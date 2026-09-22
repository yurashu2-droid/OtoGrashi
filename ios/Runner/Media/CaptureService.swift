import AVFoundation
import Flutter
import Foundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

enum CaptureServiceError: Error, Equatable {
  case permissionDenied
  case unavailable
  case invalidState
  case invalidOperation
  case incompleteCapture
  case interrupted
  case noAudio
  case tooShort
  case invalidMedia
  case cancelled

  var flutterCode: String {
    switch self {
    case .permissionDenied: "permissionDenied"
    case .unavailable: "unavailable"
    case .invalidState, .invalidOperation, .invalidMedia: "invalidMedia"
    case .incompleteCapture: "incompleteCapture"
    case .interrupted: "interrupted"
    case .noAudio: "noAudio"
    case .tooShort: "tooShort"
    case .cancelled: "cancelled"
    }
  }
}

enum CaptureLifecyclePhase: Equatable {
  case idle
  case preparing
  case ready
  case recording
  case finalizing
  case interrupted
}

struct CaptureLifecycle {
  private(set) var phase: CaptureLifecyclePhase = .idle
  private(set) var operationId: String?

  mutating func beginPreparing() throws {
    guard phase == .idle || phase == .interrupted else {
      throw CaptureServiceError.invalidState
    }
    operationId = nil
    phase = .preparing
  }

  mutating func finishPreparing() throws {
    guard phase == .preparing else { throw CaptureServiceError.invalidState }
    phase = .ready
  }

  mutating func beginRecording(operationId: String) throws {
    guard phase == .ready, !operationId.isEmpty else {
      throw CaptureServiceError.invalidState
    }
    self.operationId = operationId
    phase = .recording
  }

  mutating func beginFinalizing(operationId: String) throws {
    guard phase == .recording, self.operationId == operationId else {
      throw CaptureServiceError.invalidOperation
    }
    phase = .finalizing
  }

  mutating func interrupt(operationId: String) -> Bool {
    guard self.operationId == operationId,
      phase == .recording || phase == .finalizing
    else { return false }
    phase = .interrupted
    return true
  }

  mutating func finish(operationId: String) throws {
    guard self.operationId == operationId, phase == .finalizing else {
      throw CaptureServiceError.invalidOperation
    }
    self.operationId = nil
    phase = .ready
  }

  mutating func reset() {
    phase = .idle
    operationId = nil
  }
}

struct InspectedMediaPayload {
  let durationUs: Int64
  let audioTrackStartUs: Int64
  let width: Int
  let height: Int
  let rotation: Int

  var dictionary: [String: Any] {
    [
      "durationUs": durationUs,
      "audioTrackStartUs": audioTrackStartUs,
      "width": width,
      "height": height,
      "rotation": rotation,
    ]
  }
}

struct CaptureAsyncToken: Equatable {
  let generation: Int
  let operationId: String
}

struct CaptureAsyncGeneration {
  private var value = 0
  private var current: CaptureAsyncToken?

  mutating func begin(operationId: String) -> CaptureAsyncToken {
    value += 1
    let token = CaptureAsyncToken(generation: value, operationId: operationId)
    current = token
    return token
  }

  mutating func invalidate() {
    value += 1
    current = nil
  }

  func owns(_ token: CaptureAsyncToken, operationId: String) -> Bool {
    current == token && token.operationId == operationId
  }
}

struct CapturedMediaPayload {
  let operationId: String
  let assetId: String
  let relativePath: String
  let inspection: InspectedMediaPayload

  var dictionary: [String: Any] {
    var value = inspection.dictionary
    value["operationId"] = operationId
    value["assetId"] = assetId
    value["relativePath"] = relativePath
    return value
  }
}

struct ManagedMediaInspector {
  func inspect(url: URL) async throws -> InspectedMediaPayload {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    guard duration.isNumeric else { throw CaptureServiceError.invalidMedia }
    let durationUs = try Self.microseconds(duration)
    guard durationUs >= 300_000 else { throw CaptureServiceError.tooShort }

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard let video = videoTracks.first else { throw CaptureServiceError.invalidMedia }
    guard let audio = audioTracks.first else { throw CaptureServiceError.noAudio }

    let naturalSize = try await video.load(.naturalSize)
    let transform = try await video.load(.preferredTransform)
    let audioRange = try await audio.load(.timeRange)
    let audioTrackStartUs = try Self.microseconds(audioRange.start)
    let audioTrackDurationUs = try Self.microseconds(audioRange.duration)
    guard Self.audioRangeIsUsable(
      startUs: audioTrackStartUs,
      durationUs: audioTrackDurationUs,
      assetDurationUs: durationUs,
      maximumSelectionUs: 6_000_000
    ) else { throw CaptureServiceError.noAudio }
    let rotation = Self.rotation(transform)
    let oriented = naturalSize.applying(transform)
    let width = Int(abs(oriented.width).rounded())
    let height = Int(abs(oriented.height).rounded())
    guard width > 0, height > 0 else { throw CaptureServiceError.invalidMedia }
    return InspectedMediaPayload(
      durationUs: durationUs,
      audioTrackStartUs: audioTrackStartUs,
      width: width,
      height: height,
      rotation: rotation
    )
  }

  static func audioRangeIsUsable(
    startUs: Int64,
    durationUs: Int64,
    assetDurationUs: Int64,
    maximumSelectionUs: Int64
  ) -> Bool {
    guard startUs >= 0, durationUs > 0, assetDurationUs > 0, maximumSelectionUs > 0,
      startUs < assetDurationUs,
      startUs < min(assetDurationUs, maximumSelectionUs),
      durationUs <= Int64.max - startUs
    else { return false }
    return startUs + durationUs > 0
  }

  private static func microseconds(_ time: CMTime) throws -> Int64 {
    guard time.isNumeric else { throw CaptureServiceError.invalidMedia }
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite,
      seconds >= Double(Int64.min) / 1_000_000,
      seconds <= Double(Int64.max) / 1_000_000
    else { throw CaptureServiceError.invalidMedia }
    return Int64((seconds * 1_000_000).rounded())
  }

  private static func rotation(_ transform: CGAffineTransform) -> Int {
    let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
    return ((degrees % 360) + 360) % 360
  }
}

final class CaptureService: NSObject, AVCaptureFileOutputRecordingDelegate,
  PHPickerViewControllerDelegate
{
  typealias Completion = (Result<[String: Any], Error>) -> Void

  private let queue = DispatchQueue(label: "dev.otogurashi.capture.session")
  private let session = AVCaptureSession()
  private let output = AVCaptureMovieFileOutput()
  private let store: ManagedMediaStore
  private let audioSession: AudioSessionCoordinator
  private let inspector = ManagedMediaInspector()
  private let emit: ([String: Any]) -> Void
  private var lifecycle = CaptureLifecycle()
  private var startCompletion: ((Result<Void, Error>) -> Void)?
  private var stopCompletion: ((Result<CapturedMediaPayload, Error>) -> Void)?
  private var finalized: CapturedMediaPayload?
  private var outputURL: URL?
  private var pickerCompletion: ((Result<CapturedMediaPayload?, Error>) -> Void)?
  private weak var activePicker: PHPickerViewController?
  private var preparationGeneration = 0
  private var captureGeneration = CaptureAsyncGeneration()
  private var activeCaptureToken: CaptureAsyncToken?
  private var pickerGeneration = CaptureAsyncGeneration()
  private var activePickerToken: CaptureAsyncToken?

  init(
    store: ManagedMediaStore,
    audioSession: AudioSessionCoordinator = .shared,
    emit: @escaping ([String: Any]) -> Void
  ) {
    self.store = store
    self.audioSession = audioSession
    self.emit = emit
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(audioSessionInterrupted(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(audioRouteChanged(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(sceneEnteredBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  var captureSession: AVCaptureSession { session }

  func prepare(completion: @escaping Completion) {
    queue.async { [weak self] in
      guard let self else { return }
      self.preparationGeneration += 1
      let generation = self.preparationGeneration
      do { try self.lifecycle.beginPreparing() }
      catch { completion(.failure(error)); return }
      self.requestPermissions { granted in
        self.queue.async {
          do {
            guard generation == self.preparationGeneration else {
              throw CaptureServiceError.cancelled
            }
            guard granted else { throw CaptureServiceError.permissionDenied }
            try self.configureSessionIfNeeded()
            try self.lifecycle.finishPreparing()
            if !self.session.isRunning { self.session.startRunning() }
            completion(.success([
              "previewViewType": MediaPlugin.previewViewType
            ]))
          } catch {
            self.lifecycle.reset()
            completion(.failure(error))
          }
        }
      }
    }
  }

  func start(
    operationId: String,
    maxDurationUs: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      do {
        guard maxDurationUs == 3_000_000 || maxDurationUs == 6_000_000 else {
          throw CaptureServiceError.invalidMedia
        }
        try self.lifecycle.beginRecording(operationId: operationId)
        let token = self.captureGeneration.begin(operationId: operationId)
        self.activeCaptureToken = token
        try self.audioSession.activateForRecording()
        let url = try self.store.newStagingURL(extension: "mov")
        self.outputURL = url
        self.finalized = nil
        self.startCompletion = completion
        self.output.maxRecordedDuration = CMTime(value: maxDurationUs, timescale: 1_000_000)
        self.output.startRecording(to: url, recordingDelegate: self)
      } catch {
        self.captureGeneration.invalidate()
        self.activeCaptureToken = nil
        self.lifecycle.reset()
        self.audioSession.deactivateRecording()
        completion(.failure(error))
      }
    }
  }

  func stop(
    operationId: String,
    completion: @escaping (Result<CapturedMediaPayload, Error>) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      if let finalized = self.finalized, finalized.operationId == operationId {
        self.finalized = nil
        completion(.success(finalized))
        return
      }
      do {
        guard self.lifecycle.phase == .recording,
          self.lifecycle.operationId == operationId
        else { throw CaptureServiceError.invalidOperation }
        self.stopCompletion = completion
        if self.output.isRecording {
          try self.lifecycle.beginFinalizing(operationId: operationId)
          self.output.stopRecording()
        }
      } catch {
        self.stopCompletion = nil
        completion(.failure(error))
      }
    }
  }

  func dispose(completion: @escaping () -> Void) {
    queue.async { [weak self] in
      guard let self else { completion(); return }
      if self.output.isRecording { self.output.stopRecording() }
      self.preparationGeneration += 1
      self.captureGeneration.invalidate()
      self.activeCaptureToken = nil
      if self.session.isRunning { self.session.stopRunning() }
      self.audioSession.deactivateRecording()
      self.outputURL.map { try? FileManager.default.removeItem(at: $0) }
      self.startCompletion?(.failure(CaptureServiceError.cancelled))
      self.startCompletion = nil
      self.stopCompletion?(.failure(CaptureServiceError.cancelled))
      self.stopCompletion = nil
      self.outputURL = nil
      self.finalized = nil
      self.lifecycle.reset()
      DispatchQueue.main.async {
        self.pickerGeneration.invalidate()
        self.activePickerToken = nil
        self.activePicker?.dismiss(animated: false)
        self.activePicker = nil
        let pickerCompletion = self.pickerCompletion
        self.pickerCompletion = nil
        pickerCompletion?(.failure(CaptureServiceError.cancelled))
        completion()
      }
    }
  }

  func inspectStaged(path: String) async throws -> InspectedMediaPayload {
    let url = try store.resolveStaged(path: path)
    return try await inspector.inspect(url: url)
  }

  func pickVideo(
    operationId: String,
    presenter: UIViewController,
    completion: @escaping (Result<CapturedMediaPayload?, Error>) -> Void
  ) {
    guard pickerCompletion == nil, !operationId.isEmpty else {
      completion(.failure(CaptureServiceError.invalidState))
      return
    }
    let token = pickerGeneration.begin(operationId: operationId)
    activePickerToken = token
    pickerCompletion = completion
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .videos
    configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    picker.view.accessibilityIdentifier = operationId
    activePicker = picker
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let operationId = picker.view.accessibilityIdentifier ?? ""
    guard let token = activePickerToken,
      pickerGeneration.owns(token, operationId: operationId),
      picker === activePicker
    else { return }
    activePicker = nil
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider else {
      let completion = pickerCompletion
      pickerCompletion = nil
      activePickerToken = nil
      pickerGeneration.invalidate()
      completion?(.success(nil))
      return
    }
    provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) {
      [weak self] source, error in
      guard let self else { return }
      if let error { self.finishPicker(token: token, stagedURL: nil, .failure(error)); return }
      guard let source else {
        self.finishPicker(token: token, stagedURL: nil, .failure(CaptureServiceError.invalidMedia))
        return
      }
      do {
        let url = try self.store.newStagingURL(
          extension: source.pathExtension.isEmpty ? "mov" : source.pathExtension
        )
        try FileManager.default.copyItem(at: source, to: url)
        Task {
          do {
            let inspection = try await self.inspector.inspect(url: url)
            let payload = try self.payload(
              operationId: operationId,
              url: url,
              inspection: inspection
            )
            self.finishPicker(token: token, stagedURL: url, .success(payload))
          } catch {
            self.finishPicker(token: token, stagedURL: url, .failure(error))
          }
        }
      } catch {
        self.finishPicker(token: token, stagedURL: nil, .failure(error))
      }
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didStartRecordingTo fileURL: URL,
    from connections: [AVCaptureConnection]
  ) {
    queue.async { [weak self] in
      guard let self, let operationId = self.lifecycle.operationId,
        let token = self.activeCaptureToken,
        self.captureGeneration.owns(token, operationId: operationId),
        self.outputURL == fileURL
      else { return }
      let completion = self.startCompletion
      self.startCompletion = nil
      completion?(.success(()))
      self.emitEvent(operationId: operationId, type: "recording", progress: 0)
      if self.stopCompletion != nil {
        do {
          try self.lifecycle.beginFinalizing(operationId: operationId)
          self.output.stopRecording()
        } catch {
          let stop = self.stopCompletion
          self.stopCompletion = nil
          stop?(.failure(error))
        }
      }
    }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    queue.async { [weak self] in
      guard let self, let operationId = self.lifecycle.operationId,
        let token = self.activeCaptureToken,
        self.captureGeneration.owns(token, operationId: operationId),
        self.outputURL == outputFileURL
      else {
        try? FileManager.default.removeItem(at: outputFileURL)
        return
      }
      self.audioSession.deactivateRecording()
      if self.lifecycle.phase == .interrupted {
        try? FileManager.default.removeItem(at: outputFileURL)
        let start = self.startCompletion
        self.startCompletion = nil
        let completion = self.stopCompletion
        self.stopCompletion = nil
        start?(.failure(CaptureServiceError.interrupted))
        completion?(.failure(CaptureServiceError.interrupted))
        self.outputURL = nil
        return
      }
      guard Self.recordingFinishedSuccessfully(error: error) else {
        try? FileManager.default.removeItem(at: outputFileURL)
        let start = self.startCompletion
        self.startCompletion = nil
        let completion = self.stopCompletion
        self.stopCompletion = nil
        self.lifecycle.reset()
        self.outputURL = nil
        start?(.failure(CaptureServiceError.incompleteCapture))
        completion?(.failure(CaptureServiceError.incompleteCapture))
        self.emitEvent(
          operationId: operationId,
          type: "failed",
          errorCode: CaptureServiceError.incompleteCapture.flutterCode
        )
        return
      }
      if self.lifecycle.phase == .recording {
        try? self.lifecycle.beginFinalizing(operationId: operationId)
      }
      Task {
        do {
          let inspection = try await self.inspector.inspect(url: outputFileURL)
          let payload = try self.payload(
            operationId: operationId,
            url: outputFileURL,
            inspection: inspection
          )
          self.queue.async {
            guard self.captureGeneration.owns(token, operationId: operationId),
              self.activeCaptureToken == token,
              self.outputURL == outputFileURL
            else {
              try? FileManager.default.removeItem(at: outputFileURL)
              return
            }
            do { try self.lifecycle.finish(operationId: operationId) }
            catch {
              try? FileManager.default.removeItem(at: outputFileURL)
              self.stopCompletion?(.failure(error))
              self.stopCompletion = nil
              return
            }
            self.outputURL = nil
            self.activeCaptureToken = nil
            if let completion = self.stopCompletion {
              self.stopCompletion = nil
              completion(.success(payload))
            } else {
              self.finalized = payload
              self.emitEvent(operationId: operationId, type: "completed", progress: 1)
            }
          }
        } catch {
          try? FileManager.default.removeItem(at: outputFileURL)
          self.queue.async {
            guard self.captureGeneration.owns(token, operationId: operationId),
              self.activeCaptureToken == token,
              self.outputURL == outputFileURL
            else {
              try? FileManager.default.removeItem(at: outputFileURL)
              return
            }
            self.lifecycle.reset()
            self.outputURL = nil
            self.activeCaptureToken = nil
            let completion = self.stopCompletion
            self.stopCompletion = nil
            completion?(.failure(error))
            self.emitEvent(
              operationId: operationId,
              type: "failed",
              errorCode: (error as? CaptureServiceError)?.flutterCode
                ?? CaptureServiceError.incompleteCapture.flutterCode
            )
          }
        }
      }
    }
  }

  static func recordingFinishedSuccessfully(error: Error?) -> Bool {
    guard let error = error as NSError? else { return true }
    return error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
  }

  @objc private func audioSessionInterrupted(_ notification: Notification) {
    interruptCurrentCapture(code: "interrupted")
  }

  @objc private func audioRouteChanged(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
    else { return }
    interruptCurrentCapture(code: "interrupted")
  }

  @objc private func sceneEnteredBackground() {
    interruptCurrentCapture(code: "interrupted")
  }

  private func interruptCurrentCapture(code: String) {
    queue.async { [weak self] in
      guard let self, let operationId = self.lifecycle.operationId,
        self.lifecycle.interrupt(operationId: operationId)
      else { return }
      self.emitEvent(operationId: operationId, type: "interrupted", errorCode: code)
      if self.output.isRecording { self.output.stopRecording() }
      else { self.outputURL.map { try? FileManager.default.removeItem(at: $0) } }
      self.audioSession.deactivateRecording()
    }
  }

  private func requestPermissions(completion: @escaping (Bool) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var granted = true
    for mediaType in [AVMediaType.video, .audio] {
      switch AVCaptureDevice.authorizationStatus(for: mediaType) {
      case .authorized:
        break
      case .notDetermined:
        group.enter()
        AVCaptureDevice.requestAccess(for: mediaType) { allowed in
          lock.lock()
          granted = granted && allowed
          lock.unlock()
          group.leave()
        }
      default:
        granted = false
      }
    }
    group.notify(queue: queue) { completion(granted) }
  }

  private func configureSessionIfNeeded() throws {
    guard session.inputs.isEmpty else { return }
    guard let camera = AVCaptureDevice.default(
      .builtInWideAngleCamera,
      for: .video,
      position: .back
    ), let microphone = AVCaptureDevice.default(for: .audio)
    else { throw CaptureServiceError.unavailable }
    let cameraInput = try AVCaptureDeviceInput(device: camera)
    let microphoneInput = try AVCaptureDeviceInput(device: microphone)
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    session.sessionPreset = .high
    guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput),
      session.canAddOutput(output)
    else { throw CaptureServiceError.unavailable }
    session.addInput(cameraInput)
    session.addInput(microphoneInput)
    session.addOutput(output)
    output.movieFragmentInterval = .invalid
  }

  private func payload(
    operationId: String,
    url: URL,
    inspection: InspectedMediaPayload
  ) throws -> CapturedMediaPayload {
    CapturedMediaPayload(
      operationId: operationId,
      assetId: url.deletingPathExtension().lastPathComponent,
      relativePath: try store.relativePath(for: url),
      inspection: inspection
    )
  }

  private func emitEvent(
    operationId: String,
    type: String,
    progress: Double? = nil,
    errorCode: String? = nil
  ) {
    emit([
      "operationId": operationId,
      "type": type,
      "progress": progress ?? NSNull(),
      "errorCode": errorCode ?? NSNull(),
    ])
  }

  private func finishPicker(
    token: CaptureAsyncToken,
    stagedURL: URL?,
    _ result: Result<CapturedMediaPayload?, Error>
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self,
        self.pickerGeneration.owns(token, operationId: token.operationId),
        self.activePickerToken == token
      else {
        if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
        return
      }
      let completion = self.pickerCompletion
      self.pickerCompletion = nil
      self.activePickerToken = nil
      self.pickerGeneration.invalidate()
      if case .failure = result, let stagedURL {
        try? FileManager.default.removeItem(at: stagedURL)
      }
      completion?(result)
    }
  }
}

final class CapturePreviewViewFactory: NSObject, FlutterPlatformViewFactory {
  private let session: AVCaptureSession

  init(session: AVCaptureSession) {
    self.session = session
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    CapturePreviewPlatformView(frame: frame, session: session)
  }
}

final class CapturePreviewPlatformView: NSObject, FlutterPlatformView {
  private let preview: CapturePreviewUIView

  init(frame: CGRect, session: AVCaptureSession) {
    preview = CapturePreviewUIView(frame: frame, session: session)
  }

  func view() -> UIView { preview }
}

final class CapturePreviewUIView: UIView {
  override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

  init(frame: CGRect, session: AVCaptureSession) {
    super.init(frame: frame)
    let preview = layer as! AVCaptureVideoPreviewLayer
    preview.session = session
    preview.videoGravity = .resizeAspectFill
    isAccessibilityElement = true
    accessibilityLabel = "カメラのプレビュー"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }
}
