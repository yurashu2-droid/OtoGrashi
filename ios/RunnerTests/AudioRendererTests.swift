import AVFoundation
import XCTest
@testable import Runner

final class AudioRendererTests: XCTestCase {
  func testPCMPlacementUsesAbsoluteBufferPTSAndPreservesTimelineGaps() throws {
    var timeline = Array(repeating: Float(0), count: 10)

    let covered = NativePCMReader().place(
      values: [0.25, 0.5, 0.75],
      bufferStartSample: 105,
      requestedRange: 100..<110,
      into: &timeline
    )

    XCTAssertEqual(covered, 105..<108)
    XCTAssertEqual(timeline, [0, 0, 0, 0, 0, 0.25, 0.5, 0.75, 0, 0])
  }

  func testPitchShiftKeepsDurationAndRaisesSustainedTone() throws {
    let source = (0..<24_000).map { frame in
      Float(sin(2 * Double.pi * 220 * Double(frame) / 48_000) * 0.5)
    }
    let renderer = AudioRenderer(accompanimentGain: 0)
    let shifted = try renderer.pitchPreservingDuration(source, semitones: 3)
    let fractional = try renderer.pitchPreservingDuration(source, semitones: 1.25)
    XCTAssertEqual(shifted.count, source.count)
    XCTAssertEqual(fractional.count, source.count)
    XCTAssertTrue(fractional.allSatisfy(\.isFinite))
    XCTAssertEqual(try renderer.pitchPreservingDuration(source, semitones: 0), source)
    XCTAssertTrue(shifted.allSatisfy(\.isFinite))
    XCTAssertGreaterThan(shifted.suffix(2_400).map(\.magnitude).max() ?? 0, 0.05)
    XCTAssertGreaterThan(toneEnergy(shifted, hertz: 261.6), toneEnergy(source, hertz: 261.6) * 3)

    var json = validJSON(
      sourceDuration: source.count,
      destinationStart: 0,
      eventDuration: source.count,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )
    XCTAssertEqual(try decode(json).events[0].effectivePitchSemitones, 0)
    var event = (json["events"] as! [[String: Any]])[0]
    event["pitchSemitones"] = 4
    json["events"] = [event]
    XCTAssertThrowsError(try decode(json)) { error in
      XCTAssertEqual(error as? AudioRenderError, .eventOutOfBounds)
    }
  }

  func testOfflinePitchShiftMovesLowAndHighVoicesInBothDirections() throws {
    let renderer = AudioRenderer(accompanimentGain: 0)
    for frequency in [110.0, 440.0] {
      let source = (0..<24_000).map { frame in
        Float(sin(2 * Double.pi * frequency * Double(frame) / 48_000) * 0.4)
      }
      for semitones in [-3.0, 3.0] {
        let shifted = try renderer.pitchPreservingDuration(source, semitones: semitones)
        let target = frequency * pow(2, semitones / 12)
        XCTAssertEqual(shifted.count, source.count)
        XCTAssertTrue(shifted.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(
          toneEnergy(shifted, hertz: target),
          toneEnergy(shifted, hertz: frequency) * 2,
          "\(frequency) Hz shifted by \(semitones) semitones"
        )
      }
    }
  }

  func testOfflinePitchShiftAlignsImpulseAndPreservesTheLastAudibleSamples() throws {
    let renderer = AudioRenderer(accompanimentGain: 0)
    var source = Array(repeating: Float(0), count: 18_000)
    source[2_400] = 0.8
    for frame in 15_000..<17_000 {
      source[frame] = Float(sin(2 * Double.pi * 220 * Double(frame) / 48_000) * 0.3)
    }
    let shifted = try renderer.pitchPreservingDuration(source, semitones: -3)
    let impulsePeak = try XCTUnwrap(
      shifted[0..<4_800].indices.max(by: {
        abs(shifted[$0]) < abs(shifted[$1])
      })
    )
    XCTAssertEqual(shifted.count, source.count)
    XCTAssertLessThanOrEqual(abs(impulsePeak - 2_400), 960)
    XCTAssertGreaterThan(shifted[15_000..<17_500].map(\.magnitude).max() ?? 0, 0.05)
  }

  func testOfflinePitchShiftRejectsNonFiniteInputAndHonorsCancellation() throws {
    let renderer = AudioRenderer(accompanimentGain: 0)
    var source = Array(repeating: Float(0.2), count: 4_800)
    source[2_400] = .nan
    XCTAssertThrowsError(try renderer.pitchPreservingDuration(source, semitones: 2)) {
      XCTAssertEqual($0 as? AudioRenderError, .pitchProcessingFailed)
    }
    let token = CancellationToken(operationId: "pitch-cancelled")
    token.cancel()
    XCTAssertThrowsError(
      try renderer.pitchPreservingDuration(
        Array(repeating: Float(0.2), count: 4_800),
        semitones: 2,
        cancellation: token
      )
    ) {
      XCTAssertEqual($0 as? AudioRenderError, .cancelled)
    }
    XCTAssertThrowsError(
      try renderer.pitchPreservingDuration(
        Array(repeating: Float(0.2), count: ArrangementPayload.totalSamples + 1),
        semitones: 2
      )
    ) {
      XCTAssertEqual($0 as? AudioRenderError, .pitchProcessingFailed)
    }
  }

  func testPitchedEventKeepsItsVideoClockPositionInTheWrittenMix() async throws {
    var source = Array(repeating: Float(0), count: 18_000)
    source[2_400] = 0.8
    let sourceURL = try makeMonoFile(samples: source)
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }
    var json = validJSON(
      sourceDuration: source.count,
      destinationStart: 90_000,
      eventDuration: source.count,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )
    var event = (json["events"] as! [[String: Any]])[0]
    event["pitchSemitones"] = 3
    json["events"] = [event]

    let report = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: try decode(json),
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "pitched-onset")
    )
    let rendered = try readMonoFile(outputURL)
    let pulse = try XCTUnwrap(
      rendered[90_000..<94_800].indices.max(by: {
        abs(rendered[$0]) < abs(rendered[$1])
      })
    )
    XCTAssertEqual(report.sampleCount, ArrangementPayload.totalSamples)
    XCTAssertEqual(report.nonFiniteCount, 0)
    XCTAssertLessThanOrEqual(abs(pulse - 92_400), 960)
    XCTAssertGreaterThan(abs(rendered[pulse]), 0.05)
  }

  private func toneEnergy(_ samples: [Float], hertz: Double) -> Double {
    var real = 0.0
    var imaginary = 0.0
    for frame in 4_800..<19_200 {
      let phase = 2 * Double.pi * hertz * Double(frame) / 48_000
      real += Double(samples[frame]) * cos(phase)
      imaginary += Double(samples[frame]) * sin(phase)
    }
    return hypot(real, imaginary)
  }

  func testPCMReaderHonorsCancellationBeforeOpeningTheAsset() throws {
    let token = CancellationToken(operationId: "reader-cancelled")
    token.cancel()
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")

    XCTAssertThrowsError(
      try NativePCMReader().readTimeline(
        url: missing,
        startSample: 0,
        durationSamples: 480,
        cancellation: token
      )
    ) { error in
      XCTAssertEqual(error as? AudioRenderError, .cancelled)
    }
  }

  func testRenderUsesOriginalAudioAtRequestedDestinationAndWritesExactClock() async throws {
    var source = Array(repeating: Float(0), count: 4_800)
    source[120] = 0.75
    let sourceURL = try makeMonoFile(samples: source)
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }
    let arrangement = try payload(
      sourceDuration: source.count,
      destinationStart: 90_000,
      eventDuration: source.count,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )

    let report = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: arrangement,
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "onset")
    )

    XCTAssertEqual(report.sampleCount, 720_000)
    XCTAssertEqual(report.fileLength, 720_000)
    XCTAssertEqual(report.readChunkFrameCounts.reduce(0, +), 720_000)
    XCTAssertEqual(report.sampleRate, 48_000)
    XCTAssertEqual(report.channels, 1)
    XCTAssertEqual(report.nonFiniteCount, 0)
    XCTAssertLessThanOrEqual(report.peak, 1)
    XCTAssertLessThanOrEqual(abs(try firstAudibleSample(outputURL) - 90_120), 1)
  }

  func testSustainedShortSourceRepeatsWithCrossfadedSeams() async throws {
    let period = 4_800
    let source = (0..<period).map { frame in
      Float(sin(Double(frame) * 2 * .pi * 223 / 48_000) * 0.4)
    }
    let sourceURL = try makeMonoFile(samples: source)
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }
    let arrangement = try payload(
      sourceDuration: source.count,
      destinationStart: 0,
      eventDuration: 12_000,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "hold"
    )

    _ = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: arrangement,
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "sustain")
    )
    let rendered = try readMonoFile(outputURL)

    XCTAssertGreaterThan(rendered[5_000].magnitude, 0.001)
    XCTAssertLessThan(abs(rendered[4_560] - rendered[4_559]), 0.12)
    XCTAssertLessThan(abs(rendered[4_800] - rendered[4_799]), 0.12)
    XCTAssertLessThan(abs(rendered[9_120] - rendered[9_119]), 0.12)
    XCTAssertLessThan(abs(rendered[9_600] - rendered[9_599]), 0.12)
  }

  func testTransientKeepsShortSourceMarginsAroundTheScheduledOnset() async throws {
    var source = Array(repeating: Float(0), count: 3_000)
    for index in 760..<1_000 { source[index] = 0.04 }
    source[1_000] = 0.8
    for index in 1_480..<1_720 { source[index] = 0.03 }
    let sourceURL = try makeMonoFile(samples: source)
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }
    var json = validJSON(
      sourceDuration: source.count,
      destinationStart: 90_000,
      eventDuration: 480,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )
    var event = (json["events"] as! [[String: Any]])[0]
    event["sourceStartSample"] = 1_000
    json["events"] = [event]
    var video = (json["videoEvents"] as! [[String: Any]])[0]
    video["sourceVideoStartTime"] = ["numerator": 1_000, "denominator": 48_000]
    json["videoEvents"] = [video]

    _ = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: try decode(json),
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "margins")
    )
    let rendered = try readMonoFile(outputURL)

    XCTAssertGreaterThan(rendered[89_880].magnitude, 0.001)
    XCTAssertGreaterThan(rendered[90_000].magnitude, 0.1)
    XCTAssertGreaterThan(rendered[90_600].magnitude, 0.001)
  }

  func testNonFiniteAndClippingInputsProduceFiniteLimitedOutput() async throws {
    var source = Array(repeating: Float(8), count: 4_800)
    source[100] = .nan
    source[101] = .infinity
    let sourceURL = try makeMonoFile(samples: source)
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }

    let report = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: try payload(
        sourceDuration: source.count,
        destinationStart: 0,
        eventDuration: source.count,
        fadeIn: 0,
        fadeOut: 0,
        loopMode: "once"
      ),
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "finite")
    )

    XCTAssertEqual(report.nonFiniteCount, 0)
    XCTAssertLessThanOrEqual(report.peak, 1)
    XCTAssertTrue(try readMonoFile(outputURL).allSatisfy(\.isFinite))
  }

  func testNormalizationGainIsCappedForVeryQuietSource() async throws {
    let source = Array(repeating: Float(0.000_1), count: 4_800)
    let sourceURL = try makeMonoFile(samples: source)
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }

    let report = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: try payload(
        sourceDuration: source.count,
        destinationStart: 0,
        eventDuration: source.count,
        fadeIn: 0,
        fadeOut: 0,
        loopMode: "once"
      ),
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "quiet")
    )

    XCTAssertGreaterThan(report.peak, 0)
    XCTAssertLessThanOrEqual(report.peak, 0.000_41)
  }

  func testPayloadRejectsUnsupportedVersionAndOverflowingEventBounds() throws {
    var json = validJSON(
      sourceDuration: 4_800,
      destinationStart: 0,
      eventDuration: 4_800,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )
    json["rendererVersion"] = 2
    XCTAssertThrowsError(try decode(json)) { error in
      XCTAssertEqual(error as? AudioRenderError, .unsupportedContract)
    }

    json["rendererVersion"] = 1
    var event = (json["events"] as! [[String: Any]])[0]
    event["destinationStartSample"] = Int64.max
    json["events"] = [event]
    XCTAssertThrowsError(try decode(json)) { error in
      XCTAssertEqual(error as? AudioRenderError, .eventOutOfBounds)
    }
  }

  func testPayloadRejectsCropOutsideTheDartNormalizedBounds() throws {
    var json = validJSON(
      sourceDuration: 4_800,
      destinationStart: 0,
      eventDuration: 4_800,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )
    var video = (json["videoEvents"] as! [[String: Any]])[0]
    video["crop"] = ["x": -0.1, "y": 0.0, "width": 1.0, "height": 1.0]
    json["videoEvents"] = [video]

    XCTAssertThrowsError(try decode(json)) { error in
      XCTAssertEqual(error as? AudioRenderError, .eventOutOfBounds)
    }
  }

  func testPayloadRejectsOversizedCollectionsBeforeEventDecoding() throws {
    var json = validJSON(
      sourceDuration: 4_800,
      destinationStart: 0,
      eventDuration: 4_800,
      fadeIn: 0,
      fadeOut: 0,
      loopMode: "once"
    )
    json["sourceAssetIds"] = (0..<7).map { "asset-\($0)" }
    XCTAssertThrowsError(try decode(json)) { error in
      XCTAssertEqual(error as? AudioRenderError, .unsupportedContract)
    }

    json["sourceAssetIds"] = ["fixture"]
    let event = (json["events"] as! [[String: Any]])[0]
    let video = (json["videoEvents"] as! [[String: Any]])[0]
    json["events"] = Array(repeating: event, count: 65)
    json["videoEvents"] = Array(repeating: video, count: 65)
    XCTAssertThrowsError(try decode(json)) { error in
      XCTAssertEqual(error as? AudioRenderError, .unsupportedContract)
    }
  }

  func testCheckedInSyntheticMP4RendersFromItsAudioTrack() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repository.appendingPathComponent(
      "assets/demo/source/synthetic-tap.mp4"
    )
    let outputURL = temporaryURL(extension: "wav")
    var evidenceReport: AudioRenderReport?
    defer {
      persistCIEvidence(evidenceReport, outputURL: outputURL)
      remove([outputURL])
    }
    var json = validJSON(
      sourceDuration: 4_800,
      destinationStart: 90_000,
      eventDuration: 4_800,
      fadeIn: 0,
      fadeOut: 120,
      loopMode: "once"
    )
    var event = (json["events"] as! [[String: Any]])[0]
    event["sourceStartSample"] = 12_000
    json["events"] = [event]
    var video = (json["videoEvents"] as! [[String: Any]])[0]
    video["sourceVideoStartTime"] = ["numerator": 12_000, "denominator": 48_000]
    json["videoEvents"] = [video]

    let report = try await AudioRenderer(accompanimentGain: 0).render(
      arrangement: try decode(json),
      assets: ["fixture": sourceURL],
      outputURL: outputURL,
      cancellation: CancellationToken(operationId: "mp4")
    )
    evidenceReport = report

    XCTAssertEqual(report.sampleCount, 720_000)
    XCTAssertEqual(report.fileLength, 720_000)
    XCTAssertEqual(report.readChunkFrameCounts.reduce(0, +), 720_000)
    XCTAssertGreaterThan(report.peak, 0.01)
    XCTAssertLessThanOrEqual(abs(try firstAudibleSample(outputURL) - 90_000), 240)
  }

  func testLoopAndHoldCannotStartBeforeTheNativeTrackOrigin() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL = repository.appendingPathComponent(
      "test/fixtures/native/delayed-44100-aac.mp4"
    )
    for mode in ["loop", "hold"] {
      let outputURL = temporaryURL(extension: "caf")
      defer { remove([outputURL]) }
      do {
        _ = try await AudioRenderer(accompanimentGain: 0).render(
          arrangement: try payload(
            sourceDuration: 4_800,
            destinationStart: 0,
            eventDuration: 4_800,
            fadeIn: 0,
            fadeOut: 0,
            loopMode: mode
          ),
          assets: ["fixture": sourceURL],
          outputURL: outputURL,
          cancellation: CancellationToken(operationId: "early-\(mode)")
        )
        XCTFail("Expected source origin rejection for \(mode)")
      } catch {
        XCTAssertEqual(error as? AudioRenderError, .sourceOutOfBounds)
      }
    }
  }

  func testCancelledRegistryTokenStopsRenderBeforeWritingOutput() async throws {
    let registry = JobRegistry()
    let token = try await registry.start(operationId: "cancelled")
    await registry.cancel(operationId: "cancelled")
    let sourceURL = try makeMonoFile(samples: Array(repeating: 0.2, count: 4_800))
    let outputURL = temporaryURL(extension: "caf")
    defer { remove([sourceURL, outputURL]) }

    do {
      _ = try await AudioRenderer(accompanimentGain: 0).render(
        arrangement: try payload(
          sourceDuration: 4_800,
          destinationStart: 0,
          eventDuration: 4_800,
          fadeIn: 0,
          fadeOut: 0,
          loopMode: "once"
        ),
        assets: ["fixture": sourceURL],
        outputURL: outputURL,
        cancellation: token
      )
      XCTFail("Expected cancellation")
    } catch {
      XCTAssertEqual(error as? AudioRenderError, .cancelled)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
  }

  func testJobRegistryRejectsDuplicateActiveOperationAndAllowsReuseAfterFinish() async throws {
    let registry = JobRegistry()
    _ = try await registry.start(operationId: "same-id")

    do {
      _ = try await registry.start(operationId: "same-id")
      XCTFail("Expected duplicate operation rejection")
    } catch {
      XCTAssertEqual(error as? AudioRenderError, .duplicateOperationId)
    }
    await registry.finish(operationId: "same-id")
    _ = try await registry.start(operationId: "same-id")
  }

  private func payload(
    sourceDuration: Int,
    destinationStart: Int,
    eventDuration: Int,
    fadeIn: Int,
    fadeOut: Int,
    loopMode: String
  ) throws -> ArrangementPayload {
    try decode(
      validJSON(
        sourceDuration: sourceDuration,
        destinationStart: destinationStart,
        eventDuration: eventDuration,
        fadeIn: fadeIn,
        fadeOut: fadeOut,
        loopMode: loopMode
      )
    )
  }

  private func decode(_ json: [String: Any]) throws -> ArrangementPayload {
    try JSONDecoder().decode(
      ArrangementPayload.self,
      from: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    )
  }

  private func validJSON(
    sourceDuration: Int,
    destinationStart: Int,
    eventDuration: Int,
    fadeIn: Int,
    fadeOut: Int,
    loopMode: String
  ) -> [String: Any] {
    let event: [String: Any] = [
      "assetId": "fixture",
      "sourceStartSample": 0,
      "destinationStartSample": destinationStart,
      "durationSamples": eventDuration,
      "gain": 1.0,
      "fades": ["fadeInSamples": fadeIn, "fadeOutSamples": fadeOut],
    ]
    let video: [String: Any] = [
      "assetId": "fixture",
      "destinationStartSample": destinationStart,
      "durationSamples": eventDuration,
      "sourceVideoStartTime": ["numerator": 0, "denominator": 48_000],
      "crop": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0],
      "loopMode": loopMode,
    ]
    return [
      "schemaVersion": 1,
      "sampleRate": 48_000,
      "totalSamples": 720_000,
      "templateId": "test",
      "templateVersion": 1,
      "analysisVersion": 1,
      "rendererVersion": 1,
      "seed": 1,
      "style": "sparse",
      "sourceAssetIds": ["fixture"],
      "unusableAssetIds": [],
      "events": [event],
      "videoEvents": [video],
      "fixtureSourceDuration": sourceDuration,
    ]
  }

  private func makeMonoFile(samples: [Float]) throws -> URL {
    let url = temporaryURL(extension: "caf")
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    )
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      )
    )
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in samples.indices { channel[index] = samples[index] }
    try file.write(from: buffer)
    file.close()
    return url
  }

  private func readMonoFile(_ url: URL) throws -> [Float] {
    try readMonoFileWithDiagnostics(url).samples
  }

  private func readMonoFileWithDiagnostics(
    _ url: URL
  ) throws -> (samples: [Float], fileLength: Int, chunkFrameCounts: [Int]) {
    let file = try AVAudioFile(forReading: url)
    let fileLength = Int(file.length)
    var samples: [Float] = []
    samples.reserveCapacity(fileLength)
    var chunkFrameCounts: [Int] = []
    while file.framePosition < file.length {
      let remaining = file.length - file.framePosition
      guard remaining > 0 else {
        throw NSError(domain: "AudioRendererTests", code: 1)
      }
      let requestedFrames = AVAudioFrameCount(min(Int64(32_768), remaining))
      let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(
          pcmFormat: file.processingFormat,
          frameCapacity: requestedFrames
        )
      )
      try file.read(into: buffer, frameCount: requestedFrames)
      let frameCount = Int(buffer.frameLength)
      guard frameCount > 0 else {
        throw NSError(domain: "AudioRendererTests", code: 2)
      }
      let channel = try XCTUnwrap(buffer.floatChannelData?[0])
      samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameCount))
      chunkFrameCounts.append(frameCount)
    }
    guard samples.count == fileLength else {
      throw NSError(domain: "AudioRendererTests", code: 3)
    }
    return (samples, fileLength, chunkFrameCounts)
  }

  private func firstAudibleSample(_ url: URL) throws -> Int {
    let samples = try readMonoFile(url)
    return try XCTUnwrap(samples.firstIndex(where: { abs($0) > 0.001 }))
  }

  private func temporaryURL(extension suffix: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(suffix)
  }

  private func remove(_ urls: [URL]) {
    for url in urls { try? FileManager.default.removeItem(at: url) }
  }

  private func persistCIEvidence(_ report: AudioRenderReport?, outputURL: URL) {
    do {
      let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let directory = repository.appendingPathComponent("ci-artifacts", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let audioURL = directory.appendingPathComponent("audio-render-fixture.wav")
      let reportURL = directory.appendingPathComponent("audio-render-report.json")
      try? FileManager.default.removeItem(at: audioURL)
      try? FileManager.default.removeItem(at: reportURL)
      try FileManager.default.copyItem(at: outputURL, to: audioURL)

      let fallback: (samples: [Float], fileLength: Int, chunkFrameCounts: [Int])?
      let diagnosticError: String?
      do {
        fallback = try readMonoFileWithDiagnostics(outputURL)
        diagnosticError = nil
      } catch {
        fallback = nil
        diagnosticError = String(describing: error)
      }
      let fileLength: Any
      let readFrameCount: Any
      let readChunkFrameCounts: Any
      if let report {
        fileLength = report.fileLength
        readFrameCount = report.sampleCount
        readChunkFrameCounts = report.readChunkFrameCounts
      } else if let fallback {
        fileLength = fallback.fileLength
        readFrameCount = fallback.samples.count
        readChunkFrameCounts = fallback.chunkFrameCounts
      } else {
        fileLength = NSNull()
        readFrameCount = NSNull()
        readChunkFrameCounts = NSNull()
      }
      let evidence: [String: Any] = [
        "fixture": "synthetic-tap",
        "syntheticPracticeSample": true,
        "renderReturnedReport": report != nil,
        "fileLength": fileLength,
        "readFrameCount": readFrameCount,
        "readChunkFrameCounts": readChunkFrameCounts,
        "diagnosticReadError": diagnosticError.map { $0 as Any } ?? NSNull(),
        "sampleRate": report?.sampleRate ?? 48_000,
        "channels": report?.channels ?? 1,
        "peak": report.map { $0.peak as Any } ?? NSNull(),
        "nonFiniteCount": report.map { $0.nonFiniteCount as Any } ?? NSNull(),
        "scheduledOnsetSample": 90_000,
      ]
      try JSONSerialization.data(
        withJSONObject: evidence,
        options: [.prettyPrinted, .sortedKeys]
      ).write(to: reportURL, options: .atomic)

      for (url, name) in [
        (audioURL, "audio-render-fixture.wav"),
        (reportURL, "audio-render-report.json"),
      ] {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    } catch {
      XCTFail("Failed to preserve audio render evidence: \(error)")
    }
  }
}
