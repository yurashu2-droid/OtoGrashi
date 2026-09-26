import AVFoundation
import XCTest
@testable import Runner

final class VideoRendererTests: XCTestCase {
  /// Every mode, the 1080p movie and the rotated/HDR sources are rendered on
  /// main, pull requests and manual runs (OTO_FULL_CHECKS=1). Ordinary pushes
  /// render a representative subset so a check stays within a few minutes.
  private var fullChecks: Bool {
    ProcessInfo.processInfo.environment["OTO_FULL_CHECKS"] == "1"
  }

  func testVideoUsesTheSameLoopAndReverseSourceClockAsAudio() throws {
    for reverse in [false, true] {
      let event = VideoEventPayload(assetId: "voice", destinationStartSample: 12_000,
        durationSamples: 96_000,
        sourceVideoStartTime: RationalTimePayload(numerator: 24_000, denominator: 48_000),
        crop: NormalizedCropPayload(x: 0, y: 0, width: 1, height: 1), loopMode: .loop,
        sourceDurationSamples: 9_600, reverse: reverse, mirror: true)
      for offset in [0, 1_600, 9_599, 9_600, 38_000, 95_999] {
        let actual = VideoRenderer.sourceTime(assetId: "voice", sample: 12_000 + offset,
          events: [event], duration: CMTime(seconds: 6, preferredTimescale: 48_000))
        let mapped = 24_000 + EverydayAudioDSP.sourceOffset(outputOffset: offset,
          sourceCount: 9_600, reverse: reverse)
        XCTAssertEqual(CMTimeGetSeconds(actual), Double(mapped) / 48_000, accuracy: 1e-8)
      }
      let range = try XCTUnwrap(VideoRenderer.sourceRangesByAsset(videoEvents: [event])["voice"]?.first)
      XCTAssertEqual(CMTimeGetSeconds(range.duration), 0.2, accuracy: 1e-8)
    }
  }

  func testSixAudibleVideosHaveSixInBoundsPanels() {
    for layout in [VideoLayoutPayload.buildUp, .stacked, .sequentialFocus, .photoDump] {
      let panels = VideoRenderer.targetRects(count: 6, layout: layout, width: 360, height: 640)
      XCTAssertEqual(panels.count, 6)
      XCTAssertTrue(panels.allSatisfy { CGRect(x: 0, y: 0, width: 360, height: 640).contains($0) })
    }
  }

  func testRealDartEverydayTimelineRendersAsSynchronizedMADVideo() async throws {
    let directory = try evidenceDirectory()
    let requestURL = directory.appendingPathComponent("everyday-mad-request.json")
    guard FileManager.default.fileExists(atPath: requestURL.path) else {
      throw XCTSkip("Run flutter test test/domain/everyday_native_fixture_test.dart before native tests.")
    }
    let request = try JSONDecoder().decode(VideoRenderRequestPayload.self, from: Data(contentsOf: requestURL))
    let output = temporaryURL("everyday-mad.mp4")
    defer { try? FileManager.default.removeItem(at: output) }
    let report = try await VideoRenderer(audioRenderer: AudioRenderer(accompanimentGain: 0)).render(
      request: request,
      assets: ["tap": fixtureURL("synthetic-tap.mp4"), "sustain": fixtureURL("synthetic-sustain.mp4"),
        "texture": fixtureURL("synthetic-texture.mp4")], outputURL: output,
      cancellation: CancellationToken(operationId: "everyday-mad"))
    XCTAssertEqual(report.frameCount, 450)
    let asset = AVURLAsset(url: output)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    XCTAssertEqual(CMTimeGetSeconds(duration), 15, accuracy: 0.034)
    XCTAssertEqual(tracks.count, 1)
    try preserveMovie(output, name: "everyday-mad")
  }

  func testPerformancePanelsStayOnCanvas() {
    for mode in ["mosaic", "vinyl", "sampler", "voiceLead", "neonTune", "loopStation"] {
      for count in 1...18 {
        let panels = VideoRenderer.performanceRects(count: count, mode: mode, width: 360, height: 640)
        XCTAssertEqual(panels.count, count)
        XCTAssertTrue(panels.allSatisfy { $0.width > 0 && $0.height > 0 &&
          CGRect(x: 0, y: 0, width: 360, height: 640).contains($0) }, "\(mode) \(count)")
      }
    }
  }

  func testPerformanceModesRenderWithProductionValidation() async throws {
    let directory = try evidenceDirectory()
    let modes = fullChecks
      ? ["mad", "mosaic", "vinyl", "sampler", "voiceLead", "neonTune", "loopStation"]
      : ["mad", "mosaic"]
    print("MAD_CHECK full=\(fullChecks) modes=\(modes)")
    for mode in modes {
      let requestURL = directory.appendingPathComponent("native-\(mode).json")
      // Missing fixtures are a failure, not a silently skipped feature test.
      let request = try JSONDecoder().decode(VideoRenderRequestPayload.self, from: Data(contentsOf: requestURL))
      let output = temporaryURL("performance-\(mode).mp4")
      defer { try? FileManager.default.removeItem(at: output) }
      let report = try await VideoRenderer(audioRenderer: AudioRenderer(accompanimentGain: 0)).render(
        request: request,
        assets: ["tap": fixtureURL("synthetic-tap.mp4"), "sustain": fixtureURL("synthetic-sustain.mp4"),
          "texture": fixtureURL("synthetic-texture.mp4")], outputURL: output,
        cancellation: CancellationToken(operationId: request.operationId))
      XCTAssertEqual(report.frameCount, request.arrangement.totalSamples / 1600)
      let validation = try await MediaValidator().validate(url: output, expectedWidth: 360,
        expectedHeight: 640, expectedOnsetSample: nil, expectedTotalSamples: request.arrangement.totalSamples)
      XCTAssertEqual(validation.durationUs, Int64(request.arrangement.totalSamples) * 1_000_000 / 48_000)
      try preserveMovie(output, name: "performance-\(mode)")
      try preserveReport(validation, name: "performance-\(mode)")
    }
  }

  private enum ProducerFailure: Error, Equatable { case audio }

  func testProducerErrorPrecedencePreservesFailuresButNotCancellationArtifacts() {
    let primary = VideoRenderError.cancelled

    XCTAssertEqual(
      VideoRenderer.preferredProducerError(primary: primary, audio: ProducerFailure.audio)
        as? ProducerFailure,
      .audio
    )
    XCTAssertEqual(
      VideoRenderer.preferredProducerError(primary: primary, audio: VideoRenderError.cancelled)
        as? VideoRenderError,
      .cancelled
    )
    XCTAssertEqual(
      VideoRenderer.preferredProducerError(primary: primary, audio: CancellationError())
        as? VideoRenderError,
      .cancelled
    )
  }

  func testWriterProgressWatchdogTracksEitherProducerAndDetectsAFullStall() {
    var now: UInt64 = 0
    let progress = VideoWriterProgress(now: { now })
    var stalled = false
    let watchdog = VideoWriterWatchdog(progress: progress) { stalled = true }

    XCTAssertFalse(watchdog.check())
    now = VideoWriterProgress.watchdogNanoseconds
    XCTAssertTrue(watchdog.check())
    XCTAssertTrue(stalled)

    // A successful append from either producer resets the aggregate watchdog.
    now = 0
    let activeProgress = VideoWriterProgress(now: { now })
    var activeStalled = false
    let activeWatchdog = VideoWriterWatchdog(progress: activeProgress) {
      activeStalled = true
    }
    now = VideoWriterProgress.watchdogNanoseconds - 1
    activeProgress.markProgress()
    now += VideoWriterProgress.watchdogNanoseconds - 1
    XCTAssertFalse(activeWatchdog.check())
    now += 2
    XCTAssertTrue(activeWatchdog.check())
    XCTAssertTrue(activeStalled)

    // A frozen writer fires once, so cancellation/drain can be coordinated once.
    XCTAssertTrue(activeWatchdog.check())
    XCTAssertTrue(activeStalled)

    now = 0
    progress.markProgress()
    XCTAssertTrue(watchdog.check())
  }

  func testSourceTimestampIgnoresZeroSampleMarkerButRejectsInvalidMediaPTS() throws {
    var marker: CMSampleBuffer?
    XCTAssertEqual(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault,
        dataBuffer: nil,
        formatDescription: nil,
        sampleCount: 0,
        sampleTimingEntryCount: 0,
        sampleTimingArray: nil,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &marker
      ),
      noErr
    )
    XCTAssertNil(try VideoRenderer.sourceTimestamp(from: try XCTUnwrap(marker)))

    XCTAssertThrowsError(
      try VideoRenderer.sourceTimestamp(
        sampleCount: 1,
        presentationTimestamp: .invalid
      )
    )
  }

  func testSourceTimestampScanAcceptsAllThreeVideoFixtures() async throws {
    let fixtures = [
      fixtureURL("synthetic-tap.mp4"),
      nativeFixtureURL("rotated-vfr-tap.mp4"),
      nativeFixtureURL("hdr10-tap.mp4"),
    ]
    let renderer = VideoRenderer()
    for url in fixtures {
      let asset = AVURLAsset(url: url)
      let tracks = try await asset.loadTracks(withMediaType: .video)
      let track = try XCTUnwrap(tracks.first)
      let timestamps = try renderer.sourceTimestamps(asset: asset, track: track)
      XCTAssertFalse(timestamps.isEmpty)
      XCTAssertTrue(timestamps.allSatisfy(\.isNumeric))
    }
  }

  func testLongOriginalShortSelectionUsesBoundedTimestampScan() async throws {
    let source = nativeFixtureURL("long-original-tap.mp4")
    let asset = AVURLAsset(url: source)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try XCTUnwrap(tracks.first)
    let renderer = VideoRenderer()

    XCTAssertThrowsError(
      try renderer.sourceTimestamps(asset: asset, track: track)
    )

    let selected = CMTimeRange(
      start: CMTime(seconds: 45, preferredTimescale: 48_000),
      duration: CMTime(seconds: 6, preferredTimescale: 48_000)
    )
    let timestamps = try renderer.sourceTimestamps(
      asset: asset,
      track: track,
      timeRanges: [selected]
    )
    XCTAssertGreaterThan(timestamps.count, 150)
    XCTAssertLessThan(timestamps.count, 220)
    XCTAssertGreaterThanOrEqual(
      CMTimeGetSeconds(timestamps.first!),
      44.9
    )
    XCTAssertLessThanOrEqual(
      CMTimeGetSeconds(timestamps.last!),
      51.1
    )
  }

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

  func testTrimmedSourceWindowsBoundReaderRangesAndLoopTime() throws {
    let first = VideoEventPayload(
      assetId: "long",
      destinationStartSample: 0,
      durationSamples: 288_000,
      sourceVideoStartTime: RationalTimePayload(numerator: 9_600_000, denominator: 48_000),
      crop: NormalizedCropPayload(x: 0, y: 0, width: 1, height: 1),
      loopMode: .hold
    )
    let repeated = VideoEventPayload(
      assetId: "long",
      destinationStartSample: 288_000,
      durationSamples: 288_000,
      sourceVideoStartTime: RationalTimePayload(numerator: 9_600_000, denominator: 48_000),
      crop: NormalizedCropPayload(x: 0, y: 0, width: 1, height: 1),
      loopMode: .loop
    )

    let ranges = VideoRenderer.sourceRangesByAsset(videoEvents: [first, repeated])
    let range = try XCTUnwrap(ranges["long"]?.first)
    XCTAssertEqual(CMTimeCompare(range.start, CMTime(seconds: 200, preferredTimescale: 48_000)), 0)
    XCTAssertEqual(CMTimeGetSeconds(range.duration), 6, accuracy: 0.0001)

    let duration = CMTime(seconds: 600, preferredTimescale: 48_000)
    let held = VideoRenderer.sourceTime(
      assetId: "long",
      sample: 287_999,
      events: [first],
      duration: duration
    )
    XCTAssertEqual(CMTimeGetSeconds(held), 205.999979, accuracy: 0.001)

    let looped = VideoRenderer.sourceTime(
      assetId: "long",
      sample: 288_000 + 168_000,
      events: [repeated],
      duration: duration
    )
    XCTAssertEqual(CMTimeGetSeconds(looped), 203.5, accuracy: 0.001)
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

  func testBuildUpGrowsFromFullFrameToBassLaneAndTwoUpperClips() {
    let solo = VideoRenderer.targetRects(count: 1, layout: .buildUp, width: 360, height: 640)
    let duo = VideoRenderer.targetRects(count: 2, layout: .buildUp, width: 360, height: 640)
    let trio = VideoRenderer.targetRects(count: 3, layout: .buildUp, width: 360, height: 640)
    XCTAssertEqual(solo.count, 1)
    XCTAssertEqual(solo[0].height, 640)
    XCTAssertEqual(duo.count, 2)
    XCTAssertLessThan(duo[0].midY, duo[1].midY)
    XCTAssertEqual(trio.count, 3)
    XCTAssertEqual(trio[0].width, 360)
    XCTAssertEqual(trio[1].width, 180)
    XCTAssertEqual(trio[2].width, 180)
    let cues = (0..<4).map { index in
      SoundEventPayload(
        assetId: "typing",
        sourceStartSample: 0,
        destinationStartSample: 312_000 + index * 3_000,
        durationSamples: 12_000,
        gain: 0.6,
        fades: EventFadesPayload(fadeInSamples: 0, fadeOutSamples: 120),
        pitchSemitones: nil
      )
    }
    XCTAssertEqual(VideoRenderer.buildUpTileCount(assetId: "typing", sample: 312_000, events: cues), 1)
    XCTAssertEqual(VideoRenderer.buildUpTileCount(assetId: "typing", sample: 315_000, events: cues), 2)
    XCTAssertEqual(VideoRenderer.buildUpTileCount(assetId: "typing", sample: 321_000, events: cues), 4)
    XCTAssertEqual(VideoRenderer.buildUpTileCount(assetId: "typing", sample: 333_000, events: cues), 1)
    XCTAssertEqual(VideoRenderer.tileRects(in: duo[1], count: 4).count, 4)
  }

  func testCaptionAnchorStaysInsideTheVerticalVideo() {
    for x in [0.0, 0.5, 1.0] {
      for y in [0.0, 0.22, 1.0] {
        let caption = VideoCaptionPayload(
          text: "わっ！", x: x, y: y,
          destinationStartSample: 0, durationSamples: 72_000
        )
        let rect = VideoRenderer.captionRect(for: caption, width: 360, height: 640)
        XCTAssertGreaterThanOrEqual(rect.minX, 28)
        XCTAssertLessThanOrEqual(rect.maxX, 332)
        XCTAssertGreaterThanOrEqual(rect.minY, 50)
        XCTAssertLessThanOrEqual(rect.maxY, 590)
      }
    }
  }

  func testNamedSoundAppearsOnlyWhileItsVisibleEventIsAudible() {
    let event = SoundEventPayload(
      assetId: "reaction", sourceStartSample: 0,
      destinationStartSample: 12_000, durationSamples: 9_000,
      gain: 0.8, fades: EventFadesPayload(fadeInSamples: 0, fadeOutSamples: 0),
      pitchSemitones: nil
    )
    let names = ["reaction": "友達のわっ！", "silent": "表示しない"]
    XCTAssertEqual(VideoRenderer.namedActiveAssetIds(
      names: names, events: [event], sample: 12_000,
      visibleAssetIds: ["reaction", "silent"]
    ), ["reaction"])
    XCTAssertTrue(VideoRenderer.namedActiveAssetIds(
      names: names, events: [event], sample: 21_000,
      visibleAssetIds: ["reaction", "silent"]
    ).isEmpty)
    XCTAssertTrue(VideoRenderer.namedActiveAssetIds(
      names: names, events: [event], sample: 12_000,
      visibleAssetIds: ["silent"]
    ).isEmpty)
  }

  func testVideoUsesTheCurrentlySoundingSourceEvent() {
    let firstEvent = VideoEventPayload(
      assetId: "bass",
      destinationStartSample: 0,
      durationSamples: 12_000,
      sourceVideoStartTime: RationalTimePayload(numerator: 48_000, denominator: 48_000),
      crop: NormalizedCropPayload(x: 0, y: 0, width: 1, height: 1),
      loopMode: .hold
    )
    let nextEvent = VideoEventPayload(
      assetId: "bass",
      destinationStartSample: 270_000,
      durationSamples: 12_000,
      sourceVideoStartTime: RationalTimePayload(numerator: 96_000, denominator: 48_000),
      crop: NormalizedCropPayload(x: 0, y: 0, width: 1, height: 1),
      loopMode: .hold
    )
    let duration = CMTime(seconds: 3, preferredTimescale: 48_000)
    let time = VideoRenderer.sourceTime(
      assetId: "bass", sample: 270_000 + 3_000,
      events: [firstEvent, nextEvent], duration: duration
    )
    XCTAssertEqual(CMTimeGetSeconds(time), 2.0625, accuracy: 0.001)
  }

  func testLoopingVideoHoldsTheLastFrameWhenSoundStops() {
    let event = VideoEventPayload(
      assetId: "reaction",
      destinationStartSample: 0,
      durationSamples: 9_000,
      sourceVideoStartTime: RationalTimePayload(numerator: 48_000, denominator: 48_000),
      crop: NormalizedCropPayload(x: 0, y: 0, width: 1, height: 1),
      loopMode: .loop
    )
    let time = VideoRenderer.sourceTime(
      assetId: "reaction", sample: 45_000,
      events: [event], duration: CMTime(seconds: 3, preferredTimescale: 48_000)
    )
    XCTAssertEqual(CMTimeGetSeconds(time), 1.18748, accuracy: 0.001)
  }

  func testSequentialFocusUsesPrimaryAssetWhenSceneContainsMultipleSources() {
    let scene = VideoSceneEventPayload(
      destinationStartSample: 0,
      durationSamples: 720_000,
      assetIds: ["tap", "sustain", "texture"],
      primaryAssetId: "sustain"
    )

    XCTAssertEqual(
      VideoRenderer.visibleAssetIds(scene: scene, layout: .sequentialFocus),
      ["sustain"]
    )
    XCTAssertEqual(
      VideoRenderer.visibleAssetIds(
        scene: VideoSceneEventPayload(
          destinationStartSample: 0,
          durationSamples: 720_000,
          assetIds: ["tap", "sustain", "texture"],
          primaryAssetId: nil
        ),
        layout: .sequentialFocus
      ),
      ["tap"]
    )
    XCTAssertEqual(
      VideoRenderer.visibleAssetIds(scene: scene, layout: .stacked),
      ["tap", "sustain", "texture"]
    )
  }

  func testAllLayoutsDecodeWithBarBoundaryScenesAndEverySource() throws {
    for layout in ["buildUp", "stacked", "sequentialFocus", "photoDump"] {
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
    let assets = [
      "tap": sourceURL,
      "sustain": fixtureURL("synthetic-sustain.mp4"),
      "texture": fixtureURL("synthetic-texture.mp4"),
    ]
    let renderer = VideoRenderer(
      audioRenderer: AudioRenderer(accompanimentGain: 0)
    )
    var outputs: [URL] = []
    defer {
      outputs.forEach {
        if FileManager.default.fileExists(atPath: $0.path) {
          try? FileManager.default.removeItem(at: $0)
        }
      }
    }

    for quality in fullChecks ? ["preview", "full"] : ["preview"] {
      print("VIDEO_RENDER_START quality=\(quality) time=\(Date().timeIntervalSince1970)")
      let request = try decodeRequest(
        quality: quality,
        layout: quality == "preview" ? "buildUp" : "stacked",
        captionText: quality == "preview" ? "わっ！" : nil
      )
      let output = temporaryURL("\(quality).mp4")
      outputs.append(output)
      let report: VideoRenderReport
      do {
        report = try await renderer.render(
          request: request,
          assets: assets,
          outputURL: output,
          cancellation: CancellationToken(operationId: quality)
        )
      } catch {
        let nsError = error as NSError
        print("VIDEO_RENDER_ERROR reflected=\(String(reflecting: error))")
        print(
          "VIDEO_RENDER_NSERROR domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
        )
        XCTFail("render failed: \(String(reflecting: error))")
        return
      }
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
    guard fullChecks else { throw XCTSkip("Rendered in full checks only.") }
    let renderer = VideoRenderer(audioRenderer: AudioRenderer(accompanimentGain: 0))
    var outputs: [URL] = []
    defer {
      outputs.forEach {
        if FileManager.default.fileExists(atPath: $0.path) {
          try? FileManager.default.removeItem(at: $0)
        }
      }
    }
    for fixture in ["rotated-vfr-tap.mp4", "hdr10-tap.mp4"] {
      let source = nativeFixtureURL(fixture)
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
      let output = temporaryURL("\(fixture).normalized.mp4")
      outputs.append(output)
      print("VIDEO_VARIANT_START fixture=\(fixture) time=\(Date().timeIntervalSince1970)")
      do {
        _ = try await renderer.render(
          request: try decodeRequest(quality: "preview", layout: "sequentialFocus"),
          assets: ["tap": source, "sustain": source, "texture": source],
          outputURL: output,
          cancellation: CancellationToken(operationId: fixture)
        )
      } catch {
        let nsError = error as NSError
        print("VIDEO_VARIANT_ERROR reflected=\(String(reflecting: error))")
        print(
          "VIDEO_VARIANT_NSERROR domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)"
        )
        #if targetEnvironment(simulator)
        if fixture == "hdr10-tap.mp4" &&
          nsError.domain == AVFoundationErrorDomain && nsError.code == -11821 {
          throw XCTSkip("This iOS Simulator cannot decode the HEVC Main 10 HDR fixture; verify on a physical iPhone.")
        }
        #endif
        XCTFail("variant render failed: \(String(reflecting: error))")
        return
      }
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

  private func decodeRequest(quality: String, layout: String, captionText: String? = nil) throws
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
    let rhythmCues: [(assetId: String, start: Int)] = layout == "buildUp"
      ? [("sustain", 312_000), ("sustain", 324_000),
        ("sustain", 336_000), ("sustain", 348_000),
        ("texture", 600_000)] : []
    let soundEvents = [event] + rhythmCues.map { cue -> [String: Any] in
      [
        "assetId": cue.assetId,
        "sourceStartSample": 0,
        "destinationStartSample": cue.start,
        "durationSamples": 12_000,
        "gain": 0.6,
        "fades": ["fadeInSamples": 0, "fadeOutSamples": 120],
      ]
    }
    let videoEvents = [videoEvent] + rhythmCues.map { cue -> [String: Any] in
      [
        "assetId": cue.assetId,
        "destinationStartSample": cue.start,
        "durationSamples": 12_000,
        "sourceVideoStartTime": ["numerator": 0, "denominator": 48_000],
        "crop": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
        "loopMode": "once",
      ]
    }
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
      "events": soundEvents,
      "videoEvents": videoEvents,
    ]
    let scene: [String: Any] = [
      "destinationStartSample": 0,
      "durationSamples": 720_000,
      "assetIds": ids,
      "primaryAssetId": NSNull(),
    ]
    let buildUpGroups = [
      [ids[0]], [ids[1]], [ids[2]], [ids[0], ids[1]],
      [ids[0], ids[2]], ids, ids, ids,
    ]
    let scenes: [[String: Any]] = layout == "buildUp"
      ? buildUpGroups.enumerated().map { bar, group in
          [
            "destinationStartSample": bar * 90_000,
            "durationSamples": 90_000,
            "assetIds": group,
            "primaryAssetId": group[0],
          ]
        }
      : [scene]
    let captions: [[String: Any]] = captionText.map { text in
      [[
        "text": text,
        "x": 0.5,
        "y": 0.22,
        "destinationStartSample": 0,
        "durationSamples": 72_000,
      ]]
    } ?? []
    let video: [String: Any] = [
      "schemaVersion": 1,
      "layout": layout,
      "clipCrops": ids.map {
        [
          "assetId": $0,
          "crop": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
        ]
      },
      "captions": captions,
      "events": scenes,
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
