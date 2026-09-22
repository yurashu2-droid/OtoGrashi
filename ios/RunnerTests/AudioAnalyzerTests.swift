import AVFoundation
import XCTest
@testable import Runner

final class AudioAnalyzerTests: XCTestCase {
  private let analyzer = AudioAnalyzer()

  func testTrackRangeRoundsItsAbsoluteEndInsteadOfAddingRoundedParts() throws {
    let subSample = CMTime(value: 1, timescale: 120_000)

    let range = try NativePCMReader.sampleRange(
      CMTimeRange(start: subSample, duration: subSample)
    )

    XCTAssertEqual(range.startSample, 0)
    XCTAssertEqual(range.endSample, 1)
    XCTAssertEqual(range.durationSamples, 1)
  }

  func testSilentSignalHasZeroTenMillisecondMetrics() throws {
    let metrics = try analyzer.measure(samples: Array(repeating: 0, count: 960))

    XCTAssertEqual(metrics.frameRMS, [0, 0])
    XCTAssertEqual(metrics.differenceEnergy, [0, 0])
    XCTAssertEqual(metrics.peak, 0)
    XCTAssertEqual(metrics.rms, 0)
    XCTAssertEqual(metrics.onsetSamples, [])
    XCTAssertEqual(metrics.suggestedRole, .texture)
  }

  func testMixedSignalComputesRMSDifferenceAndPeakInTenMillisecondFrames() throws {
    let samples = Array(repeating: Float(0), count: 480)
      + Array(repeating: Float(0.5), count: 480)

    let metrics = try analyzer.measure(samples: samples)

    XCTAssertEqual(metrics.frameRMS[0], 0, accuracy: 0.000_001)
    XCTAssertEqual(metrics.frameRMS[1], 0.5, accuracy: 0.000_001)
    XCTAssertEqual(metrics.differenceEnergy[1], 0.5, accuracy: 0.000_001)
    XCTAssertEqual(metrics.peak, 0.5, accuracy: 0.000_001)
    XCTAssertEqual(metrics.rms, sqrt(0.125), accuracy: 0.000_001)
  }

  func testShortSeparatedImpulsesAreOnsetsAndTransient() throws {
    var samples = Array(repeating: Float(0), count: 4_800)
    samples[960] = 1
    samples[3_360] = 1

    let metrics = try analyzer.measure(samples: samples)

    XCTAssertEqual(metrics.onsetSamples, [960, 3_360])
    XCTAssertEqual(metrics.suggestedRole, .transient)
    XCTAssertGreaterThanOrEqual(
      metrics.onsetSamples[1] - metrics.onsetSamples[0],
      AudioAnalyzer.minimumOnsetSpacingSamples
    )
  }

  func testSustainedSignalIsNotMisclassifiedAsMeaning() throws {
    let result = try analyzer.analyze(
      samples: Array(repeating: 0.2, count: 4_800),
      assetId: "steady"
    )

    XCTAssertEqual(result.sampleRate, 48_000)
    XCTAssertEqual(result.durationSamples, 4_800)
    XCTAssertEqual(result.suggestedRole, .sustain)
  }

  func testAVFoundationDownmixUsesRightOnlyStereoAndProducesMono48k() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
    )
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
    buffer.frameLength = 4_410
    for channel in 0..<2 {
      let data = try XCTUnwrap(buffer.floatChannelData?[channel])
      for frame in 0..<4_410 {
        data[frame] = channel == 0 ? 0 : sin(Float(frame) * 0.05) * 0.5
      }
    }
    try file.write(from: buffer)
    file.close()

    let result = try analyzer.analyze(url: url, assetId: "file")
    XCTAssertEqual(result.sampleRate, 48_000)
    XCTAssertLessThanOrEqual(abs(result.durationSamples - 4_800), 1)
    XCTAssertGreaterThan(result.peak, 0.1)
    let selected = try analyzer.analyze(
      url: url,
      assetId: "selected",
      selectionStartUs: 30_000,
      selectionDurationUs: 20_000
    )
    XCTAssertEqual(selected.sourceStartSample, 1_440)
    XCTAssertLessThanOrEqual(abs(selected.durationSamples - 960), 1)
    XCTAssertThrowsError(
      try analyzer.analyze(
        url: url,
        assetId: "file",
        selectionStartUs: 200_000,
        selectionDurationUs: 100_000
      )
    ) { error in
      XCTAssertEqual(error as? AudioAnalysisError, .noAudioOverlap)
    }
  }

  func testAnalysisRejectsCallerTrackOriginThatDisagreesWithNativeMedia() throws {
    let url = try makeMonoFile(frameCount: 4_800, sampleRate: 48_000)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(
      try analyzer.analyze(
        url: url,
        assetId: "mismatched-origin",
        selectionStartUs: 0,
        selectionDurationUs: 50_000,
        audioTrackStartUs: 30_000
      )
    ) { error in
      XCTAssertEqual(error as? AudioAnalysisError, .trackOriginMismatch)
    }
  }

  func testHugeTimestampsAreRejectedWithoutIntegerTrap() throws {
    let url = try makeMonoFile(frameCount: 480, sampleRate: 48_000)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(
      try analyzer.analyze(
        url: url,
        assetId: "overflow",
        selectionStartUs: Int64.max,
        selectionDurationUs: 1
      )
    ) { error in
      XCTAssertEqual(error as? AudioAnalysisError, .timestampOutOfRange)
      XCTAssertEqual((error as? AudioAnalysisError)?.recoverable, true)
    }
  }

  func testDartContractFixtureDecodesAndUnsupportedVersionIsRejected() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixtureURL = repository.appendingPathComponent("test/fixtures/media_analysis_v1.json")
    let data = try Data(contentsOf: fixtureURL)

    let result = try JSONDecoder().decode(AnalyzedClip.self, from: data)
    XCTAssertEqual(result.assetId, "fixture-tap")
    XCTAssertEqual(result.onsetSamples, [960, 12_000])
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result))
      as? [String: Any]
    XCTAssertEqual(encoded?["schemaVersion"] as? Int, 1)
    XCTAssertEqual(encoded?["analysisVersion"] as? Int, 1)

    var unsupported = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    unsupported["schemaVersion"] = 2
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        AnalyzedClip.self,
        from: JSONSerialization.data(withJSONObject: unsupported)
      )
    )

    unsupported["schemaVersion"] = 1
    unsupported["sourceStartSample"] = Int64.max
    unsupported["durationSamples"] = 1
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        AnalyzedClip.self,
        from: JSONSerialization.data(withJSONObject: unsupported)
      )
    ) { error in
      XCTAssertEqual(error as? AudioAnalysisError, .timestampOutOfRange)
    }
  }

  func testDartAnalysisRequestFixturePreservesSelectionAndTrackOrigin() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: repository.appendingPathComponent(
        "test/fixtures/media_analysis_request_v1.json"
      )
    )

    let request = try JSONDecoder().decode(MediaAnalysisRequest.self, from: data)
    XCTAssertEqual(request.selectionStartUs, 30_000)
    XCTAssertEqual(request.selectionDurationUs, 20_000)
    XCTAssertEqual(request.audioTrackStartUs, 10_000)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary,
      try JSONSerialization.jsonObject(with: data) as? NSDictionary
    )

    var delayed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    delayed["selectionStartUs"] = 0
    delayed["audioTrackStartUs"] = 10_000
    XCTAssertNoThrow(
      try JSONDecoder().decode(
        MediaAnalysisRequest.self,
        from: JSONSerialization.data(withJSONObject: delayed)
      )
    )

    delayed["selectionStartUs"] = Int64.max
    delayed["selectionDurationUs"] = 1
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        MediaAnalysisRequest.self,
        from: JSONSerialization.data(withJSONObject: delayed)
      )
    ) { error in
      XCTAssertEqual(error as? AudioAnalysisError, .timestampOutOfRange)
    }
  }

  func testCheckedInSyntheticMP4UsesBoundedAudioTrackSelection() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = repository.appendingPathComponent(
      "assets/demo/source/synthetic-tap.mp4"
    )

    let result = try analyzer.analyze(
      url: url,
      assetId: "synthetic-tap",
      selectionStartUs: 250_000,
      selectionDurationUs: 100_000
    )

    XCTAssertEqual(result.sourceStartSample, 12_000)
    XCTAssertEqual(result.durationSamples, 4_800)
    XCTAssertGreaterThan(result.peak, 0.1)
    XCTAssertTrue(result.onsetSamples.allSatisfy { (12_000..<16_800).contains($0) })
  }

  func testDelayed44100AACMapsImpulseFromActualPTSIntoAbsoluteTimeline() throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let url = repository.appendingPathComponent(
      "test/fixtures/native/delayed-44100-aac.mp4"
    )
    let range = try NativePCMReader().trackRange(url: url)

    XCTAssertEqual(range.startSample, 0)
    let pcm = try NativePCMReader().readTimeline(
      url: url,
      startSample: 0,
      durationSamples: 29_952
    )
    XCTAssertEqual(pcm.requestedRange, 0..<29_952)
    let authoredMarkerSample = 19_115
    XCTAssertFalse(pcm.coveredRanges.isEmpty)
    XCTAssertTrue(
      pcm.coveredRanges.allSatisfy {
        pcm.requestedRange.lowerBound <= $0.lowerBound
          && $0.upperBound <= pcm.requestedRange.upperBound
      }
    )
    XCTAssertTrue(pcm.coveredRanges.contains(where: { $0.contains(authoredMarkerSample) }))
    XCTAssertTrue(
      pcm.samples.enumerated().allSatisfy { offset, sample in
        let absoluteSample = pcm.requestedRange.lowerBound + offset
        return pcm.coveredRanges.contains(where: { $0.contains(absoluteSample) })
          || sample == 0
      }
    )
    let result = try analyzer.analyze(
      url: url,
      assetId: "delayed-44100-aac",
      selectionStartUs: 0,
      selectionDurationUs: 600_000,
      audioTrackStartUs: 0
    )

    XCTAssertEqual(result.sourceStartSample, 0)
    let onsetSample = try XCTUnwrap(result.onsetSamples.first)
    XCTAssertEqual(result.onsetSamples.count, 1)
    XCTAssertLessThanOrEqual(onsetSample, authoredMarkerSample)
    XCTAssertLessThan(authoredMarkerSample, onsetSample + AudioAnalyzer.frameSamples)
  }

  private func makeMonoFile(frameCount: Int, sampleRate: Double) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("caf")
    let format = try XCTUnwrap(
      AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
    )
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
    )
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let data = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<frameCount {
      data[frame] = 0.25
    }
    try file.write(from: buffer)
    file.close()
    return url
  }
}
