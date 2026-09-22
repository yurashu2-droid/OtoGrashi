import AVFoundation
import XCTest
@testable import Runner

final class VideoRendererTests: XCTestCase {
  func testManagedStoreRejectsMissingAndDuplicateOriginalMatches() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ManagedMediaStore(rootOverride: root)
    _ = try store.prepareRoot()
    let id = UUID().uuidString.lowercased()

    XCTAssertThrowsError(try store.resolveOriginals(assetIds: [id]))
    let originals = root.appendingPathComponent("originals", isDirectory: true)
    try Data([0]).write(to: originals.appendingPathComponent("\(id).mp4"))
    try Data([1]).write(to: originals.appendingPathComponent("\(id).mov"))
    XCTAssertThrowsError(try store.resolveOriginals(assetIds: [id]))
  }

  func testManagedStoreRejectsTraversalAndOriginalSymlink() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).mp4")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let store = ManagedMediaStore(rootOverride: root)
    _ = try store.prepareRoot()
    try Data([0]).write(to: outside)
    let link = root.appendingPathComponent("originals/link.mp4")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    XCTAssertThrowsError(try store.resolve(relativePath: "originals/../projects.sqlite3"))
    XCTAssertThrowsError(try store.resolve(relativePath: "originals/link.mp4"))
  }

  func testJobRegistrySerializesExportOwnership() async throws {
    let registry = JobRegistry()
    _ = try await registry.startExclusiveExport(operationId: "first")
    do {
      _ = try await registry.startExclusiveExport(operationId: "second")
      XCTFail("Expected exclusive export rejection")
    } catch {
      XCTAssertEqual(error as? AudioRenderError, .duplicateOperationId)
    }
    await registry.finish(operationId: "first")
    _ = try await registry.startExclusiveExport(operationId: "second")
  }

  func testCancelAndWaitDoesNotReleaseOwnershipBeforeFinish() async throws {
    let registry = JobRegistry()
    let token = try await registry.startExclusiveExport(operationId: "active")
    let cancelled = expectation(description: "cancel returned after finish")
    let task = Task {
      await registry.cancelAndWait(operationId: "active")
      cancelled.fulfill()
    }
    while !token.isCancelled {
      await Task.yield()
    }
    XCTAssertTrue(token.isCancelled)
    do {
      _ = try await registry.startExclusiveExport(operationId: "replacement")
      XCTFail("Expected ownership to remain active")
    } catch {
      XCTAssertEqual(error as? AudioRenderError, .duplicateOperationId)
    }
    await registry.finish(operationId: "active")
    await fulfillment(of: [cancelled], timeout: 1)
    _ = await task.result
    _ = try await registry.startExclusiveExport(operationId: "replacement")
  }

  func testCancellationArrivingBeforeStartPreventsThatJobFromStarting() async throws {
    let registry = JobRegistry()
    await registry.cancelAndWait(operationId: "future")
    do {
      _ = try await registry.startExclusiveExport(operationId: "future")
      XCTFail("Expected pre-start cancellation")
    } catch {
      XCTAssertEqual(error as? AudioRenderError, .cancelled)
    }
  }

  func testCancelledJobCannotWinAtomicPublication() async throws {
    let registry = JobRegistry()
    _ = try await registry.startExclusiveExport(operationId: "cancelled")
    await registry.cancel(operationId: "cancelled")

    let published = await registry.finishForPublication(operationId: "cancelled")

    XCTAssertFalse(published)
    _ = try await registry.startExclusiveExport(operationId: "replacement")
  }

  func testValidatorStopsBeforeReadingAnAlreadyCancelledExport() async throws {
    let token = CancellationToken(operationId: "validation")
    token.cancel()
    do {
      _ = try await MediaValidator().validate(
        url: fixtureURL("synthetic-tap.mp4"),
        expectedWidth: 160,
        expectedHeight: 90,
        expectedOnsetSample: nil,
        cancellation: token
      )
      XCTFail("Expected validation cancellation")
    } catch {
      XCTAssertEqual(error as? VideoRenderError, .cancelled)
    }
  }

  func testNearestFrameUsesHalfUpSampleRoundingWithoutChangingSampleTime() {
    XCTAssertEqual(VideoRenderer.nearestFrame(forSample: 799), 0)
    XCTAssertEqual(VideoRenderer.nearestFrame(forSample: 800), 1)
    XCTAssertEqual(VideoRenderer.nearestFrame(forSample: 12_000), 8)
  }

  func testStackedAndPhotoDumpKeepFirstRecipeAssetAtTheVisualTop() {
    for layout in [VideoLayoutPayload.stacked, .photoDump] {
      let rects = VideoRenderer.targetRects(
        count: 3,
        layout: layout,
        width: 360,
        height: 640
      )
      XCTAssertGreaterThan(rects[0].midY, rects[1].midY)
      XCTAssertGreaterThan(rects[1].midY, rects[2].midY)
    }
  }

  func testAllLayoutsDecodeWithBarBoundaryScenesAndEverySource() throws {
    for layout in ["stacked", "sequentialFocus", "photoDump"] {
      let request = try decodeRequest(quality: "preview", layout: layout)
      XCTAssertTrue(
        request.video.events.allSatisfy {
          $0.destinationStartSample % 90_000 == 0
        }
      )
      XCTAssertEqual(
        Set(request.video.events.flatMap(\.assetIds)),
        Set(["tap", "sustain", "texture"])
      )
      XCTAssertEqual(request.video.events.last?.destinationEndSample, 720_000)
    }
  }

  func testPreviewAndFullWriteDecoded450Frame15SecondMovies() async throws {
    let sourceURL = fixtureURL("synthetic-tap.mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    let assets = ["tap": sourceURL, "sustain": sourceURL, "texture": sourceURL]
    let renderer = VideoRenderer(
      audioRenderer: AudioRenderer(accompanimentGain: 0)
    )
    var outputs: [URL] = []
    defer { outputs.forEach { try? FileManager.default.removeItem(at: $0) } }

    for quality in ["preview", "full"] {
      print("VIDEO_RENDER_START quality=\(quality) time=\(Date().timeIntervalSince1970)")
      let request = try decodeRequest(quality: quality, layout: "stacked")
      let output = temporaryURL("\(quality).mp4")
      outputs.append(output)
      let report = try await renderer.render(
        request: request,
        assets: assets,
        outputURL: output,
        cancellation: CancellationToken(operationId: quality)
      )
      try preserveMovie(output, name: quality)
      print("VIDEO_RENDER_END quality=\(quality) frames=\(report.frameCount) time=\(Date().timeIntervalSince1970)")
      let validation = try await validateAndPersist(
        output,
        name: quality,
        expectedWidth: quality == "full" ? 1080 : 360,
        expectedHeight: quality == "full" ? 1920 : 640
      )

      XCTAssertEqual(report.frameCount, 450)
      XCTAssertEqual(validation.decodedFrameCount, 450)
      XCTAssertEqual(validation.durationUs, 15_000_000)
      XCTAssertEqual(validation.audioTrackCount, 1)
      XCTAssertEqual(validation.audioDurationUs, 15_000_000)
      XCTAssertLessThanOrEqual(abs(validation.firstAudibleSample - 12_000), 1_600)
      XCTAssertEqual(validation.videoCueFrame, 8)
      XCTAssertLessThanOrEqual(try XCTUnwrap(validation.audioVideoDeltaUs), 33_334)
    }
  }

  func testRotatedVFRAndHDRSourcesNormalizeToSDR30fps() async throws {
    let renderer = VideoRenderer(audioRenderer: AudioRenderer(accompanimentGain: 0))
    var outputs: [URL] = []
    defer { outputs.forEach { try? FileManager.default.removeItem(at: $0) } }
    for fixture in ["rotated-vfr-tap.mp4", "hdr10-tap.mp4"] {
      let source = nativeFixtureURL(fixture)
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
      let output = temporaryURL("\(fixture).normalized.mp4")
      outputs.append(output)
      print("VIDEO_VARIANT_START fixture=\(fixture) time=\(Date().timeIntervalSince1970)")
      _ = try await renderer.render(
        request: try decodeRequest(quality: "preview", layout: "sequentialFocus"),
        assets: ["tap": source, "sustain": source, "texture": source],
        outputURL: output,
        cancellation: CancellationToken(operationId: fixture)
      )
      let name = fixture.replacingOccurrences(of: ".mp4", with: "")
      try preserveMovie(output, name: name)
      _ = try await validateAndPersist(
        output,
        name: name,
        expectedWidth: 360,
        expectedHeight: 640
      )
      print("VIDEO_VARIANT_END fixture=\(fixture) time=\(Date().timeIntervalSince1970)")
    }
  }

  private func decodeRequest(quality: String, layout: String) throws
    -> VideoRenderRequestPayload
  {
    let ids = ["tap", "sustain", "texture"]
    let event: [String: Any] = [
      "assetId": "tap",
      "sourceStartSample": 0,
      "destinationStartSample": 0,
      "durationSamples": 720_000,
      "gain": 1.0,
      "fades": ["fadeInSamples": 0, "fadeOutSamples": 120],
    ]
    let videoEvent: [String: Any] = [
      "assetId": "tap",
      "destinationStartSample": 0,
      "durationSamples": 720_000,
      "sourceVideoStartTime": ["numerator": 0, "denominator": 48_000],
      "crop": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
      "loopMode": "loop",
    ]
    let arrangement: [String: Any] = [
      "schemaVersion": 1,
      "sampleRate": 48_000,
      "totalSamples": 720_000,
      "templateId": "video-fixture",
      "templateVersion": 1,
      "analysisVersion": 1,
      "rendererVersion": 1,
      "seed": 1,
      "style": "sparse",
      "sourceAssetIds": ids,
      "unusableAssetIds": [],
      "events": [event],
      "videoEvents": [videoEvent],
    ]
    let scene: [String: Any] = [
      "destinationStartSample": 0,
      "durationSamples": 720_000,
      "assetIds": ids,
      "primaryAssetId": NSNull(),
    ]
    let video: [String: Any] = [
      "schemaVersion": 1,
      "layout": layout,
      "clipCrops": ids.map {
        [
          "assetId": $0,
          "crop": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
        ]
      },
      "captions": [],
      "events": [scene],
      "effects": ["enabled": []],
    ]
    let json: [String: Any] = [
      "schemaVersion": 1,
      "operationId": "render-\(quality)",
      "projectId": "project",
      "revision": 4,
      "arrangement": arrangement,
      "video": video,
      "quality": quality,
    ]
    return try JSONDecoder().decode(
      VideoRenderRequestPayload.self,
      from: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    )
  }

  private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("assets/demo/source/\(name)")
  }

  private func nativeFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("test/fixtures/native/\(name)")
  }

  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString)-\(name)")
  }

  private func evidenceDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let directory = root.appendingPathComponent("ci-artifacts", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func preserveMovie(_ output: URL, name: String) throws {
    let movie = try evidenceDirectory().appendingPathComponent("video-render-\(name).mp4")
    try? FileManager.default.removeItem(at: movie)
    try FileManager.default.copyItem(at: output, to: movie)
    attach(movie)
  }

  private func validateAndPersist(
    _ output: URL,
    name: String,
    expectedWidth: Int,
    expectedHeight: Int
  ) async throws
    -> MediaValidationReport
  {
    do {
      let validation = try await MediaValidator().validate(
        url: output,
        expectedWidth: expectedWidth,
        expectedHeight: expectedHeight,
        expectedOnsetSample: 12_000,
        expectedVideoCueFrame: 8
      )
      try preserveReport(validation, name: name)
      return validation
    } catch MediaValidationError.metricsOutsideTolerance(let validation) {
      try preserveReport(validation, name: name)
      throw MediaValidationError.metricsOutsideTolerance(validation)
    }
  }

  private func preserveReport(_ validation: MediaValidationReport, name: String) throws {
    let report = try evidenceDirectory().appendingPathComponent("video-render-\(name).json")
    let data = try JSONEncoder().encode(validation)
    try data.write(to: report, options: .atomic)
    print("VIDEO_VALIDATION name=\(name) json=\(String(decoding: data, as: UTF8.self))")
    attach(report)
  }

  private func attach(_ url: URL) {
    let attachment = XCTAttachment(contentsOfFile: url)
    attachment.name = url.lastPathComponent
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
