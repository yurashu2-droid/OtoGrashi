import AVFoundation
import XCTest
@testable import Runner

final class CaptureStateTests: XCTestCase {
  func testInterruptionCannotPublishACompletedCapture() throws {
    var lifecycle = CaptureLifecycle()
    try lifecycle.beginPreparing()
    try lifecycle.finishPreparing()
    try lifecycle.beginRecording(operationId: "capture-1")

    XCTAssertEqual(lifecycle.interrupt(operationId: "capture-1"), true)
    XCTAssertThrowsError(try lifecycle.beginFinalizing(operationId: "capture-1"))
    XCTAssertEqual(lifecycle.phase, .interrupted)
  }

  func testStaleOperationCannotFinalizeCurrentCapture() throws {
    var lifecycle = CaptureLifecycle()
    try lifecycle.beginPreparing()
    try lifecycle.finishPreparing()
    try lifecycle.beginRecording(operationId: "capture-new")

    XCTAssertThrowsError(try lifecycle.beginFinalizing(operationId: "capture-old"))
    XCTAssertEqual(lifecycle.phase, .recording)
    XCTAssertEqual(lifecycle.operationId, "capture-new")
  }

  func testDurationLimitErrorWithSuccessfulFlagIsAccepted() {
    let successfulLimit = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.Code.maximumDurationReached.rawValue,
      userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true]
    )
    let interrupted = NSError(
      domain: AVFoundationErrorDomain,
      code: AVError.Code.sessionWasInterrupted.rawValue,
      userInfo: [AVErrorRecordingSuccessfullyFinishedKey: false]
    )

    XCTAssertTrue(CaptureService.recordingFinishedSuccessfully(error: successfulLimit))
    XCTAssertFalse(CaptureService.recordingFinishedSuccessfully(error: interrupted))
    XCTAssertTrue(CaptureService.recordingFinishedSuccessfully(error: nil))
  }

  func testInspectorPathMustBeARegularManagedStagingFile() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).mov")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let store = ManagedMediaStore(rootOverride: root)
    let staging = try store.prepareRoot().appendingPathComponent("staging", isDirectory: true)
    let managed = staging.appendingPathComponent("fixture.mov")
    try Data([0, 1, 2]).write(to: managed)
    try Data([3, 4, 5]).write(to: outside)

    XCTAssertEqual(try store.resolveStaged(path: managed.path), managed)
    XCTAssertThrowsError(try store.resolveStaged(path: outside.path))

    let link = staging.appendingPathComponent("link.mov")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try store.resolveStaged(path: link.path))
  }
}
