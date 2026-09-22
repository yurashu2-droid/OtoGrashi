import AVFoundation
import Foundation

/// The single owner of AVAudioSession policy for recording and future playback.
/// Playback code registers a stopper so recording never activates over app audio.
final class AudioSessionCoordinator {
  static let shared = AudioSessionCoordinator()

  private let session: AVAudioSession
  private let lock = NSLock()
  private var stopPlayback: (() -> Void)?

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
    let stop = stopPlayback
    lock.unlock()
    stop?()
    try session.setCategory(
      .playAndRecord,
      mode: .videoRecording,
      options: [.allowBluetoothHFP, .defaultToSpeaker]
    )
    try session.setActive(true)
  }

  func deactivateRecording() {
    try? session.setActive(false, options: [.notifyOthersOnDeactivation])
  }
}
