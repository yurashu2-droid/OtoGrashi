import AVFoundation
import Foundation

enum AudioRenderError: Error, Equatable {
  case unsupportedContract
  case eventOutOfBounds
  case missingAsset
  case sourceOutOfBounds
  case readFailed
  case writeFailed
  case cancelled
  case duplicateOperationId
}

struct EventFadesPayload: Codable, Equatable {
  let fadeInSamples: Int
  let fadeOutSamples: Int
}

struct SoundEventPayload: Codable, Equatable {
  let assetId: String
  let sourceStartSample: Int
  let destinationStartSample: Int
  let durationSamples: Int
  let gain: Double
  let fades: EventFadesPayload
  let pitchSemitones: Int?

  var effectivePitchSemitones: Int { pitchSemitones ?? 0 }
}

enum VideoLoopModePayload: String, Codable, Equatable {
  case loop
  case hold
  case once
}

struct RationalTimePayload: Codable, Equatable {
  let numerator: Int
  let denominator: Int
}

struct NormalizedCropPayload: Codable, Equatable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double

  var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && x >= 0 && y >= 0 && width > 0 && height > 0
      && x + width <= 1 && y + height <= 1
  }
}

struct VideoEventPayload: Codable, Equatable {
  let assetId: String
  let destinationStartSample: Int
  let durationSamples: Int
  let sourceVideoStartTime: RationalTimePayload
  let crop: NormalizedCropPayload
  let loopMode: VideoLoopModePayload

  private enum CodingKeys: String, CodingKey {
    case assetId
    case destinationStartSample
    case durationSamples
    case sourceVideoStartTime
    case crop
    case loopMode
  }
}

struct ArrangementPayload: Decodable, Equatable {
  static let supportedSchemaVersion = 1
  static let sampleRate = 48_000
  static let totalSamples = 720_000

  let schemaVersion: Int
  let sampleRate: Int
  let totalSamples: Int
  let templateId: String
  let templateVersion: Int
  let analysisVersion: Int
  let rendererVersion: Int
  let seed: Int
  let style: String
  let sourceAssetIds: [String]
  let unusableAssetIds: [String]
  let events: [SoundEventPayload]
  let videoEvents: [VideoEventPayload]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sampleRate
    case totalSamples
    case templateId
    case templateVersion
    case analysisVersion
    case rendererVersion
    case seed
    case style
    case sourceAssetIds
    case unusableAssetIds
    case events
    case videoEvents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    sampleRate = try container.decode(Int.self, forKey: .sampleRate)
    totalSamples = try container.decode(Int.self, forKey: .totalSamples)
    templateId = try container.decode(String.self, forKey: .templateId)
    templateVersion = try container.decode(Int.self, forKey: .templateVersion)
    analysisVersion = try container.decode(Int.self, forKey: .analysisVersion)
    rendererVersion = try container.decode(Int.self, forKey: .rendererVersion)
    seed = try container.decode(Int.self, forKey: .seed)
    style = try container.decode(String.self, forKey: .style)
    sourceAssetIds = try Self.decodeBounded(
      String.self, from: container, forKey: .sourceAssetIds, maximum: 6
    )
    unusableAssetIds = try Self.decodeBounded(
      String.self, from: container, forKey: .unusableAssetIds, maximum: 6
    )
    events = try Self.decodeBounded(
      SoundEventPayload.self, from: container, forKey: .events, maximum: 64
    )
    videoEvents = try Self.decodeBounded(
      VideoEventPayload.self, from: container, forKey: .videoEvents, maximum: 64
    )

    guard schemaVersion == Self.supportedSchemaVersion,
      sampleRate == Self.sampleRate,
      totalSamples == Self.totalSamples,
      templateVersion == 1,
      analysisVersion == 1,
      rendererVersion == 1,
      !templateId.isEmpty,
      ["sparse", "swaying", "lively"].contains(style),
      Set(sourceAssetIds).count == sourceAssetIds.count,
      events.count == videoEvents.count
    else { throw AudioRenderError.unsupportedContract }

    for index in events.indices {
      let event = events[index]
      let video = videoEvents[index]
      let (sourceEnd, sourceOverflow) = event.sourceStartSample.addingReportingOverflow(
        event.durationSamples
      )
      let (destinationEnd, destinationOverflow) = event.destinationStartSample
        .addingReportingOverflow(event.durationSamples)
      let (fadeTotal, fadeOverflow) = event.fades.fadeInSamples.addingReportingOverflow(
        event.fades.fadeOutSamples
      )
      guard !sourceOverflow, !destinationOverflow, !fadeOverflow,
        sourceEnd > event.sourceStartSample,
        event.sourceStartSample >= 0,
        event.destinationStartSample >= 0,
        destinationEnd <= Self.totalSamples,
        event.gain.isFinite,
        (0...1).contains(event.gain),
        (-3...3).contains(event.effectivePitchSemitones),
        event.fades.fadeInSamples >= 0,
        event.fades.fadeOutSamples >= 0,
        fadeTotal <= event.durationSamples,
        sourceAssetIds.contains(event.assetId),
        event.assetId == video.assetId,
        event.destinationStartSample == video.destinationStartSample,
        event.durationSamples == video.durationSamples,
        event.sourceStartSample == video.sourceVideoStartTime.numerator,
        video.sourceVideoStartTime.denominator == Self.sampleRate,
        video.crop.isValid
      else { throw AudioRenderError.eventOutOfBounds }
    }
  }

  private static func decodeBounded<Value: Decodable>(
    _ type: Value.Type,
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys,
    maximum: Int
  ) throws -> [Value] {
    var values = try container.nestedUnkeyedContainer(forKey: key)
    if let count = values.count, count > maximum {
      throw AudioRenderError.unsupportedContract
    }
    var decoded: [Value] = []
    while !values.isAtEnd {
      guard decoded.count < maximum else { throw AudioRenderError.unsupportedContract }
      decoded.append(try values.decode(Value.self))
    }
    return decoded
  }
}

struct AudioRenderReport: Equatable {
  let url: URL
  let sampleCount: Int
  let fileLength: Int
  let readChunkFrameCounts: [Int]
  let sampleRate: Int
  let channels: Int
  let peak: Double
  let nonFiniteCount: Int
}

struct AudioRenderer {
  static let maximumNormalizationGain: Float = 4
  static let targetPeak: Float = 0.92
  static let loopCrossfadeSamples = 240

  let originalGain: Float
  let accompanimentGain: Float
  private let reader = NativePCMReader()

  init(originalGain: Float = 1, accompanimentGain: Float = 0.025) {
    self.originalGain = max(0, min(originalGain.isFinite ? originalGain : 0, 1))
    self.accompanimentGain = max(
      0,
      min(accompanimentGain.isFinite ? accompanimentGain : 0, 0.1)
    )
  }

  func render(
    arrangement: ArrangementPayload,
    assets: [String: URL],
    outputURL: URL,
    cancellation: CancellationToken
  ) async throws -> AudioRenderReport {
    try checkCancellation(cancellation)
    var mix = Array(repeating: Float(0), count: ArrangementPayload.totalSamples)

    for index in arrangement.events.indices {
      try checkCancellation(cancellation)
      let event = arrangement.events[index]
      guard let url = assets[event.assetId] else { throw AudioRenderError.missingAsset }
      let loopMode = arrangement.videoEvents[index].loopMode
      let trackRange = try reader.trackRange(url: url)
      let sourceEnd = event.sourceStartSample + event.durationSamples
      let destinationEnd = event.destinationStartSample + event.durationSamples
      let preRoll = min(
        240,
        min(
          event.destinationStartSample,
          max(0, event.sourceStartSample - trackRange.startSample)
        )
      )
      let postRoll = min(
        240,
        min(
          ArrangementPayload.totalSamples - destinationEnd,
          max(0, trackRange.endSample - sourceEnd)
        )
      )
      let renderedDuration = event.durationSamples + preRoll + postRoll
      guard event.sourceStartSample >= trackRange.startSample else {
        throw AudioRenderError.sourceOutOfBounds
      }
      if loopMode == .once, sourceEnd > trackRange.endSample {
        throw AudioRenderError.sourceOutOfBounds
      }
      let decoded = try reader.readTimeline(
        url: url,
        startSample: event.sourceStartSample - preRoll,
        durationSamples: renderedDuration,
        cancellation: cancellation
      )
      let eventSamples: [Float]
      if sourceEnd > trackRange.endSample {
        guard loopMode != .once,
          let coveredEnd = decoded.coveredRanges.last?.upperBound
        else { throw AudioRenderError.sourceOutOfBounds }
        let availableCount = coveredEnd - decoded.requestedRange.lowerBound
        guard availableCount > 0 else { throw AudioRenderError.sourceOutOfBounds }
        eventSamples = loop(
          Array(decoded.samples.prefix(availableCount)),
          count: renderedDuration,
          crossfadeSamples: Self.loopCrossfadeSamples
        )
      } else {
        eventSamples = decoded.samples
      }
      let pitched = pitchPreservingDuration(
        eventSamples,
        semitones: event.effectivePitchSemitones
      )
      mixEvent(
        pitched,
        destinationStart: event.destinationStartSample - preRoll,
        eventGain: Float(event.gain),
        fadeInSamples: max(event.fades.fadeInSamples, min(120, renderedDuration / 4)),
        fadeOutSamples: max(event.fades.fadeOutSamples, min(120, renderedDuration / 4)),
        into: &mix
      )
    }

    if accompanimentGain > 0 {
      addAccompaniment(into: &mix)
    }
    try checkCancellation(cancellation)
    finalize(&mix)
    try checkCancellation(cancellation)
    try write(samples: mix, to: outputURL)
    if cancellation.isCancelled {
      try? FileManager.default.removeItem(at: outputURL)
      throw AudioRenderError.cancelled
    }
    return try inspectWrittenOutput(outputURL)
  }

  // Two crossing read heads resample short grains while their output clock
  // stays fixed. The dry layer retains the recorded voice and attacks.
  func pitchPreservingDuration(_ source: [Float], semitones: Int) -> [Float] {
    let grainLength = 2_048
    guard semitones != 0, (-3...3).contains(semitones),
      source.count >= grainLength, source.allSatisfy(\.isFinite)
    else { return source }
    let ratio = pow(2.0, Double(semitones) / 12)
    var shifted = Array(repeating: Float(0), count: source.count)
    let windows = (0..<grainLength).map { phase in
      Float(0.5 - 0.5 * cos(2 * .pi * Double(phase) / Double(grainLength)))
    }
    for index in shifted.indices {
      var weighted: Float = 0
      var weight: Float = 0
      for head in 0..<2 {
        let offset = head * grainLength / 2
        let phase = (index + offset) % grainLength
        let position = Double(index) + (ratio - 1) * Double(phase)
        guard position >= 0, position < Double(source.count - 1) else { continue }
        let lower = Int(position)
        let fraction = Float(position - Double(lower))
        let value = source[lower] * (1 - fraction) + source[lower + 1] * fraction
        weighted += value * windows[phase]
        weight += windows[phase]
      }
      let wet = weight > 0 ? weighted / weight : source[index]
      shifted[index] = source[index] * 0.35 + wet * 0.65
    }
    return shifted
  }

  private func mixEvent(
    _ source: [Float],
    destinationStart: Int,
    eventGain: Float,
    fadeInSamples: Int,
    fadeOutSamples: Int,
    into destination: inout [Float]
  ) {
    let gain = eventGain * originalGain
    for offset in source.indices {
      var envelope: Float = 1
      if fadeInSamples > 0, offset < fadeInSamples {
        envelope *= Float(offset) / Float(fadeInSamples)
      }
      let framesFromEnd = source.count - 1 - offset
      if fadeOutSamples > 0, framesFromEnd < fadeOutSamples {
        envelope *= Float(framesFromEnd) / Float(fadeOutSamples)
      }
      let sample = source[offset].isFinite ? source[offset] : 0
      destination[destinationStart + offset] += sample * gain * envelope
    }
  }

  private func loop(
    _ source: [Float],
    count: Int,
    crossfadeSamples: Int
  ) -> [Float] {
    guard source.count > 1 else {
      return Array(repeating: source.first ?? 0, count: count)
    }
    let crossfade = min(crossfadeSamples, source.count / 4)
    let stride = source.count - crossfade
    var result = Array(repeating: Float(0), count: count)
    for index in result.indices {
      let phase = index % stride
      var value = source[phase]
      if crossfade > 0, index >= stride, phase < crossfade {
        let t = Float(phase + 1) / Float(crossfade)
        value = source[stride + phase] * (1 - t) + source[phase] * t
      }
      result[index] = value.isFinite ? value : 0
    }
    return result
  }

  private func addAccompaniment(into mix: inout [Float]) {
    let beat = 22_500
    let tail = 4_800
    for start in stride(from: 0, to: mix.count, by: beat) {
      for offset in 0..<min(tail, mix.count - start) {
        let envelope = exp(-5 * Float(offset) / Float(tail))
        let phase = 2 * Float.pi * 110 * Float(offset) / 48_000
        mix[start + offset] += sin(phase) * envelope * accompanimentGain
      }
    }
  }

  private func finalize(_ samples: inout [Float]) {
    var peak: Float = 0
    for index in samples.indices {
      if !samples[index].isFinite { samples[index] = 0 }
      peak = max(peak, abs(samples[index]))
    }
    let normalization: Float
    if peak > 0 {
      normalization = min(Self.maximumNormalizationGain, Self.targetPeak / peak)
    } else {
      normalization = 1
    }
    for index in samples.indices {
      let normalized = samples[index] * normalization
      samples[index] = max(-1, min(1, normalized))
    }
  }

  private func write(samples: [Float], to url: URL) throws {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(ArrangementPayload.sampleRate),
      channels: 1,
      interleaved: false
    ), let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(samples.count)
    ), let channel = buffer.floatChannelData?[0]
    else { throw AudioRenderError.writeFailed }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for index in samples.indices { channel[index] = samples[index] }
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      try file.write(from: buffer)
      file.close()
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw AudioRenderError.writeFailed
    }
  }

  private func inspectWrittenOutput(_ url: URL) throws -> AudioRenderReport {
    do {
      let file = try AVAudioFile(forReading: url)
      let format = file.processingFormat
      guard let fileLength = Int(exactly: file.length) else {
        throw AudioRenderError.writeFailed
      }
      var peak = 0.0
      var nonFiniteCount = 0
      var sampleCount = 0
      var readChunkFrameCounts: [Int] = []
      while file.framePosition < file.length {
        let remaining = file.length - file.framePosition
        guard remaining > 0 else { throw AudioRenderError.writeFailed }
        let requestedFrames = AVAudioFrameCount(min(Int64(32_768), remaining))
        guard let buffer = AVAudioPCMBuffer(
          pcmFormat: format,
          frameCapacity: requestedFrames
        ) else { throw AudioRenderError.writeFailed }
        try file.read(into: buffer, frameCount: requestedFrames)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { throw AudioRenderError.writeFailed }
        guard let channels = buffer.floatChannelData else {
          throw AudioRenderError.writeFailed
        }
        for channelIndex in 0..<Int(format.channelCount) {
          for frame in 0..<frameCount {
            let sample = channels[channelIndex][frame]
            if sample.isFinite {
              peak = max(peak, Double(abs(sample)))
            } else {
              nonFiniteCount += 1
            }
          }
        }
        sampleCount += frameCount
        readChunkFrameCounts.append(frameCount)
      }
      guard fileLength == ArrangementPayload.totalSamples,
        sampleCount == ArrangementPayload.totalSamples
      else { throw AudioRenderError.writeFailed }
      return AudioRenderReport(
        url: url,
        sampleCount: sampleCount,
        fileLength: fileLength,
        readChunkFrameCounts: readChunkFrameCounts,
        sampleRate: Int(format.sampleRate.rounded()),
        channels: Int(format.channelCount),
        peak: peak,
        nonFiniteCount: nonFiniteCount
      )
    } catch let error as AudioRenderError {
      throw error
    } catch {
      throw AudioRenderError.writeFailed
    }
  }

  private func checkCancellation(_ token: CancellationToken) throws {
    if token.isCancelled { throw AudioRenderError.cancelled }
  }
}
