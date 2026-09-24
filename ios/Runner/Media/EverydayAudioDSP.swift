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
      if cmnd[lag] < 0.18 {
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

  /// Advisory voice register even for changing speech. Not a single stable
  /// fundamental and NEVER used as the actual source pitch by the renderer.
  static func registerNote(_ samples: [Float]) -> Double? {
    guard samples.count >= 1024 else { return nil }
    let window = min(4096, samples.count)
    var notes: [Double] = []
    for offset in stride(from: 0, to: samples.count, by: 3840) {
      let start = max(0, min(samples.count - window, offset - window / 2))
      if let pitch = estimate(samples, start: start, count: window), pitch.confidence >= 0.82 {
        notes.append(pitch.midiNote)
      }
    }
    guard !notes.isEmpty else { return nil }
    return notes.sorted()[notes.count / 2]
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

  /// A melody is automation over a continuing recording, not a new oscillator
  /// or a restart of the first syllable for every note. Offsets use the same
  /// 48 kHz clock as the source video. Empty automation preserves old payloads.
  struct NoteStep: Codable, Equatable {
    let offsetSamples: Int
    let durationSamples: Int
    let midiNote: Double
  }

  static func validSteps(_ steps: [NoteStep], count: Int) -> Bool {
    guard steps.count <= 128 else { return false }
    var end = 0
    for step in steps {
      guard step.offsetSamples >= end, step.offsetSamples < count,
        step.durationSamples > 0, step.durationSamples <= count - step.offsetSamples,
        step.midiNote.isFinite, (24...100).contains(step.midiNote)
      else { return false }
      end = step.offsetSamples + step.durationSamples
    }
    return true
  }

  /// Pitch-synchronous overlap-add of ORIGINAL, unresampled waveform grains.
  /// Unlike the old 128-sample cycle tables, this retains the spectral envelope
  /// and advances through consonants, vowels, breaths and changes in timbre.
  /// Unvoiced speech is copied, not coerced into an artificial voiced vowel.
  /// This is intended for monophonic voices/incidental sounds, not polyphonic
  /// source separation. Large transpositions still sound deliberately edited.
  static func render(
    _ input: [Float], count: Int, targetMidiNote: Double?, reverse: Bool = false,
    pitchSteps: [NoteStep] = []
  ) throws -> [Float] {
    guard count > 0, count <= 720_000, !input.isEmpty, input.count <= 720_000,
      input.allSatisfy(\.isFinite), validSteps(pitchSteps, count: count),
      targetMidiNote == nil || (targetMidiNote!.isFinite && (24...100).contains(targetMidiNote!))
    else { throw Failure.invalidInput }
    let source = reverse ? Array(input.reversed()) : input
    let dry = looped(source, count: count)
    guard targetMidiNote != nil || !pitchSteps.isEmpty else { return dry }
    let steps = pitchSteps.isEmpty
      ? [NoteStep(offsetSamples: 0, durationSamples: count, midiNote: targetMidiNote!)]
      : pitchSteps
    let frames = track(dry)
    // Entirely a scrape/tap/wind: retain its evolving texture with a modest
    // source-excited comb resonance. Never replace it with a sine oscillator.
    guard frames.contains(where: { $0.pitch != nil }) else {
      return resonantTexture(dry, steps: steps)
    }
    let marks = pitchMarks(dry, frames: frames)
    guard !marks.isEmpty else { return gated(dry, steps: steps) }
    var wet = [Float](repeating: 0, count: count)
    var weights = [Float](repeating: 0, count: count)
    var nearest = 0
    var position = Double(marks[0])
    var stepIndex = 0
    while position < Double(count) {
      let t = Int(position)
      while stepIndex + 1 < steps.count && steps[stepIndex + 1].offsetSamples <= t {
        stepIndex += 1
      }
      let note = noteAt(t, steps: steps, index: stepIndex)
      let targetPeriod = Double(sampleRate) / (440 * pow(2, (note - 69) / 12))
      while nearest + 1 < marks.count &&
        abs(Double(marks[nearest + 1]) - position) < abs(Double(marks[nearest]) - position) {
        nearest += 1
      }
      let mark = marks[nearest]
      if let pitch = frames[min(frames.count - 1, mark / trackingHop)].pitch,
        abs(Double(mark) - position) < Double(sampleRate) / pitch.hertz * 1.6 {
        let half = min(1200, max(24, Int(min(Double(sampleRate) / pitch.hertz, targetPeriod).rounded())))
        // Limit support at upward shifts, as in pitch-synchronous overlap-add.
        // Subtract the grain DC, not its speech formants. A very high target
        // otherwise repeats only the positive crest of a low source tone.
        let grainLo = max(0, mark - half), grainHi = min(count, mark + half + 1)
        let mean = dry[grainLo..<grainHi].reduce(0, +) / Float(grainHi - grainLo)
        let lo = max(0, Int(ceil(position - Double(half))))
        let hi = min(count - 1, Int(floor(position + Double(half))))
        if lo <= hi {
          for i in lo...hi {
            let offset = Double(i) - position
            let sourcePosition = Double(mark) + offset
            guard sourcePosition >= 0, sourcePosition < Double(count - 1) else { continue }
            let weight = Float(0.5 + 0.5 * cos(Double.pi * offset / Double(half)))
            wet[i] += (read(dry, at: sourcePosition) - mean) * weight
            weights[i] += weight
          }
        }
      }
      // Fractional pulse phase continues across all MIDI boundaries. Only the
      // interval changes; no per-note reset, oscillator or sample-rate change.
      position += targetPeriod
    }
    var output = dry
    var blend: Float = 0
    for i in output.indices {
      let voiced = frames[min(frames.count - 1, i / trackingHop)].pitch != nil
      let desired: Float = voiced && weights[i] > 0.03 ? 1 : 0
      // 5 ms transition. Leave the original attack and unvoiced phonemes intact.
      blend += max(-1 / 240.0, min(1 / 240.0, desired - blend))
      if weights[i] > 0.03 {
        output[i] = dry[i] * (1 - blend) + (wet[i] / weights[i]) * blend
      }
    }
    return gated(output, steps: steps)
  }

  private static let trackingHop = 960 // 20 ms; beat targets change independently.
  private struct Frame {
    let pitch: Pitch?
  }

  private static func track(_ source: [Float]) -> [Frame] {
    var result: [Frame] = []
    for offset in stride(from: 0, to: source.count, by: trackingHop) {
      let center = min(source.count - 1, offset + trackingHop / 2)
      let n = min(4096, source.count)
      let start = max(0, min(source.count - n, center - n / 2))
      var pitch = estimate(source, start: start, count: n)
      if let candidate = pitch {
        // A long pitch window can straddle a vowel and /s/. Verify periodicity
        // locally so the neighboring vowel does not "voice" the consonant.
        let lag = max(1, Int((Double(sampleRate) / candidate.hertz).rounded()))
        let lo = max(0, center - trackingHop / 2)
        let hi = min(source.count - lag, center + trackingHop / 2)
        var ab = 0.0, aa = 0.0, bb = 0.0
        if hi > lo {
          for i in lo..<hi {
            let a = Double(source[i]), b = Double(source[i + lag])
            ab += a * b; aa += a * a; bb += b * b
          }
        }
        if aa < 1e-8 || bb < 1e-8 || ab / max(1e-12, sqrt(aa * bb)) < 0.65 {
          pitch = nil
        }
      }
      result.append(Frame(pitch: pitch))
    }
    return result
  }

  private static func pitchMarks(_ source: [Float], frames: [Frame]) -> [Int] {
    var marks: [Int] = []
    var cursor = 0
    var previous: Int?
    var polarity: Float = 1
    while cursor < source.count {
      let frameIndex = min(frames.count - 1, cursor / trackingHop)
      guard let pitch = frames[frameIndex].pitch else {
        cursor = (frameIndex + 1) * trackingHop
        previous = nil
        continue
      }
      let period = max(24, Int((Double(sampleRate) / pitch.hertz).rounded()))
      let prediction = previous.map { $0 + period } ?? cursor
      let radius = previous == nil ? period : max(2, period / 5)
      let lo = max(cursor, prediction - (previous == nil ? 0 : radius))
      let hi = min(source.count - 1, prediction + radius)
      guard hi >= lo else { break }
      var peak = lo
      for i in lo...hi {
        let value = previous == nil ? abs(source[i]) : source[i] * polarity
        let best = previous == nil ? abs(source[peak]) : source[peak] * polarity
        if value > best { peak = i }
      }
      if previous == nil { polarity = source[peak] < 0 ? -1 : 1 }
      marks.append(peak)
      previous = peak
      cursor = peak + max(1, period / 2)
    }
    return marks
  }

  private static func noteAt(_ offset: Int, steps: [NoteStep], index: Int) -> Double {
    let current = steps[index]
    guard index > 0 else { return current.midiNote }
    let previous = steps[index - 1]
    let gap = current.offsetSamples - (previous.offsetSamples + previous.durationSamples)
    // Eight milliseconds, not an audible beat-long glide. Natural syllables
    // continue through small articulation gaps in the source score.
    let transition = 384
    if gap <= 1920 && offset < current.offsetSamples + transition {
      let f = max(0, min(1, Double(offset - current.offsetSamples) / Double(transition)))
      let smooth = f * f * (3 - 2 * f)
      return previous.midiNote + (current.midiNote - previous.midiNote) * smooth
    }
    return current.midiNote
  }

  private static func gated(_ source: [Float], steps: [NoteStep]) -> [Float] {
    var output = source
    var index = 0
    for i in output.indices {
      while index + 1 < steps.count && steps[index + 1].offsetSamples <= i { index += 1 }
      let step = steps[index]
      let end = step.offsetSamples + step.durationSamples
      // Retain tiny MIDI articulation gaps as legato speech, but never fill
      // real rests. There is no re-attack envelope on every automated note.
      let next = index + 1 < steps.count ? steps[index + 1].offsetSamples : source.count + 1921
      if i < step.offsetSamples || (i >= end && next - end > 1920) {
        output[i] = 0
      } else if next - end > 1920 && i >= end - 240 {
        output[i] *= Float(max(0, end - i)) / 240
      }
    }
    return output
  }

  private static func resonantTexture(_ source: [Float], steps: [NoteStep]) -> [Float] {
    var output = source
    var delay = [Float](repeating: 0, count: source.count)
    var index = 0
    for i in output.indices {
      while index + 1 < steps.count && steps[index + 1].offsetSamples <= i { index += 1 }
      let hz = 440 * pow(2, (noteAt(i, steps: steps, index: index) - 69) / 12)
      let period = Double(sampleRate) / hz
      let echo = Double(i) >= period ? read(delay, at: Double(i) - period) : 0
      delay[i] = source[i] + 0.6 * echo
      // Dry remains dominant; keep the first 12 ms of every sound untouched.
      let wet = Float(min(1, max(0, Double(i - 576) / 480))) * 0.22
      output[i] = source[i] + wet * echo
    }
    return gated(output, steps: steps)
  }

  private static func looped(_ source: [Float], count: Int) -> [Float] {
    if count <= source.count { return Array(source.prefix(count)) }
    var result = (0..<count).map { source[$0 % source.count] }
    // Unchanged period: the source picture still advances at 1x and wraps at
    // exactly source.count. A short edge crossfade avoids a loop click.
    let fade = min(240, source.count / 8)
    if fade > 0 {
      for i in source.count..<count where i % source.count < fade {
        let phase = i % source.count
        let t = Float(phase + 1) / Float(fade)
        result[i] = source[source.count - fade + phase] * (1 - t) + source[phase] * t
      }
    }
    return result
  }

  private static func read(_ source: [Float], at position: Double) -> Float {
    let p = max(0, min(Double(source.count - 1), position))
    let a = Int(p), b = min(source.count - 1, a + 1)
    let t = Float(p - Double(a))
    return source[a] * (1 - t) + source[b] * t
  }
}
