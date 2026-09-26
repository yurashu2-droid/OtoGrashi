import AVFoundation
import Foundation

enum AudioRenderError: Error, Equatable {
  case unsupportedContract
  case eventOutOfBounds
  case missingAsset
  case sourceOutOfBounds
  case readFailed
  case writeFailed
  case pitchProcessingFailed
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
  var partIndex: Int? = nil
  let pitchSemitones: Double?
  var sourceDurationSamples: Int? = nil
  var targetMidiNote: Double? = nil
  var pitchSteps: [EverydayAudioDSP.NoteStep]? = nil
  var reverse: Bool? = nil
  var treatment: String? = nil
  /// MAD fields: what the event plays and how its read position moves.
  var role: String? = nil
  var rate: Double? = nil
  var glide: Double? = nil
  var scratch: Double? = nil
  var scratchPeriod: Int? = nil
  var gate: Int? = nil

  static let roles: Set<String> = [
    "melody", "bass", "kick", "snare", "hat", "chop", "phrase", "fx", "echo", "stab",
  ]
  var hasMotion: Bool { rate != nil || glide != nil || scratch != nil }

  var effectiveSourceDurationSamples: Int { sourceDurationSamples ?? durationSamples }
  var isReversed: Bool { reverse ?? false }
  var effectivePitchSemitones: Double { pitchSemitones ?? 0 }
  /// A phrase with a different second beat must not reuse the first phrase's
  /// PCM, even when the file, source window and first note are identical.
  var musicalCacheKey: String {
    let automation = (pitchSteps ?? []).map {
      "\($0.offsetSamples):\($0.durationSamples):\($0.midiNote)"
    }.joined(separator: ",")
    return "\(automation)|\(assetId)|\(sourceStartSample)|\(effectiveSourceDurationSamples)|\(durationSamples)|\(targetMidiNote.map(String.init(describing:)) ?? "dry")|\(isReversed)|\(effectivePitchSemitones)|\(role ?? "")|\(rate ?? 0)|\(glide ?? 0)|\(scratch ?? 0)|\(scratchPeriod ?? 0)|\(gate ?? 0)"
  }

  /// Source read offset at one output sample, in closed form (the picture
  /// asks for single frames; the sound uses the array below).
  static func motionPosition(at i: Int, count: Int, rate: Double?, glide: Double?, scratch: Double?,
                             scratchPeriod: Int?) -> Double {
    let speed = rate ?? 1
    if let scratch {
      let period = Double(max(1_200, scratchPeriod ?? 11_250))
      let phase = Double(i).truncatingRemainder(dividingBy: period) / period
      let wave = phase < 0.35 ? phase / 0.35 : 1 - (phase - 0.35) / 0.65
      return wave * scratch * 48_000
    }
    if let glide, glide != 0 {
      let k = glide / 12 / Double(max(1, count))
      return speed * (pow(2, k * Double(i)) - 1) / (k * log(2))
    }
    return Double(i) * speed
  }

  /// Source read offset for each output sample of a motion event. The
  /// picture uses the same positions, so a scratch rocks the face too.
  static func motionPositions(count: Int, rate: Double?, glide: Double?, scratch: Double?,
                              scratchPeriod: Int?) -> [Double] {
    guard count > 0 else { return [] }
    var positions = [Double](repeating: 0, count: count)
    let speed = rate ?? 1
    if let scratch {
      let period = Double(max(1_200, scratchPeriod ?? 11_250))
      let depth = scratch * 48_000
      for i in 0..<count {
        let phase = Double(i).truncatingRemainder(dividingBy: period) / period
        // a hand on the record: quick push forward, slower pull back
        let wave = phase < 0.35 ? phase / 0.35 : 1 - (phase - 0.35) / 0.65
        positions[i] = wave * depth
      }
      return positions
    }
    if let glide {
      var position = 0.0
      for i in 0..<count {
        positions[i] = position
        position += speed * pow(2, glide * Double(i) / Double(count) / 12)
      }
      return positions
    }
    for i in 0..<count { positions[i] = Double(i) * speed }
    return positions
  }
}

/// A whole-mix effect at one moment of a MAD song.
struct MasterEffectPayload: Codable, Equatable {
  let type: String
  let startSample: Int
  let durationSamples: Int
  var kickSamples: [Int]? = nil

  static let types: Set<String> = ["tapestop", "sweep", "bitcrush", "sidechain", "halftime"]
}

struct SongSectionPayload: Codable, Equatable {
  let fromBar: Int
  let toBar: Int
  let energy: String
}

enum VideoLoopModePayload: String, Codable, Hashable {
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
  var sourceDurationSamples: Int? = nil
  var reverse: Bool? = nil
  var partIndex: Int? = nil
  var mirror: Bool? = nil

  var effectiveSourceDurationSamples: Int { sourceDurationSamples ?? durationSamples }
  var isReversed: Bool { reverse ?? false }
  var isMirrored: Bool { mirror ?? false }

  private enum CodingKeys: String, CodingKey {
    case assetId
    case destinationStartSample
    case durationSamples
    case sourceVideoStartTime
    case crop
    case loopMode
    case sourceDurationSamples, reverse, mirror, partIndex
  }
}

struct ArrangementPayload: Decodable, Equatable {
  static let supportedSchemaVersion = 1
  static let sampleRate = 48_000
  static let totalSamples = 720_000
  static let maximumEvents = 512
  static let maximumTotalSamples = 1_440_000

  let schemaVersion: Int
  let sampleRate: Int
  let totalSamples: Int
  let templateId: String
  let templateVersion: Int
  let analysisVersion: Int
  let rendererVersion: Int
  let seed: Int
  let performanceMode: String
  let style: String
  let sourceAssetIds: [String]
  let unusableAssetIds: [String]
  let events: [SoundEventPayload]
  let videoEvents: [VideoEventPayload]
  let masterEffects: [MasterEffectPayload]
  let sections: [SongSectionPayload]
  let songTitle: String?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case sampleRate
    case totalSamples
    case templateId
    case templateVersion
    case analysisVersion
    case rendererVersion
    case seed
    case performanceMode
    case style
    case sourceAssetIds
    case unusableAssetIds
    case events
    case videoEvents
    case masterEffects, sections, songTitle
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
    performanceMode = try container.decodeIfPresent(String.self, forKey: .performanceMode) ?? "natural"
    style = try container.decode(String.self, forKey: .style)
    sourceAssetIds = try Self.decodeBounded(
      String.self, from: container, forKey: .sourceAssetIds, maximum: 6
    )
    unusableAssetIds = try Self.decodeBounded(
      String.self, from: container, forKey: .unusableAssetIds, maximum: 6
    )
    events = try Self.decodeBounded(
      SoundEventPayload.self, from: container, forKey: .events, maximum: Self.maximumEvents
    )
    videoEvents = try Self.decodeBounded(
      VideoEventPayload.self, from: container, forKey: .videoEvents, maximum: Self.maximumEvents
    )
    masterEffects = try container.contains(.masterEffects)
      ? Self.decodeBounded(MasterEffectPayload.self, from: container, forKey: .masterEffects, maximum: 16)
      : []
    sections = try container.contains(.sections)
      ? Self.decodeBounded(SongSectionPayload.self, from: container, forKey: .sections, maximum: 32)
      : []
    songTitle = try container.decodeIfPresent(String.self, forKey: .songTitle)
    guard masterEffects.allSatisfy({ fx in
        MasterEffectPayload.types.contains(fx.type) && fx.startSample >= 0 && fx.durationSamples > 0 &&
          fx.startSample <= totalSamples - fx.durationSamples &&
          (fx.kickSamples ?? []).count <= 128 &&
          (fx.kickSamples ?? []).allSatisfy { (0..<totalSamples).contains($0) }
      }),
      sections.allSatisfy({ ["calm", "mid", "high"].contains($0.energy) && $0.fromBar >= 0 &&
        $0.toBar > $0.fromBar && $0.toBar <= totalSamples / 90_000 }),
      songTitle == nil || (songTitle!.count <= 40 && !songTitle!.isEmpty)
    else { throw AudioRenderError.unsupportedContract }

    guard schemaVersion == Self.supportedSchemaVersion,
      sampleRate == Self.sampleRate,
      [Self.totalSamples, Self.maximumTotalSamples].contains(totalSamples),
      ["natural", "mad", "mosaic", "vinyl", "sampler", "voiceLead", "neonTune", "loopStation"].contains(performanceMode),
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
        event.effectiveSourceDurationSamples
      )
      let (destinationEnd, destinationOverflow) = event.destinationStartSample
        .addingReportingOverflow(event.durationSamples)
      let (fadeTotal, fadeOverflow) = event.fades.fadeInSamples.addingReportingOverflow(
        event.fades.fadeOutSamples
      )
      guard !sourceOverflow, !destinationOverflow, !fadeOverflow,
        sourceEnd > event.sourceStartSample,
        EverydayAudioDSP.validSteps(event.pitchSteps ?? [], count: event.durationSamples),
        (event.pitchSteps ?? []).isEmpty ||
          event.sourceDurationSamples != nil,
        event.sourceStartSample >= 0,
        (1...Self.totalSamples).contains(event.effectiveSourceDurationSamples),
        event.targetMidiNote == nil || (event.targetMidiNote!.isFinite && (24...100).contains(event.targetMidiNote!)),
        (event.targetMidiNote == nil && !event.isReversed && !event.hasMotion) || event.sourceDurationSamples != nil,
        event.role == nil || SoundEventPayload.roles.contains(event.role!),
        event.rate == nil || (event.rate!.isFinite && (0.25...4).contains(event.rate!)),
        event.glide == nil || (event.glide!.isFinite && abs(event.glide!) <= 24),
        event.scratch == nil || (event.scratch!.isFinite && (0...0.5).contains(event.scratch!)),
        event.scratchPeriod == nil || (1_200...90_000).contains(event.scratchPeriod!),
        event.gate == nil || (1...8).contains(event.gate!),
        ["original", "phrase", "rhythm", "tuned"].contains(event.treatment ?? "original"),
        event.destinationStartSample >= 0,
        destinationEnd <= totalSamples,
        (0...15).contains(event.partIndex ?? 0),
        (event.partIndex ?? 0) == (video.partIndex ?? 0),
        event.gain.isFinite,
        (0...1).contains(event.gain),
        event.effectivePitchSemitones.isFinite,
        (-12.0...12.0).contains(event.effectivePitchSemitones),
        event.fades.fadeInSamples >= 0,
        event.fades.fadeOutSamples >= 0,
        fadeTotal <= event.durationSamples,
        sourceAssetIds.contains(event.assetId),
        event.assetId == video.assetId,
        event.destinationStartSample == video.destinationStartSample,
        event.durationSamples == video.durationSamples,
        event.effectiveSourceDurationSamples == video.effectiveSourceDurationSamples,
        event.isReversed == video.isReversed,
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
  /// One peak every 1,600 samples for each event, in arrangement order.
  var eventPeaks: [[Float]] = []
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
  private static let maximumCachedPitchSamples = 4_000_000
  private static let maximumCacheableEventSamples = 48_000

  private struct PitchedFragmentKey: Hashable {
    let assetId: String
    let sourceStartSample: Int
    let durationSamples: Int
    let preRoll: Int
    let postRoll: Int
    let loopMode: VideoLoopModePayload
    let pitchSemitones: Double
  }

  let originalGain: Float
  let accompanimentGain: Float
  private let reader = NativePCMReader()

  init(originalGain: Float = 1, accompanimentGain: Float = 0) {
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
    var mix = Array(repeating: Float(0), count: arrangement.totalSamples)
    // Kicks are mixed apart so a sidechain can duck everything else under them.
    var kickMix = Array(repeating: Float(0), count: arrangement.totalSamples)
    var eventPeaks: [[Float]] = []
    var pitchLatencies: [Double: Int] = [:]
    var trackRanges: [String: NativePCMReader.TrackRange] = [:]
    var pitchedFragments: [PitchedFragmentKey: [Float]] = [:]
    var cachedPitchSamples = 0
    var musicalFragments: [String: [Float]] = [:]

    for index in arrangement.events.indices {
      try checkCancellation(cancellation)
      let event = arrangement.events[index]
      guard let url = assets[event.assetId] else { throw AudioRenderError.missingAsset }
      let loopMode = arrangement.videoEvents[index].loopMode
      let trackRange: NativePCMReader.TrackRange
      if let cached = trackRanges[event.assetId] {
        trackRange = cached
      } else {
        trackRange = try reader.trackRange(url: url)
        trackRanges[event.assetId] = trackRange
      }
      if let sourceDuration = event.sourceDurationSamples {
        // New events own their exact selected range. Never read beyond the
        // trim, and never add pre/post-roll outside the visible event clock.
        guard event.sourceStartSample >= trackRange.startSample,
          event.sourceStartSample + sourceDuration <= trackRange.endSample
        else { throw AudioRenderError.sourceOutOfBounds }
        let key = event.musicalCacheKey
        var processed: [Float]
        if let cached = musicalFragments[key] {
          processed = cached
        } else if event.hasMotion {
          let decoded = try reader.readTimeline(url: url,
            startSample: event.sourceStartSample, durationSamples: sourceDuration,
            cancellation: cancellation)
          processed = Self.motionRender(EverydayAudioDSP.matchLevel(decoded.samples), event: event)
          if cachedPitchSamples <= Self.maximumCachedPitchSamples - processed.count {
            musicalFragments[key] = processed
            cachedPitchSamples += processed.count
          }
        } else {
          let decoded = try reader.readTimeline(url: url,
            startSample: event.sourceStartSample, durationSamples: sourceDuration,
            cancellation: cancellation)
          let leveled = EverydayAudioDSP.matchLevel(decoded.samples)
          do {
            let shaped = try EverydayAudioDSP.render(leveled,
              count: event.durationSamples, targetMidiNote: event.targetMidiNote,
              reverse: event.isReversed, pitchSteps: event.pitchSteps ?? [],
              hardTune: arrangement.performanceMode == "neonTune" || arrangement.performanceMode == "mad")
            processed = event.targetMidiNote == nil && (event.pitchSteps?.isEmpty ?? true) && event.effectivePitchSemitones != 0
              ? try pitchPreservingDuration(shaped, semitones: event.effectivePitchSemitones,
                  cancellation: cancellation, latencyCache: &pitchLatencies) : shaped
          } catch let error as AudioRenderError { throw error }
          catch { throw AudioRenderError.pitchProcessingFailed }
          if cachedPitchSamples <= Self.maximumCachedPitchSamples - processed.count {
            musicalFragments[key] = processed
            cachedPitchSamples += processed.count
          }
        }
        if let gate = event.gate {
          processed = Self.gated(processed, piecesPerBeat: gate)
        }
        if event.role == "kick" {
          eventPeaks.append(mixEvent(processed, destinationStart: event.destinationStartSample,
            eventGain: Float(event.gain), fadeInSamples: event.fades.fadeInSamples,
            fadeOutSamples: event.fades.fadeOutSamples, into: &kickMix))
        } else {
          eventPeaks.append(mixEvent(processed, destinationStart: event.destinationStartSample,
            eventGain: Float(event.gain), fadeInSamples: event.fades.fadeInSamples,
            fadeOutSamples: event.fades.fadeOutSamples, into: &mix))
        }
        continue
      }
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
          arrangement.totalSamples - destinationEnd,
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
      let key = PitchedFragmentKey(
        assetId: event.assetId,
        sourceStartSample: event.sourceStartSample,
        durationSamples: event.durationSamples,
        preRoll: preRoll,
        postRoll: postRoll,
        loopMode: loopMode,
        pitchSemitones: event.effectivePitchSemitones
      )
      let pitched: [Float]
      if let cached = pitchedFragments[key] {
        pitched = cached
      } else {
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
        pitched = try pitchPreservingDuration(
          eventSamples,
          semitones: event.effectivePitchSemitones,
          cancellation: cancellation,
          latencyCache: &pitchLatencies
        )
        if pitched.count <= Self.maximumCacheableEventSamples,
          cachedPitchSamples <= Self.maximumCachedPitchSamples - pitched.count {
          pitchedFragments[key] = pitched
          cachedPitchSamples += pitched.count
        }
      }
      eventPeaks.append(mixEvent(
        pitched,
        destinationStart: event.destinationStartSample - preRoll,
        eventGain: Float(event.gain),
        fadeInSamples: max(event.fades.fadeInSamples, min(120, renderedDuration / 4)),
        fadeOutSamples: max(event.fades.fadeOutSamples, min(120, renderedDuration / 4)),
        into: &mix
      ))
    }

    for effect in arrangement.masterEffects where effect.type == "sidechain" {
      Self.duck(&mix, effect: effect)
    }
    for index in mix.indices { mix[index] += kickMix[index] }
    for effect in arrangement.masterEffects {
      Self.applyMaster(&mix, effect: effect)
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
    var report = try inspectWrittenOutput(outputURL, expectedSamples: arrangement.totalSamples)
    report.eventPeaks = eventPeaks
    return report
  }

  // TimePitch retains rate=1 while changing pitch. Its processing latency is
  // measured with an impulse in the same padded graph, then removed so the
  // existing audio/video event clock and sample count remain unchanged.
  func pitchPreservingDuration(
    _ source: [Float],
    semitones: Double,
    cancellation: CancellationToken? = nil
  ) throws -> [Float] {
    var latencyCache: [Double: Int] = [:]
    return try pitchPreservingDuration(
      source,
      semitones: semitones,
      cancellation: cancellation,
      latencyCache: &latencyCache
    )
  }

  private func pitchPreservingDuration(
    _ source: [Float],
    semitones: Double,
    cancellation: CancellationToken?,
    latencyCache: inout [Double: Int]
  ) throws -> [Float] {
    if cancellation?.isCancelled == true { throw AudioRenderError.cancelled }
    guard semitones.isFinite, (-12.0...12.0).contains(semitones),
      source.count <= ArrangementPayload.totalSamples,
      source.allSatisfy(\.isFinite)
    else { throw AudioRenderError.pitchProcessingFailed }
    if semitones == 0 || source.isEmpty || source.allSatisfy({ $0 == 0 }) {
      return source
    }

    let latency: Int
    if let cached = latencyCache[semitones] {
      latency = cached
    } else {
      let calibration = try renderTimePitch(
        [0.8], semitones: semitones, cancellation: cancellation
      )
      guard let peakIndex = calibration.indices.max(by: {
        abs(calibration[$0]) < abs(calibration[$1])
      }),
        abs(calibration[peakIndex]) > 0.000_1,
        peakIndex > 0,
        peakIndex < Self.pitchPaddingSamples + Self.maximumPitchLatencySamples
      else { throw AudioRenderError.pitchProcessingFailed }
      latency = peakIndex - Self.pitchPaddingSamples
      latencyCache[semitones] = latency
    }

    let rendered = try renderTimePitch(
      source, semitones: semitones, cancellation: cancellation
    )
    let start = Self.pitchPaddingSamples + latency
    let end = start + source.count
    guard end <= rendered.count else { throw AudioRenderError.pitchProcessingFailed }
    let shifted = Array(rendered[start..<end])
    guard shifted.allSatisfy(\.isFinite),
      shifted.contains(where: { $0 != 0 })
    else { throw AudioRenderError.pitchProcessingFailed }
    return shifted
  }

  private static let pitchPaddingSamples = 4_096
  private static let maximumPitchLatencySamples = 32_768
  private static let pitchRenderChunkSamples = 4_096

  private func renderTimePitch(
    _ source: [Float],
    semitones: Double,
    cancellation: CancellationToken?
  ) throws -> [Float] {
    let frameCount = Self.pitchPaddingSamples + source.count
      + Self.maximumPitchLatencySamples
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Double(ArrangementPayload.sampleRate),
      channels: 1,
      interleaved: false
    ), let input = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: AVAudioFrameCount(frameCount)
    ), let inputChannel = input.floatChannelData?[0],
      let output = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(Self.pitchRenderChunkSamples)
      )
    else { throw AudioRenderError.pitchProcessingFailed }
    input.frameLength = AVAudioFrameCount(frameCount)
    for frame in 0..<frameCount { inputChannel[frame] = 0 }
    for frame in source.indices {
      inputChannel[Self.pitchPaddingSamples + frame] = source[frame]
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    timePitch.rate = 1
    timePitch.pitch = Float(semitones * 100)
    timePitch.overlap = 16
    engine.attach(player)
    engine.attach(timePitch)
    engine.connect(player, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    defer {
      player.stop()
      engine.stop()
    }

    do {
      try engine.enableManualRenderingMode(
        .offline,
        format: format,
        maximumFrameCount: AVAudioFrameCount(Self.pitchRenderChunkSamples)
      )
      player.scheduleBuffer(input, completionHandler: nil)
      try engine.start()
      player.play()

      var rendered: [Float] = []
      rendered.reserveCapacity(frameCount)
      var consecutiveEmptyRenders = 0
      while rendered.count < frameCount {
        if cancellation?.isCancelled == true { throw AudioRenderError.cancelled }
        let requested = AVAudioFrameCount(
          min(Self.pitchRenderChunkSamples, frameCount - rendered.count)
        )
        let status = try engine.renderOffline(requested, to: output)
        guard output.frameLength <= requested else {
          throw AudioRenderError.pitchProcessingFailed
        }
        switch status {
        case .success, .cannotDoInCurrentContext:
          // A non-success status can still carry rendered frames. Advance by
          // frameLength, then retry temporary context failures on the next call.
          if output.frameLength > 0 {
            guard let outputChannel = output.floatChannelData?[0] else {
              throw AudioRenderError.pitchProcessingFailed
            }
            rendered.append(contentsOf: UnsafeBufferPointer(
              start: outputChannel,
              count: Int(output.frameLength)
            ))
            consecutiveEmptyRenders = 0
          } else {
            consecutiveEmptyRenders += 1
            if consecutiveEmptyRenders >= 16 {
              throw AudioRenderError.pitchProcessingFailed
            }
          }
        case .insufficientDataFromInputNode, .error:
          // This graph uses a player node, never the input node.
          throw AudioRenderError.pitchProcessingFailed
        @unknown default:
          throw AudioRenderError.pitchProcessingFailed
        }
      }
      return rendered
    } catch let error as AudioRenderError {
      throw error
    } catch {
      throw AudioRenderError.pitchProcessingFailed
    }
  }

  /// Reads a motion event (sampler rate, riser glide, scratch) from its source span.
  static func motionRender(_ source: [Float], event: SoundEventPayload) -> [Float] {
    let positions = SoundEventPayload.motionPositions(count: event.durationSamples, rate: event.rate,
      glide: event.glide, scratch: event.scratch, scratchPeriod: event.scratchPeriod)
    var output = [Float](repeating: 0, count: positions.count)
    guard !source.isEmpty else { return output }
    for (i, position) in positions.enumerated() {
      let base = event.isReversed ? Double(source.count - 1) - position : position
      guard base >= 0, base < Double(source.count - 1) else { continue }
      let a = Int(base), t = Float(base - Double(a))
      output[i] = source[a] * (1 - t) + source[a + 1] * t
    }
    if event.role == "kick" {
      // a pitched-down attack becomes a thump: let it fall away quickly
      for i in output.indices { output[i] *= exp(-Float(i) / (0.07 * 48_000)) }
    }
    return output
  }

  /// Chops a held sound into pieces per beat with short ramps.
  static func gated(_ source: [Float], piecesPerBeat: Int) -> [Float] {
    let step = Double(22_500) / Double(max(1, piecesPerBeat))
    var output = source
    var level: Float = 1
    for i in output.indices {
      let phase = Double(i).truncatingRemainder(dividingBy: step) / step
      let target: Float = phase < 0.55 ? 1 : 0.04
      level += max(-1 / 96, min(1 / 96, target - level))
      output[i] *= level
    }
    return output
  }

  /// Everything but the kick dips on each kick and breathes back up.
  static func duck(_ mix: inout [Float], effect: MasterEffectPayload) {
    let release = Int(0.18 * 48_000)
    let end = min(mix.count, effect.startSample + effect.durationSamples)
    for kick in effect.kickSamples ?? [] where kick >= effect.startSample && kick < end {
      for offset in 0..<release where kick + offset < end {
        let recover = 1 - exp(-Double(offset) / (Double(release) / 4))
        mix[kick + offset] *= Float(0.35 + 0.65 * recover)
      }
    }
  }

  static func applyMaster(_ mix: inout [Float], effect: MasterEffectPayload) {
    let a = effect.startSample
    let n = effect.durationSamples
    let b = min(mix.count, a + n)
    guard b > a else { return }
    switch effect.type {
    case "tapestop":
      // the song slows to a halt: speed falls linearly from 1 to 0
      let original = Array(mix[a..<b])
      for i in 0..<(b - a) {
        let u = Double(i) / Double(n)
        let source = Double(n) * (u - u * u / 2)
        let j = Int(source), t = Float(source - Double(j))
        let x0 = j < original.count ? original[j] : 0
        let x1 = j + 1 < original.count ? original[j + 1] : x0
        mix[a + i] = (x0 * (1 - t) + x1 * t) * Float(1 - u * u * u)
      }
    case "sweep":
      // low-pass opening from 250 Hz to 16 kHz
      var y: Float = 0
      for i in 0..<(b - a) {
        let u = Double(i) / Double(n)
        let cutoff = 250 * pow(16_000.0 / 250, u)
        let alpha = Float(1 - exp(-2 * Double.pi * cutoff / 48_000))
        y += alpha * (mix[a + i] - y)
        mix[a + i] = y
      }
    case "bitcrush":
      var held: Float = 0
      for i in 0..<(b - a) {
        if i % 6 == 0 { held = mix[a + i] }
        mix[a + i] = (held * 7).rounded() / 7
      }
    default:
      break  // sidechain is applied before the kick is added; halftime is arranged
    }
  }

  private func mixEvent(
    _ source: [Float],
    destinationStart: Int,
    eventGain: Float,
    fadeInSamples: Int,
    fadeOutSamples: Int,
    into destination: inout [Float]
  ) -> [Float] {
    let gain = eventGain * originalGain
    var peaks = [Float](repeating: 0, count: (source.count + 1599) / 1600)
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
      let value = sample * gain * envelope
      destination[destinationStart + offset] += value
      peaks[offset / 1600] = max(peaks[offset / 1600], abs(value))
    }
    return peaks
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

  private func inspectWrittenOutput(_ url: URL, expectedSamples: Int = ArrangementPayload.totalSamples) throws -> AudioRenderReport {
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
      guard fileLength == expectedSamples,
        sampleCount == expectedSamples
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
