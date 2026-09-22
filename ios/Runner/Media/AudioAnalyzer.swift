import AVFoundation
import Foundation

enum AudioAnalysisError: Error, Equatable {
  case emptyAssetId
  case emptyAudio
  case conversionFailed
  case selectionOutOfBounds
  case noAudioOverlap
  case timestampOutOfRange
  case unsupportedContract

  var recoverable: Bool {
    switch self {
    case .selectionOutOfBounds, .noAudioOverlap, .timestampOutOfRange:
      return true
    default:
      return false
    }
  }
}

enum SuggestedRole: String, Codable, Equatable {
  case transient
  case sustain
  case texture
}

struct MediaAnalysisRequest: Codable, Equatable {
  static let supportedSchemaVersion = 1

  let schemaVersion: Int
  let assetId: String
  let relativePath: String
  let selectionStartUs: Int64
  let selectionDurationUs: Int64
  let audioTrackStartUs: Int64

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let assetId = try container.decode(String.self, forKey: .assetId)
    let relativePath = try container.decode(String.self, forKey: .relativePath)
    let selectionStartUs = try container.decode(Int64.self, forKey: .selectionStartUs)
    let selectionDurationUs = try container.decode(Int64.self, forKey: .selectionDurationUs)
    let audioTrackStartUs = try container.decode(Int64.self, forKey: .audioTrackStartUs)
    let (_, selectionEndOverflow) = selectionStartUs.addingReportingOverflow(
      selectionDurationUs
    )
    guard !selectionEndOverflow else { throw AudioAnalysisError.timestampOutOfRange }
    guard schemaVersion == Self.supportedSchemaVersion,
      !assetId.isEmpty, !relativePath.isEmpty,
      audioTrackStartUs >= 0,
      selectionStartUs >= 0,
      selectionDurationUs > 0
    else { throw AudioAnalysisError.unsupportedContract }
    self.schemaVersion = schemaVersion
    self.assetId = assetId
    self.relativePath = relativePath
    self.selectionStartUs = selectionStartUs
    self.selectionDurationUs = selectionDurationUs
    self.audioTrackStartUs = audioTrackStartUs
  }
}

struct AnalyzedClip: Codable, Equatable {
  static let supportedSchemaVersion = 1
  static let supportedAnalysisVersion = 1

  let schemaVersion: Int
  let analysisVersion: Int
  let assetId: String
  let sourceStartSample: Int
  let durationSamples: Int
  let sampleRate: Int
  let onsetSamples: [Int]
  let peak: Double
  let rms: Double
  let suggestedRole: SuggestedRole

  init(
    assetId: String,
    sourceStartSample: Int = 0,
    durationSamples: Int,
    onsetSamples: [Int],
    peak: Double,
    rms: Double,
    suggestedRole: SuggestedRole
  ) throws {
    guard !assetId.isEmpty else { throw AudioAnalysisError.emptyAssetId }
    let (sourceEndSample, sourceEndOverflow) = sourceStartSample
      .addingReportingOverflow(durationSamples)
    guard !sourceEndOverflow else { throw AudioAnalysisError.timestampOutOfRange }
    guard sourceStartSample >= 0, durationSamples > 0,
      onsetSamples.allSatisfy({
        $0 >= sourceStartSample && $0 < sourceEndSample
      }),
      peak.isFinite, rms.isFinite,
      (0...1).contains(peak), (0...1).contains(rms)
    else { throw AudioAnalysisError.unsupportedContract }
    self.schemaVersion = Self.supportedSchemaVersion
    self.analysisVersion = Self.supportedAnalysisVersion
    self.assetId = assetId
    self.sourceStartSample = sourceStartSample
    self.durationSamples = durationSamples
    self.sampleRate = AudioAnalyzer.sampleRate
    self.onsetSamples = onsetSamples
    self.peak = peak
    self.rms = rms
    self.suggestedRole = suggestedRole
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let analysisVersion = try container.decode(Int.self, forKey: .analysisVersion)
    let sampleRate = try container.decode(Int.self, forKey: .sampleRate)
    guard schemaVersion == Self.supportedSchemaVersion,
      analysisVersion == Self.supportedAnalysisVersion,
      sampleRate == AudioAnalyzer.sampleRate
    else { throw AudioAnalysisError.unsupportedContract }
    try self.init(
      assetId: container.decode(String.self, forKey: .assetId),
      sourceStartSample: container.decode(Int.self, forKey: .sourceStartSample),
      durationSamples: container.decode(Int.self, forKey: .durationSamples),
      onsetSamples: container.decode([Int].self, forKey: .onsetSamples),
      peak: container.decode(Double.self, forKey: .peak),
      rms: container.decode(Double.self, forKey: .rms),
      suggestedRole: container.decode(SuggestedRole.self, forKey: .suggestedRole)
    )
  }
}

struct SignalMetrics: Equatable {
  let frameRMS: [Double]
  let differenceEnergy: [Double]
  let peak: Double
  let rms: Double
  let onsetSamples: [Int]
  let suggestedRole: SuggestedRole
}

struct AudioAnalyzer {
  static let sampleRate = 48_000
  static let frameSamples = 480
  static let minimumOnsetSpacingSamples = 2_400

  func analyze(samples: [Float], assetId: String) throws -> AnalyzedClip {
    guard !assetId.isEmpty else { throw AudioAnalysisError.emptyAssetId }
    return try analyze(samples: samples, assetId: assetId, sourceStartSample: 0)
  }

  private func analyze(
    samples: [Float],
    assetId: String,
    sourceStartSample: Int
  ) throws -> AnalyzedClip {
    let metrics = try measure(samples: samples)
    return try AnalyzedClip(
      assetId: assetId,
      sourceStartSample: sourceStartSample,
      durationSamples: samples.count,
      onsetSamples: metrics.onsetSamples.map { $0 + sourceStartSample },
      peak: metrics.peak,
      rms: metrics.rms,
      suggestedRole: metrics.suggestedRole
    )
  }

  func analyze(
    url: URL,
    assetId: String,
    selectionStartUs: Int64 = 0,
    selectionDurationUs: Int64? = nil,
    audioTrackStartUs: Int64 = 0
  ) throws -> AnalyzedClip {
    guard audioTrackStartUs >= 0,
      selectionStartUs >= 0,
      selectionDurationUs == nil || selectionDurationUs! > 0
    else { throw AudioAnalysisError.selectionOutOfBounds }
    let selectionEndUs: Int64?
    if let selectionDurationUs {
      let (end, overflow) = selectionStartUs.addingReportingOverflow(selectionDurationUs)
      guard !overflow else { throw AudioAnalysisError.timestampOutOfRange }
      selectionEndUs = end
    } else {
      selectionEndUs = nil
    }
    let selectionStartSample = try Self.samples(fromMicroseconds: selectionStartUs)
    let selectionEndSample = try selectionEndUs.map {
      try Self.samples(fromMicroseconds: $0)
    }
    let trackStartSample = try Self.samples(fromMicroseconds: audioTrackStartUs)
    let decodedTrackRange: NativePCMReader.TrackRange
    do {
      decodedTrackRange = try NativePCMReader().trackRange(url: url)
    } catch {
      throw AudioAnalysisError.conversionFailed
    }
    guard let audioLength = Int64(exactly: decodedTrackRange.durationSamples) else {
      throw AudioAnalysisError.timestampOutOfRange
    }
    let (audioEndSample, audioEndOverflow) = trackStartSample.addingReportingOverflow(
      audioLength
    )
    guard !audioEndOverflow else { throw AudioAnalysisError.timestampOutOfRange }
    let intersectionStart = max(selectionStartSample, trackStartSample)
    let intersectionEnd = min(selectionEndSample ?? audioEndSample, audioEndSample)
    guard intersectionEnd > intersectionStart else {
      throw AudioAnalysisError.noAudioOverlap
    }
    guard let start = Int(exactly: intersectionStart - trackStartSample),
      let duration = Int(exactly: intersectionEnd - intersectionStart),
      let sourceStart = Int(exactly: intersectionStart)
    else { throw AudioAnalysisError.timestampOutOfRange }
    let selectedSamples: [Float]
    do {
      selectedSamples = try NativePCMReader().readTrackOffset(
        url: url,
        offsetSamples: start,
        durationSamples: duration
      )
    } catch {
      throw AudioAnalysisError.conversionFailed
    }
    guard !selectedSamples.isEmpty else { throw AudioAnalysisError.emptyAudio }
    return try analyze(
      samples: selectedSamples,
      assetId: assetId,
      sourceStartSample: sourceStart
    )
  }

  func measure(samples: [Float]) throws -> SignalMetrics {
    guard !samples.isEmpty else { throw AudioAnalysisError.emptyAudio }
    var frameRMS = [Double]()
    var differenceEnergy = [Double]()
    var peak = 0.0
    var totalSquares = 0.0
    var previousFrameRMS = 0.0

    for frameStart in stride(from: 0, to: samples.count, by: Self.frameSamples) {
      let frameEnd = min(frameStart + Self.frameSamples, samples.count)
      var frameSquares = 0.0
      for index in frameStart..<frameEnd {
        let sample = min(1.0, max(-1.0, Double(samples[index])))
        peak = max(peak, abs(sample))
        frameSquares += sample * sample
      }
      totalSquares += frameSquares
      let value = sqrt(frameSquares / Double(frameEnd - frameStart))
      frameRMS.append(value)
      differenceEnergy.append(abs(value - previousFrameRMS))
      previousFrameRMS = value
    }

    let rms = sqrt(totalSquares / Double(samples.count))
    let rmsThreshold = max(0.01, rms * 1.5)
    let differenceThreshold = max(0.01, rms * 0.5)
    var onsets = [Int]()
    for frame in frameRMS.indices
    where frameRMS[frame] >= rmsThreshold
      && differenceEnergy[frame] >= differenceThreshold
    {
      let candidate = frame * Self.frameSamples
      if onsets.last.map({ candidate - $0 >= Self.minimumOnsetSpacingSamples }) ?? true {
        onsets.append(candidate)
      }
    }

    let role: SuggestedRole
    if peak < 0.001 && rms < 0.0001 {
      role = .texture
    } else if !onsets.isEmpty && peak >= max(0.05, rms * 3) {
      role = .transient
    } else if rms >= 0.01 {
      role = .sustain
    } else {
      role = .texture
    }
    return SignalMetrics(
      frameRMS: frameRMS,
      differenceEnergy: differenceEnergy,
      peak: peak,
      rms: rms,
      onsetSamples: onsets,
      suggestedRole: role
    )
  }

  private static func samples(fromMicroseconds microseconds: Int64) throws -> Int64 {
    guard microseconds >= 0 else { throw AudioAnalysisError.timestampOutOfRange }
    let wholeSeconds = microseconds / 1_000_000
    let remainingMicroseconds = microseconds % 1_000_000
    let (wholeSamples, wholeOverflow) = wholeSeconds.multipliedReportingOverflow(
      by: Int64(sampleRate)
    )
    let (fractionProduct, fractionOverflow) = remainingMicroseconds
      .multipliedReportingOverflow(by: Int64(sampleRate))
    guard !wholeOverflow, !fractionOverflow else {
      throw AudioAnalysisError.timestampOutOfRange
    }
    let fractionalSamples = fractionProduct / 1_000_000
    let (samples, additionOverflow) = wholeSamples.addingReportingOverflow(
      fractionalSamples
    )
    guard !additionOverflow else { throw AudioAnalysisError.timestampOutOfRange }
    return samples
  }
}
