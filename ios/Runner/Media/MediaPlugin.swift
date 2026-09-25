import Flutter
import AVFoundation
import Foundation
import Photos
import UIKit

private enum MediaDeliveryError: Error {
  case permissionDenied
  case unavailable

  var flutterCode: String {
    switch self {
    case .permissionDenied: "photos_permission_denied"
    case .unavailable: "media_delivery_unavailable"
    }
  }
}

final class MediaPlugin: NSObject, FlutterPlugin {
  static let channelName = "dev.otogurashi/media"
  static let eventChannelName = "dev.otogurashi/media/events"
  static let previewViewType = "dev.otogurashi/capture-preview"
  static let playbackViewType = "dev.otogurashi/playback-view"

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
    registrar.register(
      PlaybackViewFactory(store: plugin.store, registry: plugin.playback),
      withId: playbackViewType
    )
  }

  private let jobs = JobRegistry()
  private let store: ManagedMediaStore
  private let eventStream: MediaEventStreamHandler
  fileprivate let capture: CaptureService
  fileprivate let playback: PlaybackRegistry

  init(eventStream: MediaEventStreamHandler) {
    let store = ManagedMediaStore()
    self.store = store
    self.eventStream = eventStream
    self.playback = PlaybackRegistry(audioSession: .shared)
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
    case "switchCamera":
      capture.switchCamera { outcome in self.finish(result, outcome) }
    case "suspendCaptureForReview":
      capture.suspendForReview { outcome in
        switch outcome {
        case .success: self.succeed(result, value: nil)
        case .failure(let error): self.fail(result, error: error)
        }
      }
    case "discardStaged":
      guard let arguments = call.arguments as? [String: Any],
        let relativePath = arguments["relativePath"] as? String
      else { fail(result, error: CaptureServiceError.invalidMedia); return }
      capture.discardStaged(relativePath: relativePath) { outcome in
        switch outcome {
        case .success: self.succeed(result, value: nil)
        case .failure(let error): self.fail(result, error: error)
        }
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
    case "thumbnail":
      Task.detached { [self] in
        do {
          guard let arguments = call.arguments as? [String: Any],
            let relativePath = arguments["relativePath"] as? String
          else { throw CaptureServiceError.invalidMedia }
          let url = try store.resolvePlayable(relativePath: relativePath)
          let asset = AVURLAsset(url: url)
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.maximumSize = CGSize(width: 720, height: 720)
          let image = try await generator.image(at: CMTime(value: 150, timescale: 1_000)).image
          guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.78) else {
            throw CaptureServiceError.invalidMedia
          }
          succeed(result, value: FlutterStandardTypedData(bytes: data))
        } catch { fail(result, error: error) }
      }
    case "waveform":
      Task.detached { [self] in
        do {
          guard let arguments = call.arguments as? [String: Any],
            let relativePath = arguments["relativePath"] as? String
          else { throw CaptureServiceError.invalidMedia }
          let url = try store.resolve(relativePath: relativePath)
          succeed(result, value: try AudioWaveformSampler().sample(url: url))
        } catch { fail(result, error: error) }
      }
    case "playbackPlay", "playbackPause", "playbackSeek", "playbackPosition",
      "playbackState":
      guard let arguments = call.arguments as? [String: Any],
        let viewId = (arguments["viewId"] as? NSNumber)?.int64Value
      else {
        fail(result, error: CaptureServiceError.invalidMedia)
        return
      }
      do {
        switch call.method {
        case "playbackPlay":
          try playback.play(viewId: viewId) { [self] outcome in
            switch outcome {
            case .success: succeed(result, value: nil)
            case .failure(let error): fail(result, error: error)
            }
          }
        case "playbackPause":
          playback.pause(viewId: viewId)
          succeed(result, value: nil)
        case "playbackSeek":
          guard let positionUs = (arguments["positionUs"] as? NSNumber)?.int64Value,
            positionUs >= 0
          else { throw CaptureServiceError.invalidMedia }
          try playback.seek(viewId: viewId, positionUs: positionUs) { [self] outcome in
            switch outcome {
            case .success: succeed(result, value: nil)
            case .failure(let error): fail(result, error: error)
            }
          }
        case "playbackPosition":
          succeed(result, value: playback.positionUs(viewId: viewId))
        default:
          succeed(result, value: try playback.state(viewId: viewId))
        }
      } catch { fail(result, error: error) }
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
              expectedTotalSamples: request.arrangement.totalSamples,
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
    case "saveRendered":
      do {
        guard let arguments = call.arguments as? [String: Any],
          let path = arguments["relativePath"] as? String,
          path.hasPrefix("renders/")
        else { throw VideoRenderError.unsupportedContract }
        let url = try store.resolvePlayable(relativePath: path)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [self] status in
          guard status == .authorized || status == .limited else {
            fail(result, error: MediaDeliveryError.permissionDenied)
            return
          }
          PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
          } completionHandler: { [self] saved, error in
            if saved {
              succeed(result, value: nil)
            } else {
              fail(result, error: error ?? MediaDeliveryError.unavailable)
            }
          }
        }
      } catch { fail(result, error: error) }
    case "shareRendered":
      do {
        guard let arguments = call.arguments as? [String: Any],
          let path = arguments["relativePath"] as? String,
          path.hasPrefix("renders/"),
          let presenter = Self.topViewController()
        else { throw MediaDeliveryError.unavailable }
        let url = try store.resolvePlayable(relativePath: path)
        let activity = UIActivityViewController(
          activityItems: [url], applicationActivities: nil
        )
        activity.popoverPresentationController?.sourceView = presenter.view
        activity.popoverPresentationController?.sourceRect = CGRect(
          x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40,
          width: 1, height: 1
        )
        activity.completionWithItemsHandler = { [self] _, completed, _, error in
          if let error { fail(result, error: error) }
          else { succeed(result, value: completed) }
        }
        presenter.present(activity, animated: true)
      } catch { fail(result, error: error) }
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
          code: (error as? MediaDeliveryError)?.flutterCode
            ?? (error as? CaptureServiceError)?.flutterCode ?? "media_error",
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

final class PlaybackRegistry {
  private let audioSession: AudioSessionCoordinator
  private var players: [Int64: AVPlayer] = [:]
  private var loadingErrors: [Int64: Error] = [:]
  private var operations: [Int64: Int] = [:]
  private var observers: [NSObjectProtocol] = []

  func setLoadingError(viewId: Int64, error: Error) { loadingErrors[viewId] = error }

  init(audioSession: AudioSessionCoordinator) {
    self.audioSession = audioSession
    audioSession.registerPlaybackStopper { [weak self] in
      self?.pauseAll()
    }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.pauseAll() })
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.pauseAll() })
  }

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

  func register(viewId: Int64, player: AVPlayer) {
    pauseAll()
    loadingErrors.removeValue(forKey: viewId)
    player.isMuted = false
    player.volume = 1
    players[viewId] = player
    operations[viewId] = 0
  }

  func unregister(viewId: Int64) {
    loadingErrors.removeValue(forKey: viewId)
    operations.removeValue(forKey: viewId)
    players.removeValue(forKey: viewId)?.pause()
  }

  func play(viewId: Int64, completion: @escaping (Result<Void, Error>) -> Void) throws {
    if let error = loadingErrors[viewId] { throw error }
    guard let player = players[viewId], let item = player.currentItem else {
      throw CaptureServiceError.invalidState
    }
    if item.status == .failed { throw item.error ?? CaptureServiceError.invalidMedia }
    pauseAll(except: viewId)
    try audioSession.activateForPlayback()
    let operation = (operations[viewId] ?? 0) + 1
    operations[viewId] = operation
    let duration = item.duration
    if duration.isNumeric,
      CMTimeCompare(player.currentTime(), duration - CMTime(seconds: 0.05, preferredTimescale: 600)) >= 0 {
      player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
        DispatchQueue.main.async {
          guard let self, let player, self.operations[viewId] == operation,
            self.players[viewId] === player else { completion(.success(())); return }
          guard finished else { completion(.failure(CaptureServiceError.invalidState)); return }
          player.play()
          completion(.success(()))
        }
      }
    } else {
      player.play()
      completion(.success(()))
    }
  }

  func pause(viewId: Int64) {
    operations[viewId] = (operations[viewId] ?? 0) + 1
    players[viewId]?.pause()
  }

  func seek(viewId: Int64, positionUs: Int64,
    completion: @escaping (Result<Void, Error>) -> Void) throws {
    guard positionUs >= 0, let player = players[viewId] else {
      throw CaptureServiceError.invalidState
    }
    let duration = player.currentItem?.duration ?? .invalid
    let requested = CMTime(value: positionUs, timescale: 1_000_000)
    let target = duration.isNumeric ? CMTimeMinimum(requested, duration) : requested
    let operation = (operations[viewId] ?? 0) + 1
    operations[viewId] = operation
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, self.operations[viewId] == operation else { completion(.success(())); return }
        completion(finished ? .success(()) : .failure(CaptureServiceError.invalidState))
      }
    }
  }

  func positionUs(viewId: Int64) -> Int64 {
    guard let time = players[viewId]?.currentTime(), time.isNumeric else { return 0 }
    return Int64((CMTimeGetSeconds(time) * 1_000_000).rounded())
  }

  func state(viewId: Int64) throws -> [String: Any] {
    if let error = loadingErrors[viewId] { throw error }
    guard let player = players[viewId] else {
      throw CaptureServiceError.invalidState
    }
    guard let item = player.currentItem else {
      return [
        "positionUs": 0,
        "durationUs": 0,
        "isPlaying": false,
        "ended": false,
        "loading": true,
      ]
    }
    if item.status == .failed { throw item.error ?? CaptureServiceError.invalidMedia }
    let position = player.currentTime()
    let duration = item.duration
    let positionUs = position.isNumeric
      ? Int64((CMTimeGetSeconds(position) * 1_000_000).rounded()) : 0
    let durationUs = duration.isNumeric
      ? Int64((CMTimeGetSeconds(duration) * 1_000_000).rounded()) : 0
    let ended = durationUs > 0 && positionUs >= max(0, durationUs - 50_000)
      && player.rate == 0
    return [
      "positionUs": positionUs,
      "durationUs": durationUs,
      "isPlaying": player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "ended": ended,
      "loading": item.status == .unknown,
    ]
  }

  private func pauseAll(except keptViewId: Int64? = nil) {
    for viewId in players.keys where viewId != keptViewId { pause(viewId: viewId) }
  }
}

final class PlaybackViewFactory: NSObject, FlutterPlatformViewFactory {
  private let store: ManagedMediaStore
  private let registry: PlaybackRegistry

  init(store: ManagedMediaStore, registry: PlaybackRegistry) {
    self.store = store
    self.registry = registry
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let relativePath = (args as? [String: Any])?["relativePath"] as? String ?? ""
    let url = try? store.resolvePlayable(relativePath: relativePath)
    let segments = (args as? [String: Any])?["segments"] as? [[String: Any]]
    let aspectFitVideo = (args as? [String: Any])?["aspectFitVideo"] as? Bool ?? false
    return PlaybackPlatformView(frame: frame, viewId: viewId,
      url: segments == nil ? url : nil, registry: registry,
      segments: segments, store: store, aspectFitVideo: aspectFitVideo)
  }
}

final class PlaybackPlatformView: NSObject, FlutterPlatformView {
  private let playerView: PlaybackUIView
  private let viewId: Int64
  private weak var registry: PlaybackRegistry?
  private var loading: Task<Void, Never>?

  init(frame: CGRect, viewId: Int64, url: URL?, registry: PlaybackRegistry,
    segments: [[String: Any]]? = nil, store: ManagedMediaStore = ManagedMediaStore(),
    aspectFitVideo: Bool = false) {
    self.viewId = viewId
    self.registry = registry
    self.playerView = PlaybackUIView(
      frame: frame, url: url,
      videoGravity: aspectFitVideo ? .resizeAspect : .resizeAspectFill
    )
    super.init()
    registry.register(viewId: viewId, player: playerView.player)
    if let segments {
      loading = Task { [weak self] in
        do {
          let composition = try await Self.comparison(segments, store: store)
          guard !Task.isCancelled else { return }
          let item = AVPlayerItem(asset: composition)
          item.videoComposition = try await Self.previewVideoComposition(composition)
          await MainActor.run { self?.playerView.player.replaceCurrentItem(with: item) }
        } catch {
          await MainActor.run { self?.registry?.setLoadingError(viewId: viewId, error: error) }
        }
      }
    }
  }

  deinit { loading?.cancel(); registry?.unregister(viewId: viewId) }

  static func comparison(_ segments: [[String: Any]], store: ManagedMediaStore) async throws
    -> AVMutableComposition {
    guard (1...6).contains(segments.count) else { throw CaptureServiceError.invalidMedia }
    let composition = AVMutableComposition()
    var cursor = CMTime.zero
    for segment in segments {
      try Task.checkCancellation()
      guard let path = segment["relativePath"] as? String,
        let start = (segment["startUs"] as? NSNumber)?.int64Value,
        let duration = (segment["durationUs"] as? NSNumber)?.int64Value,
        start >= 0, duration > 0, duration <= 6_000_000
      else { throw CaptureServiceError.invalidMedia }
      let asset = AVURLAsset(url: try store.resolvePlayable(relativePath: path))
      let length = try await asset.load(.duration)
      let selectedStart = CMTime(value: start, timescale: 1_000_000)
      let selectedEnd = selectedStart + CMTime(value: duration, timescale: 1_000_000)
      guard length.isNumeric, selectedStart < length,
        selectedEnd <= length + CMTime(value: 1, timescale: 1_000)
      else { throw CaptureServiceError.invalidMedia }
      let range = CMTimeRange(start: selectedStart, end: CMTimeMinimum(selectedEnd, length))
      for type in [AVMediaType.video, .audio] {
        guard let source = try await asset.loadTracks(withMediaType: type).first else {
          if type == .audio { continue }
          throw CaptureServiceError.invalidMedia
        }
        guard let destination = composition.addMutableTrack(withMediaType: type,
            preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CaptureServiceError.invalidMedia }
        let available = try await source.load(.timeRange)
        let overlap = CMTimeRangeGetIntersection(range, otherRange: available)
        if CMTimeCompare(overlap.duration, .zero) > 0 {
          try destination.insertTimeRange(overlap, of: source,
            at: cursor + (overlap.start - range.start))
        }
        if type == .video { destination.preferredTransform = try await source.load(.preferredTransform) }
      }
      cursor = cursor + range.duration
    }
    // Preserve selected silent tails too, rather than shortening the player
    // timeline to the last audio packet / video frame.
    if composition.duration < cursor {
      composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: cursor))
    }
    return composition
  }

  static func previewVideoComposition(_ composition: AVMutableComposition) async throws
    -> AVMutableVideoComposition {
    let result = AVMutableVideoComposition()
    let size = CGSize(width: 720, height: 1280)
    result.renderSize = size
    result.frameDuration = CMTime(value: 1, timescale: 30)
    let tracks = try await composition.loadTracks(withMediaType: .video)
    var parts: [(track: AVAssetTrack, range: CMTimeRange, transform: CGAffineTransform)] = []
    var edges: [CMTime] = [.zero, composition.duration]
    for track in tracks {
      let range = try await track.load(.timeRange)
      let naturalSize = try await track.load(.naturalSize)
      let orientation = try await track.load(.preferredTransform)
      let bounds = CGRect(origin: .zero, size: naturalSize).applying(orientation)
      guard bounds.width > 0, bounds.height > 0 else { throw CaptureServiceError.invalidMedia }
      let scale = min(size.width / bounds.width, size.height / bounds.height)
      let transform = orientation
        .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: (size.width - bounds.width * scale) / 2,
          y: (size.height - bounds.height * scale) / 2))
      // Composition tracks can contain leading empty segments. Only expose
      // their actual inserted ranges; empty tracks must not cover another clip.
      for segment in track.segments where !segment.isEmpty {
        let occupied = CMTimeRangeGetIntersection(range, otherRange: segment.timeMapping.target)
        guard occupied.duration > .zero else { continue }
        parts.append((track, occupied, transform))
        edges.append(contentsOf: [occupied.start, occupied.end])
      }
    }
    edges.sort { CMTimeCompare($0, $1) < 0 }
    var instructions: [AVMutableVideoCompositionInstruction] = []
    for index in 0..<(edges.count - 1) where edges[index + 1] > edges[index] {
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: edges[index], end: edges[index + 1])
      instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
      instruction.layerInstructions = parts.filter {
        edges[index] >= $0.range.start && edges[index] < $0.range.end
      }.map { part in
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: part.track)
        layer.setTransform(part.transform, at: edges[index])
        return layer
      }
      instructions.append(instruction)
    }
    result.instructions = instructions
    return result
  }

  func view() -> UIView { playerView }
}

final class PlaybackUIView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  let player: AVPlayer

  init(frame: CGRect, url: URL?, videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
    if let url {
      player = AVPlayer(url: url)
    } else {
      player = AVPlayer()
    }
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true
    isUserInteractionEnabled = false
    let layer = layer as! AVPlayerLayer
    layer.player = player
    layer.videoGravity = videoGravity
    isAccessibilityElement = true
    accessibilityLabel = "動画プレビュー"
  }

  override func layoutSubviews() {
    // UIKit platform views move during sheet transitions. Do not animate a
    // second, lagging video layer behind Flutter's geometry.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    super.layoutSubviews()
    CATransaction.commit()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }
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

  func resolvePlayable(relativePath: String) throws -> URL {
    guard (relativePath.hasPrefix("originals/") || relativePath.hasPrefix("renders/")
      || relativePath.hasPrefix("staging/")),
      safeRelativePath(relativePath)
    else { throw VideoRenderError.unsupportedContract }
    let root = try prepareRoot().resolvingSymlinksInPath()
    let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
    let resolved = candidate.resolvingSymlinksInPath()
    let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard resolved.path.hasPrefix(root.path + "/"),
      values.isRegularFile == true,
      values.isSymbolicLink != true
    else { throw VideoRenderError.missingAsset }
    return resolved
  }

  func discardStaged(relativePath: String) throws {
    guard relativePath.hasPrefix("staging/"), safeRelativePath(relativePath) else {
      throw CaptureServiceError.invalidMedia
    }
    let url = try resolvePlayable(relativePath: relativePath)
    try fileManager.removeItem(at: url)
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
