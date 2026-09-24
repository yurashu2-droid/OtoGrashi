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
  let pitchSemitones: Double?
  var sourceDurationSamples: Int? = nil
  var targetMidiNote: Double? = nil
  var pitchSteps: [EverydayAudioDSP.PitchStep]? = nil
  var reverse: Bool? = nil
  var treatment: String? = nil

  var effectiveSourceDurationSamples: Int { sourceDurationSamples ?? durationSamples }
  var isReversed: Bool { reverse ?? false }
  var effectivePitchSemitones: Double { pitchSemitones ?? 0 }
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
    case sourceDurationSamples, reverse, mirror
  }
}

struct ArrangementPayload: Decodable, Equatable {
  static let supportedSchemaVersion = 1
  static let sampleRate = 48_000
  static let totalSamples = 720_000
  static let maximumEvents = 256

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
      SoundEventPayload.self, from: container, forKey: .events, maximum: Self.maximumEvents
    )
    videoEvents = try Self.decodeBounded(
      VideoEventPayload.self, from: container, forKey: .videoEvents, maximum: Self.maximumEvents
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
          (event.targetMidiNote != nil && event.sourceDurationSamples != nil),
        event.sourceStartSample >= 0,
        (1...Self.totalSamples).contains(event.effectiveSourceDurationSamples),
        event.targetMidiNote == nil || (event.targetMidiNote!.isFinite && (24...100).contains(event.targetMidiNote!)),
        (event.targetMidiNote == nil && !event.isReversed) || event.sourceDurationSamples != nil,
        ["original", "phrase", "rhythm", "tuned"].contains(event.treatment ?? "original"),
        event.destinationStartSample >= 0,
        destinationEnd <= Self.totalSamples,
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
    var mix = Array(repeating: Float(0), count: ArrangementPayload.totalSamples)
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
        let curveKey = (event.pitchSteps ?? []).map { "\($0.offsetSamples):\($0.midiNote)" }.joined(separator: ",")
        let key = "\(curveKey)|\(event.assetId)|\(event.sourceStartSample)|\(sourceDuration)|\(event.durationSamples)|\(event.targetMidiNote.map(String.init(describing:)) ?? "dry")|\(event.isReversed)|\(event.effectivePitchSemitones)"
        let processed: [Float]
        if let cached = musicalFragments[key] {
          processed = cached
        } else {
          let decoded = try reader.readTimeline(url: url,
            startSample: event.sourceStartSample, durationSamples: sourceDuration,
            cancellation: cancellation)
          let leveled = EverydayAudioDSP.matchLevel(decoded.samples)
          do {
            let shaped = try EverydayAudioDSP.render(leveled,
              count: event.durationSamples, targetMidiNote: event.targetMidiNote,
              reverse: event.isReversed, pitchSteps: event.pitchSteps ?? [])
            processed = event.targetMidiNote == nil && event.effectivePitchSemitones != 0
              ? try pitchPreservingDuration(shaped, semitones: event.effectivePitchSemitones,
                  cancellation: cancellation, latencyCache: &pitchLatencies) : shaped
          } catch let error as AudioRenderError { throw error }
          catch { throw AudioRenderError.pitchProcessingFailed }
          if cachedPitchSamples <= Self.maximumCachedPitchSamples - processed.count {
            musicalFragments[key] = processed
            cachedPitchSamples += processed.count
          }
        }
        mixEvent(processed, destinationStart: event.destinationStartSample,
          eventGain: Float(event.gain), fadeInSamples: event.fades.fadeInSamples,
          fadeOutSamples: event.fades.fadeOutSamples, into: &mix)
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
