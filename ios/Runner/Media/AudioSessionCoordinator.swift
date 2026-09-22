import AVFoundation
import Foundation

/// The single owner of AVAudioSession policy for recording and future playback.
/// Playback code registers a stopper so recording never activates over app audio.
final class AudioSessionCoordinator {
  static let shared = AudioSessionCoordinator()

  private let session: AVAudioSession
  private let lock = NSLock()
  private var stopPlayback: (() -> Void)?
  private var recordingOwnsSession = false

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  func registerPlaybackStopper(_ stop: @escaping () -> Void) {
    lock.lock()
    stopPlayback = stop
    lock.unlock()
  }

  func activateForRecording() throws {
    lock.lock()
    recordingOwnsSession = true
    let stop = stopPlayback
    lock.unlock()
    if let stop {
      if Thread.isMainThread {
        stop()
      } else {
        DispatchQueue.main.sync(execute: stop)
      }
    }
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .videoRecording,
        options: [.allowBluetoothHFP, .defaultToSpeaker]
      )
      try session.setActive(true)
    } catch {
      lock.lock()
      recordingOwnsSession = false
      lock.unlock()
      throw error
    }
  }

  func activateForPlayback() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !recordingOwnsSession else {
      throw AudioSessionCoordinatorError.recordingActive
    }
    try session.setCategory(.playback, mode: .moviePlayback)
    try session.setActive(true)
  }

  func deactivateRecording() {
    lock.lock()
    let owned = recordingOwnsSession
    recordingOwnsSession = false
    lock.unlock()
    guard owned else { return }
    try? session.setActive(false, options: [.notifyOthersOnDeactivation])
  }
}

enum AudioSessionCoordinatorError: Error {
  case recordingActive
}
