import AVFoundation
import XCTest
@testable import Runner

final class AudioAnalyzerTests: XCTestCase {
  private let analyzer = AudioAnalyzer()

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

  func testAVFoundationConversionProducesMono48kAndRejectsOutOfBoundsSelection() throws {
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
        data[frame] = sin(Float(frame) * 0.05) * 0.25
      }
    }
    try file.write(from: buffer)

    let result = try analyzer.analyze(url: url, assetId: "file")
    XCTAssertEqual(result.sampleRate, 48_000)
    XCTAssertLessThanOrEqual(abs(result.durationSamples - 4_800), 1)
    let selected = try analyzer.analyze(
      url: url,
      assetId: "selected",
      selectionStartUs: 30_000,
      selectionDurationUs: 20_000,
      audioTrackStartUs: 10_000
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
      XCTAssertEqual(error as? AudioAnalysisError, .selectionOutOfBounds)
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
  }
}
