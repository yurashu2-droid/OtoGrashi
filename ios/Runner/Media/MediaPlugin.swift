import Flutter
import Foundation
import UIKit

final class MediaPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.otogurashi/media"
  static let eventChannelName = "dev.otogurashi/media/events"
  static let previewViewType = "dev.otogurashi/capture-preview"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    let stream = MediaEventStreamHandler()
    eventChannel.setStreamHandler(stream)
    let plugin = MediaPlugin(eventStream: stream)
    registrar.addMethodCallDelegate(plugin, channel: channel)
    registrar.register(
      CapturePreviewViewFactory(session: plugin.capture.captureSession),
      withId: previewViewType
    )
  }

  private let jobs = JobRegistry()
  private let store: ManagedMediaStore
  private let eventStream: MediaEventStreamHandler
  fileprivate let capture: CaptureService

  init(eventStream: MediaEventStreamHandler) {
    let store = ManagedMediaStore()
    self.store = store
    self.eventStream = eventStream
    self.capture = CaptureService(store: store) { event in
      eventStream.emit(event)
    }
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "managedRoot":
      complete(result) {
        try self.store.prepareRoot().path
      }
    case "prepareCapture":
      capture.prepare { outcome in
        self.finish(result, outcome)
      }
    case "startCapture":
      guard let arguments = call.arguments as? [String: Any],
        let operationId = arguments["operationId"] as? String,
        let maxDuration = arguments["maxDurationUs"] as? NSNumber
      else {
        fail(result, error: CaptureServiceError.invalidMedia)
        return
      }
      capture.start(
        operationId: operationId,
        maxDurationUs: maxDuration.int64Value
      ) { outcome in
        switch outcome {
        case .success: self.succeed(result, value: nil)
        case .failure(let error): self.fail(result, error: error)
        }
      }
    case "stopCapture":
      guard let arguments = call.arguments as? [String: Any],
        let operationId = arguments["operationId"] as? String
      else {
        fail(result, error: CaptureServiceError.invalidMedia)
        return
      }
      capture.stop(operationId: operationId) { outcome in
        self.finish(result, outcome.map(\.dictionary))
      }
    case "pickVideo":
      guard let arguments = call.arguments as? [String: Any],
        let operationId = arguments["operationId"] as? String,
        let presenter = Self.topViewController()
      else {
        fail(result, error: CaptureServiceError.unavailable)
        return
      }
      capture.pickVideo(operationId: operationId, presenter: presenter) { outcome in
        switch outcome {
        case .success(let payload): self.succeed(result, value: payload?.dictionary)
        case .failure(let error): self.fail(result, error: error)
        }
      }
    case "inspectStaged":
      guard let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String
      else {
        fail(result, error: CaptureServiceError.invalidMedia)
        return
      }
      Task {
        do { succeed(result, value: try await capture.inspectStaged(path: path).dictionary) }
        catch { fail(result, error: error) }
      }
    case "disposeCapture":
      capture.dispose { self.succeed(result, value: nil) }
    case "analyze":
      complete(result) {
        let request = try self.decode(MediaAnalysisRequest.self, call.arguments)
        let url = try self.store.resolve(relativePath: request.relativePath)
        let analyzed = try AudioAnalyzer().analyze(
          url: url,
          assetId: request.assetId,
          selectionStartUs: request.selectionStartUs,
          selectionDurationUs: request.selectionDurationUs,
          audioTrackStartUs: request.audioTrackStartUs
        )
        return try self.dictionary(analyzed)
      }
    case "render":
      Task.detached { [self] in
        do {
          let request = try decode(VideoRenderRequestPayload.self, call.arguments)
          let token = try await jobs.startExclusiveExport(operationId: request.operationId)
          var producedOutput: URL?
          do {
            let assets = try store.resolveOriginals(
              assetIds: request.arrangement.sourceAssetIds
            )
            let output = try store.outputURL(for: request)
            producedOutput = output
            _ = try await VideoRenderer().render(
              request: request,
              assets: assets,
              outputURL: output,
              cancellation: token
            )
            let dimensions = request.quality.dimensions
            let validation = try await MediaValidator().validate(
              url: output,
              expectedWidth: dimensions.width,
              expectedHeight: dimensions.height,
              expectedOnsetSample: nil,
              cancellation: token
            )
            guard !token.isCancelled else {
              try? FileManager.default.removeItem(at: output)
              throw VideoRenderError.cancelled
            }
            let relativePath = try store.relativePath(for: output)
            guard await jobs.finishForPublication(operationId: request.operationId) else {
              try? FileManager.default.removeItem(at: output)
              throw VideoRenderError.cancelled
            }
            succeed(result, value: [
              "operationId": request.operationId,
              "projectId": request.projectId,
              "revision": request.revision,
              "relativePath": relativePath,
              "durationUs": validation.durationUs,
              "width": validation.width,
              "height": validation.height,
            ])
          } catch {
            if let producedOutput {
              try? FileManager.default.removeItem(at: producedOutput)
            }
            await jobs.finish(operationId: request.operationId)
            throw error
          }
        } catch {
          fail(result, error: error)
        }
      }
    case "cancel":
      Task { [self] in
        guard let arguments = call.arguments as? [String: Any],
          let operationId = arguments["operationId"] as? String,
          !operationId.isEmpty
        else {
          fail(result, error: VideoRenderError.unsupportedContract)
          return
        }
        await jobs.cancelAndWait(operationId: operationId)
        succeed(result, value: nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func complete(_ result: @escaping FlutterResult, work: @escaping () throws -> Any) {
    Task.detached { [self] in
      do { succeed(result, value: try work()) }
      catch { fail(result, error: error) }
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ arguments: Any?) throws
    -> Value
  {
    guard let object = arguments, JSONSerialization.isValidJSONObject(object) else {
      throw VideoRenderError.unsupportedContract
    }
    return try JSONDecoder().decode(
      Value.self,
      from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
  }

  private func dictionary<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw VideoRenderError.unsupportedContract }
    return dictionary
  }

  private func finish<Value>(_ result: @escaping FlutterResult, _ outcome: Result<Value, Error>) {
    switch outcome {
    case .success(let value): succeed(result, value: value)
    case .failure(let error): fail(result, error: error)
    }
  }

  private func succeed(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async { result(value) }
  }

  private func fail(_ result: @escaping FlutterResult, error: Error) {
    DispatchQueue.main.async {
      result(
        FlutterError(
          code: (error as? CaptureServiceError)?.flutterCode ?? "media_error",
          message: String(describing: error),
          details: nil
        )
      )
    }
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
    var current = root
    while let presented = current?.presentedViewController { current = presented }
    return current
  }
}

final class MediaEventStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(event) }
  }
}

struct ManagedMediaStore {
  private let fileManager = FileManager.default
  private let rootOverride: URL?

  init(rootOverride: URL? = nil) {
    self.rootOverride = rootOverride
  }

  func prepareRoot() throws -> URL {
    let base: URL
    if let rootOverride {
      base = rootOverride
    } else {
      base = try fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appendingPathComponent("OtoGrashi", isDirectory: true)
    }
    for directory in ["originals", "renders", "staging", "analysis-cache"] {
      try fileManager.createDirectory(
        at: base.appendingPathComponent(directory, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
    return base.standardizedFileURL
  }

  func resolve(relativePath: String) throws -> URL {
    guard relativePath.hasPrefix("originals/"), safeRelativePath(relativePath) else {
      throw VideoRenderError.unsupportedContract
    }
    let root = try prepareRoot().resolvingSymlinksInPath()
    let originals = root.appendingPathComponent("originals", isDirectory: true)
      .resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath()
    let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard resolved.path.hasPrefix(originals.path + "/"),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else { throw VideoRenderError.missingAsset }
    return resolved
  }

  func resolveOriginals(assetIds: [String]) throws -> [String: URL] {
    let root = try prepareRoot()
    let originals = root.appendingPathComponent("originals", isDirectory: true)
    let files = try fileManager.contentsOfDirectory(
      at: originals,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    var result: [String: URL] = [:]
    for id in assetIds {
      guard UUID(uuidString: id) != nil else { throw VideoRenderError.unsupportedContract }
      let matches = try files.filter {
        guard $0.deletingPathExtension().lastPathComponent == id else { return false }
        let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
          && $0.resolvingSymlinksInPath().path.hasPrefix(originals.path + "/")
      }
      guard matches.count == 1 else { throw VideoRenderError.missingAsset }
      result[id] = matches[0]
    }
    return result
  }

  func outputURL(for request: VideoRenderRequestPayload) throws -> URL {
    guard safeComponent(request.projectId), safeComponent(request.operationId) else {
      throw VideoRenderError.unsupportedContract
    }
    let root = try prepareRoot()
    let directory = root
      .appendingPathComponent("renders", isDirectory: true)
      .appendingPathComponent(request.projectId, isDirectory: true)
      .appendingPathComponent(String(request.revision), isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(request.operationId)-\(request.quality.rawValue).mp4")
  }

  func relativePath(for url: URL) throws -> String {
    let root = try prepareRoot()
    let standardized = url.standardizedFileURL
    guard standardized.path.hasPrefix(root.path + "/") else {
      throw VideoRenderError.unsupportedContract
    }
    return String(standardized.path.dropFirst(root.path.count + 1))
  }

  func newStagingURL(extension fileExtension: String) throws -> URL {
    let safeExtension = fileExtension.lowercased()
    guard !safeExtension.isEmpty,
      safeExtension.count <= 10,
      safeExtension.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    else { throw CaptureServiceError.invalidMedia }
    return try prepareRoot()
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent("\(UUID().uuidString.lowercased()).\(safeExtension)")
  }

  func resolveStaged(path: String) throws -> URL {
    let root = try prepareRoot().resolvingSymlinksInPath()
    let staging = root.appendingPathComponent("staging", isDirectory: true)
      .resolvingSymlinksInPath()
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath()
    let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard resolved.path.hasPrefix(staging.path + "/"),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else { throw CaptureServiceError.invalidMedia }
    return resolved
  }

  private func safeRelativePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
      && !path.split(separator: "/").contains("..")
  }

  private func safeComponent(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 100
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
      }
  }
}
