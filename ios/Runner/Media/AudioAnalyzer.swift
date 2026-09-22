import AVFoundation
import Foundation

enum AudioAnalysisError: Error, Equatable {
  case emptyAssetId
  case emptyAudio
  case conversionFailed
  case selectionOutOfBounds
  case unsupportedContract
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
    guard schemaVersion == Self.supportedSchemaVersion,
      !assetId.isEmpty, !relativePath.isEmpty,
      audioTrackStartUs >= 0,
      selectionStartUs >= audioTrackStartUs,
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
    guard sourceStartSample >= 0, durationSamples > 0,
      onsetSamples.allSatisfy({
        $0 >= sourceStartSample && $0 < sourceStartSample + durationSamples
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
    let allSamples = try readMono48k(url: url)
    guard audioTrackStartUs >= 0,
      selectionStartUs >= audioTrackStartUs,
      selectionDurationUs == nil || selectionDurationUs! > 0
    else { throw AudioAnalysisError.selectionOutOfBounds }
    let localStartUs = selectionStartUs - audioTrackStartUs
    let start = Int(localStartUs * Int64(Self.sampleRate) / 1_000_000)
    let requestedDuration = selectionDurationUs.map {
      Int($0 * Int64(Self.sampleRate) / 1_000_000)
    }
    let end = requestedDuration.map { start + $0 } ?? allSamples.count
    guard start < allSamples.count, end > start, end <= allSamples.count else {
      throw AudioAnalysisError.selectionOutOfBounds
    }
    let sourceStart = Int(selectionStartUs * Int64(Self.sampleRate) / 1_000_000)
    return try analyze(
      samples: Array(allSamples[start..<end]),
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

  private func readMono48k(url: URL) throws -> [Float] {
    let sourceFile = try AVAudioFile(forReading: url)
    let sourceFormat = sourceFile.processingFormat
    guard sourceFile.length > 0,
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(Self.sampleRate),
        channels: 1,
        interleaved: false
      ),
      let input = AVAudioPCMBuffer(
        pcmFormat: sourceFormat,
        frameCapacity: AVAudioFrameCount(sourceFile.length)
      )
    else { throw AudioAnalysisError.emptyAudio }
    try sourceFile.read(into: input)

    if sourceFormat.sampleRate == targetFormat.sampleRate,
      sourceFormat.channelCount == 1,
      sourceFormat.commonFormat == .pcmFormatFloat32,
      let channel = input.floatChannelData?[0]
    {
      return Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw AudioAnalysisError.conversionFailed
    }
    let expectedFrames = Int(ceil(Double(input.frameLength) * targetFormat.sampleRate
      / sourceFormat.sampleRate)) + 32
    guard let output = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: AVAudioFrameCount(expectedFrames)
    ) else { throw AudioAnalysisError.conversionFailed }
    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      if suppliedInput {
        inputStatus.pointee = .endOfStream
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return input
    }
    guard conversionError == nil,
      status != .error,
      output.frameLength > 0,
      let channel = output.floatChannelData?[0]
    else { throw AudioAnalysisError.conversionFailed }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
  }
}
