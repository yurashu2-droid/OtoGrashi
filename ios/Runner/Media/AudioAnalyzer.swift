import AVFoundation
import CoreMedia
import Foundation

enum AudioAnalysisError: Error, Equatable {
  case emptyAssetId
  case emptyAudio
  case conversionFailed
  case selectionOutOfBounds
  case noAudioOverlap
  case trackOriginMismatch
  case timestampOutOfRange
  case unsupportedContract

  var recoverable: Bool {
    switch self {
    case .selectionOutOfBounds, .noAudioOverlap, .trackOriginMismatch,
      .timestampOutOfRange:
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

struct AudibleRegion: Codable, Equatable {
  let startSample: Int
  let durationSamples: Int
  let fundamentalMidiNote: Double?

  init(startSample: Int, durationSamples: Int, fundamentalMidiNote: Double? = nil) {
    self.startSample = startSample
    self.durationSamples = durationSamples
    self.fundamentalMidiNote = fundamentalMidiNote
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
  let audibleRegions: [AudibleRegion]
  let peak: Double
  let rms: Double
  let suggestedRole: SuggestedRole
  /// Stable fundamental of a sustained, single-pitched recording, in MIDI notes.
  /// Nil means that the recording must not be treated as a tuned instrument.
  let fundamentalMidiNote: Double?

  init(
    assetId: String,
    sourceStartSample: Int = 0,
    durationSamples: Int,
    onsetSamples: [Int],
    audibleRegions: [AudibleRegion] = [],
    peak: Double,
    rms: Double,
    suggestedRole: SuggestedRole,
    fundamentalMidiNote: Double? = nil
  ) throws {
    guard !assetId.isEmpty else { throw AudioAnalysisError.emptyAssetId }
    let (sourceEndSample, sourceEndOverflow) = sourceStartSample
      .addingReportingOverflow(durationSamples)
    guard !sourceEndOverflow else { throw AudioAnalysisError.timestampOutOfRange }
    guard sourceStartSample >= 0, durationSamples > 0,
      onsetSamples.allSatisfy({
        $0 >= sourceStartSample && $0 < sourceEndSample
      }),
      audibleRegions.count <= 16,
      audibleRegions.allSatisfy({
        $0.startSample >= sourceStartSample && $0.durationSamples > 0 &&
          $0.startSample <= sourceEndSample - $0.durationSamples &&
          ($0.fundamentalMidiNote == nil ||
            ($0.fundamentalMidiNote!.isFinite && (24...100).contains($0.fundamentalMidiNote!)))
      }),
      peak.isFinite, rms.isFinite,
      (0...1).contains(peak), (0...1).contains(rms),
      fundamentalMidiNote == nil ||
        (fundamentalMidiNote!.isFinite && (24...100).contains(fundamentalMidiNote!))
    else { throw AudioAnalysisError.unsupportedContract }
    self.schemaVersion = Self.supportedSchemaVersion
    self.analysisVersion = Self.supportedAnalysisVersion
    self.assetId = assetId
    self.sourceStartSample = sourceStartSample
    self.durationSamples = durationSamples
    self.sampleRate = AudioAnalyzer.sampleRate
    self.onsetSamples = onsetSamples
    self.audibleRegions = audibleRegions
    self.peak = peak
    self.rms = rms
    self.suggestedRole = suggestedRole
    self.fundamentalMidiNote = fundamentalMidiNote
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
      audibleRegions: container.decodeIfPresent([AudibleRegion].self, forKey: .audibleRegions) ?? [],
      peak: container.decode(Double.self, forKey: .peak),
      rms: container.decode(Double.self, forKey: .rms),
      suggestedRole: container.decode(SuggestedRole.self, forKey: .suggestedRole),
      fundamentalMidiNote: container.decodeIfPresent(Double.self, forKey: .fundamentalMidiNote)
    )
  }
}

struct SignalMetrics: Equatable {
  let frameRMS: [Double]
  let differenceEnergy: [Double]
  let peak: Double
  let rms: Double
  let onsetSamples: [Int]
  let audibleRegions: [AudibleRegion]
  let suggestedRole: SuggestedRole
  let fundamentalMidiNote: Double?
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
      audibleRegions: metrics.audibleRegions.map {
        AudibleRegion(startSample: $0.startSample + sourceStartSample,
                      durationSamples: $0.durationSamples,
                      fundamentalMidiNote: $0.fundamentalMidiNote)
      },
      peak: metrics.peak,
      rms: metrics.rms,
      suggestedRole: metrics.suggestedRole,
      fundamentalMidiNote: metrics.fundamentalMidiNote
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
    let declaredTrackStartSample = try Self.samples(fromMicroseconds: audioTrackStartUs)
    let decodedTrackRange: NativePCMReader.TrackRange
    do {
      decodedTrackRange = try NativePCMReader().trackRange(url: url)
    } catch {
      throw AudioAnalysisError.conversionFailed
    }
    guard abs(declaredTrackStartSample - Int64(decodedTrackRange.startSample)) <= 1 else {
      throw AudioAnalysisError.trackOriginMismatch
    }
    let intersectionStart = max(
      selectionStartSample,
      Int64(decodedTrackRange.startSample)
    )
    let intersectionEnd = min(
      selectionEndSample ?? Int64(decodedTrackRange.endSample),
      Int64(decodedTrackRange.endSample)
    )
    guard intersectionEnd > intersectionStart else {
      throw AudioAnalysisError.noAudioOverlap
    }
    guard let duration = Int(exactly: intersectionEnd - intersectionStart),
      let sourceStart = Int(exactly: intersectionStart)
    else { throw AudioAnalysisError.timestampOutOfRange }
    let selected: PCMReadResult
    do {
      selected = try NativePCMReader().readTimeline(
        url: url,
        startSample: sourceStart,
        durationSamples: duration
      )
    } catch {
      throw AudioAnalysisError.conversionFailed
    }
    return try analyze(
      samples: selected.samples,
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

    // A voice or room sound may have no sharp attack. Give the arranger an
    // audible anchor instead of letting it pick a random point in the clip.
    if onsets.isEmpty, rms >= 0.001,
      let loudestFrame = frameRMS.indices.max(by: { frameRMS[$0] < frameRMS[$1] }),
      frameRMS[loudestFrame] >= max(0.005, rms * 0.5) {
      onsets.append(max(0, loudestFrame * Self.frameSamples - 2_400))
    }

    // Classify the audible signal, not the recording including its silence.
    // A half-second voice inside a six-second recording is still a voice.
    let regions = Self.audibleRegions(
      frameRMS: frameRMS, sampleCount: samples.count, rms: rms
    )
    let activeThreshold = max(0.0001, (frameRMS.max() ?? 0) * 0.1)
    let activeFrames = frameRMS.filter { $0 >= activeThreshold }
    let activeRMS = activeFrames.isEmpty ? 0
      : sqrt(activeFrames.reduce(0) { $0 + $1 * $1 } / Double(activeFrames.count))
    let role: SuggestedRole
    if peak < 0.001 && rms < 0.0001 {
      role = .texture
    } else if !onsets.isEmpty && peak >= max(0.05, activeRMS * 3) {
      role = .transient
    } else if activeRMS >= 0.001 {
      role = .sustain
    } else {
      role = .texture
    }
    let audibleRegions = regions.map { region in
      let fragment = Array(samples[region.startSample..<(region.startSample + region.durationSamples)])
      return AudibleRegion(startSample: region.startSample,
        durationSamples: region.durationSamples,
        fundamentalMidiNote: EverydayAudioDSP.stableNote(fragment))
    }
    let regionNotes = audibleRegions.compactMap(\.fundamentalMidiNote)
    let stableClipNote: Double?
    if !regionNotes.isEmpty,
      regionNotes.count == audibleRegions.count,
      regionNotes.max()! - regionNotes.min()! < 0.5 {
      stableClipNote = regionNotes.sorted()[regionNotes.count / 2]
    } else {
      stableClipNote = nil
    }
    return SignalMetrics(
      frameRMS: frameRMS,
      differenceEnergy: differenceEnergy,
      peak: peak,
      rms: rms,
      onsetSamples: onsets,
      audibleRegions: audibleRegions,
      suggestedRole: role,
      fundamentalMidiNote: stableClipNote
    )
  }

  private static func audibleRegions(
    frameRMS: [Double],
    sampleCount: Int,
    rms: Double
  ) -> [AudibleRegion] {
    let threshold = max(0.0001, max(rms * 0.35, (frameRMS.max() ?? 0) * 0.10))
    var active = frameRMS.map { $0 >= threshold }
    guard active.contains(true) else { return [] }

    // Keep short gaps inside a spoken syllable together, without merging
    // separate phrases across a long quiet stretch.
    if active.count > 2 {
      for frame in active.indices where frame > 0 &&
        frame + 1 < active.count && !active[frame] {
        let before = max(0, frame - 5)
        let after = min(active.count - 1, frame + 5)
        if active[before..<frame].contains(true) &&
          active[(frame + 1)...after].contains(true) {
          active[frame] = true
        }
      }
    }

    var scored: [(region: AudibleRegion, score: Double)] = []
    var frame = 0
    while frame < active.count {
      guard active[frame] else { frame += 1; continue }
      let begin = frame
      var energy = 0.0
      var strongest = 0.0
      while frame < active.count && active[frame] {
        let level = frameRMS[frame]
        energy += level * level
        strongest = max(strongest, level)
        frame += 1
      }
      let start = max(0, begin * frameSamples - 960)
      let end = min(sampleCount, frame * frameSamples + 1_920)
      guard end > start else { continue }
      let meanEnergy = energy / Double(frame - begin)
      scored.append((
        region: AudibleRegion(startSample: start, durationSamples: end - start),
        score: meanEnergy + strongest * strongest
      ))
    }
    return scored.sorted { $0.score > $1.score }
      .prefix(16).map { $0.region }
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

struct AudioWaveformSampler {
  static let barCount = 96

  func sample(url: URL) throws -> [String: Any] {
    let asset = AVURLAsset(url: url)
    let duration = asset.duration
    let seconds = CMTimeGetSeconds(duration)
    guard duration.isNumeric, seconds.isFinite, seconds > 0,
      seconds < Double(Int.max / (NativePCMReader.sampleRate * Self.barCount)),
      seconds < Double(Int64.max) / 1_000_000
    else { throw AudioAnalysisError.unsupportedContract }
    let totalSamples = Int((seconds * Double(NativePCMReader.sampleRate)).rounded())
    guard totalSamples > 0,
      let track = asset.tracks(withMediaType: .audio).first
    else { throw AudioAnalysisError.emptyAudio }
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: NativePCMReader.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw AudioAnalysisError.conversionFailed }
    reader.add(output)
    guard reader.startReading() else { throw AudioAnalysisError.conversionFailed }
    var peaks = [Double](repeating: 0, count: Self.barCount)
    while let buffer = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let count = min(CMSampleBufferGetNumSamples(buffer),
        CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
      guard count > 0 else { continue }
      var values = [Float](repeating: 0, count: count)
      let status = values.withUnsafeMutableBytes { storage in
        CMBlockBufferCopyDataBytes(block, atOffset: 0,
          dataLength: count * MemoryLayout<Float>.size,
          destination: storage.baseAddress!)
      }
      guard status == kCMBlockBufferNoErr else {
        reader.cancelReading()
        throw AudioAnalysisError.conversionFailed
      }
      let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
      let startSeconds = CMTimeGetSeconds(timestamp)
      guard timestamp.isNumeric, startSeconds.isFinite,
        startSeconds >= 0,
        startSeconds < Double(Int.max / NativePCMReader.sampleRate)
      else { continue }
      let startSample = Int((startSeconds * Double(NativePCMReader.sampleRate)).rounded())
      for index in values.indices {
        let sample = startSample + index
        guard sample >= 0, sample < totalSamples else { continue }
        let amplitude = Double(abs(values[index]))
        guard amplitude.isFinite else { continue }
        let bar = min(Self.barCount - 1, sample * Self.barCount / totalSamples)
        peaks[bar] = max(peaks[bar], min(1, amplitude))
      }
    }
    guard reader.status != .failed else { throw AudioAnalysisError.conversionFailed }
    let maximum = peaks.max() ?? 0
    let levels = maximum > 0 ? peaks.map { sqrt($0 / maximum) } : peaks
    return [
      "durationUs": Int64((seconds * 1_000_000).rounded()),
      "levels": levels,
    ]
  }
}
