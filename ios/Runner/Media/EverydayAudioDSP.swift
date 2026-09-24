import Foundation

/// Local, source-derived pitch processing. No oscillator/backing track is played
/// independently of a recording. Foundation-only so the actual DSP is testable
/// on Linux as well as in the iOS renderer.
enum EverydayAudioDSP {
  static let sampleRate = 48_000
  struct Pitch: Equatable {
    let hertz: Double
    let confidence: Double
    var midiNote: Double { 69 + 12 * log2(hertz / 440) }
  }
  enum Failure: Error { case invalidInput }

  /// Interpolated YIN. Search the FIRST trough, including out-of-band lags,
  /// before accepting the range; otherwise high notes alias to lower octaves.
  static func estimate(_ samples: [Float], start: Int = 0, count: Int? = nil) -> Pitch? {
    let start = max(0, start)
    guard start < samples.count else { return nil }
    let n = min(count ?? 4096, samples.count - start)
    guard n >= 1024 else { return nil }
    let decimation = 2
    let rate = Double(sampleRate / decimation)
    var signal = [Double]()
    signal.reserveCapacity(n / decimation)
    for i in stride(from: start, to: start + n - 1, by: decimation) {
      let a = samples[i].isFinite ? Double(samples[i]) : 0
      let b = samples[i + 1].isFinite ? Double(samples[i + 1]) : 0
      signal.append((a + b) * 0.5)
    }
    let mean = signal.reduce(0, +) / Double(signal.count)
    for i in signal.indices { signal[i] -= mean }
    let variance = signal.reduce(0) { $0 + $1 * $1 } / Double(signal.count)
    guard variance > 0.000_000_01 else { return nil }
    let maxLag = min(Int(ceil(rate / 55)) + 1, signal.count / 2 - 1)
    let width = signal.count - maxLag - 1
    guard maxLag > 3, width > maxLag else { return nil }
    var cmnd = [Double](repeating: 1, count: maxLag + 2)
    var accumulated = 0.0
    for lag in 1...maxLag + 1 {
      var difference = 0.0
      for i in 0..<width {
        let delta = signal[i] - signal[i + lag]
        difference += delta * delta
      }
      accumulated += difference
      if accumulated > 0 { cmnd[lag] = difference * Double(lag) / accumulated }
    }
    var lag = 2
    while lag <= maxLag {
      if cmnd[lag] < 0.10 {
        while lag < maxLag && cmnd[lag + 1] < cmnd[lag] { lag += 1 }
        guard cmnd[lag + 1] >= cmnd[lag] else { return nil }
        let left = cmnd[lag - 1], mid = cmnd[lag], right = cmnd[lag + 1]
        let denominator = left - 2 * mid + right
        let correction = abs(denominator) > 1e-12
          ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
        let hz = rate / (Double(lag) + correction)
        guard (55...2000).contains(hz) else { return nil }
        return Pitch(hertz: hz, confidence: max(0, min(1, 1 - mid)))
      }
      lag += 1
    }
    return nil
  }

  /// A clip-level advisory pitch is only stable when windows agree. Rendering
  /// never trusts this value: it inspects the actual selected PCM fragment.
  static func stableNote(_ samples: [Float]) -> Double? {
    guard samples.count >= 4096 else { return nil }
    let available = samples.count - 4096
    let offsets = [available / 6, available / 2, available * 5 / 6]
    let notes = offsets.compactMap { estimate(samples, start: $0)?.midiNote }
    guard notes.count == 3, let lo = notes.min(), let hi = notes.max(), hi - lo < 0.5 else { return nil }
    return notes.sorted()[1]
  }

  /// Shared sample-clock mapping for looping / reverse audio AND video.
  static func sourceOffset(outputOffset: Int, sourceCount: Int, reverse: Bool) -> Int {
    guard sourceCount > 0 else { return 0 }
    let offset = max(0, outputOffset) % sourceCount
    return reverse ? sourceCount - 1 - offset : offset
  }

  static func matchLevel(_ source: [Float]) -> [Float] {
    guard !source.isEmpty else { return source }
    let energy = source.reduce(0.0) { $0 + Double($1.isFinite ? $1 * $1 : 0) }
    let rms = sqrt(energy / Double(source.count))
    let peak = Double(source.map { $0.isFinite ? abs($0) : 0 }.max() ?? 0)
    guard rms > 1e-8, peak > 0 else { return source.map { _ in 0 } }
    let gain = Float(min(24, min(0.24 / rms, 0.94 / peak)))
    return source.map { $0.isFinite ? $0 * gain : 0 }
  }

  /// Musical targets are independent of source time. A single phrase can move
  /// through several notes without restarting a syllable or its video.
  struct PitchStep: Codable, Equatable {
    let offsetSamples: Int
    let midiNote: Double
  }

  static func validSteps(_ steps: [PitchStep], count: Int) -> Bool {
    guard steps.count <= 64 else { return false }
    var previous = -1
    for step in steps {
      guard step.offsetSamples > previous, step.offsetSamples < count,
        step.midiNote.isFinite, (24...100).contains(step.midiNote)
      else { return false }
      previous = step.offsetSamples
    }
    return steps.isEmpty || steps[0].offsetSamples == 0
  }

  /// Native-rate pitch-synchronous overlap-add. Copy windows of the ORIGINAL
  /// waveform around local pitch marks; never squeeze a cycle into a wavetable.
  /// Voiceless intervals stay dry, preserving consonants, breaths and impacts.
  /// The passage advances at rate=1, with the same loop/reverse clock as video.
  static func render(
    _ input: [Float], count: Int, targetMidiNote: Double?,
    reverse: Bool = false, pitchSteps: [PitchStep] = []
  ) throws -> [Float] {
    guard count > 0, count <= 720_000, !input.isEmpty, input.count <= 720_000,
      input.allSatisfy(\.isFinite), validSteps(pitchSteps, count: count),
      targetMidiNote == nil || (targetMidiNote!.isFinite && (24...100).contains(targetMidiNote!)),
      pitchSteps.isEmpty || targetMidiNote != nil
    else { throw Failure.invalidInput }
    let source = reverse ? Array(input.reversed()) : input
    let dry = repeatSource(source, count: count)
    guard let note = targetMidiNote, source.contains(where: { $0 != 0 }) else { return dry }
    let frames = analyzeVoice(source)
    let marks = pitchMarks(source, frames: frames)
    guard !marks.isEmpty else {
      // No fundamental (whisper/noise/impact) is not a licence to replace the
      // recording with a synthetic vowel. Keep its attack and spectral texture.
      return resonate(dry, note: note, steps: pitchSteps)
    }
    var sum = [Float](repeating: 0, count: count)
    var weights = [Float](repeating: 0, count: count)
    var cursor = 0.0
    var markIndex = 0
    var lastPosition = -1
    while cursor < Double(count) {
      let position = Int(cursor) % source.count
      if position < lastPosition { markIndex = 0 }
      lastPosition = position
      while markIndex + 1 < marks.count &&
        abs(marks[markIndex + 1].sample - position) < abs(marks[markIndex].sample - position) {
        markIndex += 1
      }
      let mark = marks[markIndex]
      let hz = 440 * pow(2, (targetNote(at: cursor, base: note, steps: pitchSteps) - 69) / 12)
      let targetPeriod = Double(sampleRate) / hz
      if abs(mark.sample - position) <= Int(mark.period * 1.5),
        voice(at: position, frames: frames).amount > 0 {
        // Extreme transpositions can cancel a narrow-band grain almost
        // completely. Spend part of that shift on native waveform resampling,
        // rather than silently outputting zero or injecting a synthetic tone.
        // In the normal voice range (+/- roughly an octave), rate remains 1.
        let ratio = mark.period / targetPeriod
        let readRate = ratio > 2 ? ratio / 1.8 : ratio < 0.5 ? ratio / 0.55 : 1
        let radius = max(mark.period / readRate, targetPeriod * 0.55)
        let from = max(0, Int(ceil(cursor - radius)))
        let to = min(count - 1, Int(floor(cursor + radius)))
        if from <= to {
          for outputIndex in from...to {
            let delta = Double(outputIndex) - cursor
            let inputPosition = Double(mark.sample) + delta * readRate
            guard inputPosition >= 0, inputPosition < Double(source.count - 1) else { continue }
            let weight = Float(0.5 + 0.5 * cos(Double.pi * delta / radius))
            let i = Int(inputPosition), blend = Float(inputPosition - Double(i))
            // Normally unit slope: preserve the vowel's formant positions.
            let sample = source[i] * (1 - blend) + source[i + 1] * blend
            sum[outputIndex] += sample * weight
            weights[outputIndex] += weight
          }
        }
      }
      cursor += targetPeriod
    }
    var output = dry
    for i in output.indices {
      let position = i % source.count
      let amount = Float(voice(at: position, frames: frames).amount)
      // Blend only at voiced/unvoiced boundaries, not a permanent doubled
      // dry+pitched voice (which would reintroduce the out-of-tune fundamental).
      let edge = Float(min(1.0, min(Double(position), Double(source.count - 1 - position)) / 240))
      let wet = amount * edge
      if weights[i] > 0.05, wet > 0 {
        output[i] = dry[i] * (1 - wet) + sum[i] / weights[i] * wet
      }
    }
    return output
  }

  private static let voiceHop = 480 // 10 ms analysis; musical notes are slower.
  private struct VoiceFrame {
    let pitch: Pitch?
    let amount: Double
  }
  private struct Mark {
    let sample: Int
    let period: Double
  }

  private static func analyzeVoice(_ source: [Float]) -> [VoiceFrame] {
    let window = min(3072, source.count)
    var frames = [VoiceFrame]()
    for center in stride(from: 0, through: source.count, by: voiceHop) {
      let start = max(0, min(source.count - window, center - window / 2))
      let pitch = estimate(source, start: start, count: window)
      var amount = 0.0
      if let pitch, pitch.confidence >= 0.86 {
        // A broad analysis window can see a neighboring vowel through a /s/.
        // Require periodicity AT this time before touching the consonant.
        let lag = Int((Double(sampleRate) / pitch.hertz).rounded())
        let lo = max(0, center - 480)
        let hi = min(source.count - lag, center + 480)
        var xy = 0.0, xx = 0.0, yy = 0.0
        if hi > lo {
          for i in lo..<hi {
            let a = Double(source[i]), b = Double(source[i + lag])
            xy += a * b; xx += a * a; yy += b * b
          }
          let correlation = xy / max(1e-12, sqrt(xx * yy))
          amount = max(0, min(1, (correlation - 0.65) / 0.25))
        }
      }
      frames.append(VoiceFrame(pitch: amount > 0 ? pitch : nil, amount: amount))
    }
    return frames
  }

  private static func voice(at sample: Int, frames: [VoiceFrame]) -> VoiceFrame {
    let a = min(max(0, sample / voiceHop), frames.count - 1)
    let b = min(a + 1, frames.count - 1)
    let blend = Double(sample % voiceHop) / Double(voiceHop)
    let amount = frames[a].amount * (1 - blend) + frames[b].amount * blend
    let pitch = frames[a].pitch ?? frames[b].pitch
    return VoiceFrame(pitch: pitch, amount: amount)
  }

  private static func pitchMarks(_ source: [Float], frames: [VoiceFrame]) -> [Mark] {
    var marks = [Mark]()
    var position = 0
    var previous: Int?
    while position < source.count {
      let local = voice(at: position, frames: frames)
      guard local.amount > 0.5, let pitch = local.pitch else {
        position += voiceHop / 2
        previous = nil
        continue
      }
      let period = Double(sampleRate) / pitch.hertz
      let predicted = previous.map { $0 + Int(period.rounded()) } ?? position
      let tolerance = Int(period * (previous == nil ? 0.5 : 0.2))
      let lo = max((previous ?? -1) + 1, max(0, predicted - tolerance))
      let hi = min(source.count - 1, predicted + tolerance)
      guard lo <= hi else { break }
      var best = lo
      for i in lo...hi where source[i] > source[best] { best = i }
      marks.append(Mark(sample: best, period: period))
      previous = best
      position = best + max(1, Int(period))
    }
    return marks
  }

  private static func targetNote(at sample: Double, base: Double, steps: [PitchStep]) -> Double {
    var current = base
    for step in steps {
      if Double(step.offsetSamples) > sample { break }
      if step.offsetSamples > 0, sample < Double(step.offsetSamples + 720) {
        let t = (sample - Double(step.offsetSamples)) / 720 // 15 ms portamento.
        let smooth = t * t * (3 - 2 * t)
        return current + (step.midiNote - current) * smooth
      }
      current = step.midiNote
    }
    return current
  }

  private static func repeatSource(_ source: [Float], count: Int) -> [Float] {
    if count <= source.count { return Array(source.prefix(count)) }
    var result = (0..<count).map { source[$0 % source.count] }
    let fade = min(240, source.count / 8)
    if fade > 0 {
      for i in source.count..<count where i % source.count < fade {
        let phase = i % source.count, t = Float(phase + 1) / Float(fade)
        result[i] = source[source.count - fade + phase] * (1 - t) + source[phase] * t
      }
    }
    return result
  }

  private static func resonate(_ dry: [Float], note: Double, steps: [PitchStep]) -> [Float] {
    var resonant = [Float](repeating: 0, count: dry.count)
    var output = dry
    for i in dry.indices {
      let hz = 440 * pow(2, (targetNote(at: Double(i), base: note, steps: steps) - 69) / 12)
      let delay = max(1, Int((Double(sampleRate) / hz).rounded()))
      resonant[i] = dry[i] * 0.4 + (i >= delay ? resonant[i - delay] * 0.6 : 0)
      // 85% untouched source. Resonance cannot introduce sound during a silent
      // consonant gap/tail: gate it by the local dry signal's envelope.
      output[i] = dry[i] == 0 ? 0 : dry[i] * 0.85 + resonant[i] * 0.15
    }
    return output
  }
}
