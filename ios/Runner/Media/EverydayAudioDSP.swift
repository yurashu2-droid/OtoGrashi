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
  static func estimate(_ samples: [Float], start: Int = 0, count: Int? = nil,
                       maximumHertz: Double = 2000, threshold: Double = 0.18,
                       minimumConfidence: Double = 0.82,
                       allowBestFallback: Bool = false) -> Pitch? {
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
    var bestLag = 2
    while lag <= maxLag {
      if cmnd[lag] < cmnd[bestLag] { bestLag = lag }
      if cmnd[lag] < threshold {
        while lag < maxLag && cmnd[lag + 1] < cmnd[lag] { lag += 1 }
        guard cmnd[lag + 1] >= cmnd[lag] else { return nil }
        let left = cmnd[lag - 1], mid = cmnd[lag], right = cmnd[lag + 1]
        let denominator = left - 2 * mid + right
        let correction = abs(denominator) > 1e-12
          ? max(-0.5, min(0.5, 0.5 * (left - right) / denominator)) : 0
        let hz = rate / (Double(lag) + correction)
        guard hz >= 55, hz <= maximumHertz else { return nil }
        let confidence = max(0, min(1, 1 - mid))
        return confidence >= minimumConfidence ? Pitch(hertz: hz, confidence: confidence) : nil
      }
      lag += 1
    }
    // The lab accepts the clearest trough even when it misses the early
    // threshold, provided that its periodicity is still strong enough.
    guard allowBestFallback, 1 - cmnd[bestLag] >= minimumConfidence else { return nil }
    let hz = rate / Double(bestLag)
    guard hz >= 55, hz <= maximumHertz else { return nil }
    return Pitch(hertz: hz, confidence: 1 - cmnd[bestLag])
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

  typealias PitchStep = NoteStep

  /// The exact looped/reversed recording and its pitch analysis for one output window.
  /// Callers may reuse it only when the source window, count and reverse flag match.
  struct PreparedSource {
    fileprivate let dry: [Float]
    fileprivate let frames: [Frame]
    var storageSampleCost: Int { dry.count + frames.count * 6 }
  }

  static func prepare(_ input: [Float], count: Int, reverse: Bool = false,
                      cancellationCheck: (() throws -> Void)? = nil) throws -> PreparedSource {
    guard count > 0, count <= 1_440_000, !input.isEmpty, input.count <= 720_000,
      input.allSatisfy(\.isFinite) else { throw Failure.invalidInput }
    try cancellationCheck?()
    let source = reverse ? Array(input.reversed()) : input
    let dry = looped(source, count: count)
    return PreparedSource(dry: dry, frames: try track(dry, cancellationCheck: cancellationCheck))
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
    pitchSteps: [NoteStep] = [], hardTune: Bool = false,
    prepared: PreparedSource? = nil, cancellationCheck: (() throws -> Void)? = nil
  ) throws -> [Float] {
    guard count > 0, count <= 1_440_000, !input.isEmpty, input.count <= 720_000,
      input.allSatisfy(\.isFinite), validSteps(pitchSteps, count: count),
      targetMidiNote == nil || (targetMidiNote!.isFinite && (24...100).contains(targetMidiNote!))
    else { throw Failure.invalidInput }
    try cancellationCheck?()
    guard targetMidiNote != nil || !pitchSteps.isEmpty else {
      let source = reverse ? Array(input.reversed()) : input
      return looped(source, count: count)
    }
    let source = try prepared ?? prepare(input, count: count, reverse: reverse,
                                         cancellationCheck: cancellationCheck)
    guard source.dry.count == count, !source.frames.isEmpty else { throw Failure.invalidInput }
    let dry = source.dry
    let steps = pitchSteps.isEmpty
      ? [NoteStep(offsetSamples: 0, durationSamples: count, midiNote: targetMidiNote!)]
      : pitchSteps
    let frames = source.frames
    // Entirely a scrape/tap/wind: retain its evolving texture with a modest
    // source-excited comb resonance. Never replace it with a sine oscillator.
    guard frames.contains(where: { $0.pitch != nil }) else {
      return resonantTexture(dry, steps: steps)
    }
    var output = [Float](repeating: 0, count: count)
    var norm = [Float](repeating: 0, count: count)
    var position = 0.0
    var mark: Double?
    var stepIndex = 0
    while position < Double(count) {
      try cancellationCheck?()
      let t = Int(position)
      while stepIndex + 1 < steps.count && steps[stepIndex + 1].offsetSamples <= t {
        stepIndex += 1
      }
      let note = noteAt(t, steps: steps, index: stepIndex, transition: hardTune ? 48 : 384)
      let targetPeriod = Double(sampleRate) / (440 * pow(2, (note - 69) / 12))
      if let pitch = frames[min(frames.count - 1, t / trackingHop)].pitch {
        let sourcePeriod = Double(sampleRate) / pitch.hertz
        mark = crest(dry, prediction: mark, sourcePosition: position, period: sourcePeriod)
        let half = min(1200, max(24, Int(min(sourcePeriod, targetPeriod).rounded())))
        layGrain(dry, centre: mark!, at: position, half: half,
                 removeDC: true, output: &output, norm: &norm)
        position += targetPeriod
      } else {
        mark = nil
        layGrain(dry, centre: position, at: position, half: 240,
                 output: &output, norm: &norm)
        position += 240
      }
    }
    for i in output.indices {
      output[i] = norm[i] > 0 ? output[i] / max(0.35, norm[i]) : dry[i]
    }
    return gated(output, steps: steps)
  }

  /// Pitch-synchronous overlap-add that also reads the source at `stretch`
  /// (below 1 holds a vowel longer, above 1 says it faster) while every grain
  /// lands on the note. With `refMidi` the syllable keeps a fifth of its own
  /// rise and fall around the note, so speech still sounds like speech.
  /// Consonants and breath are read at the same pace, untouched.
  static func renderStretched(_ source: [Float], count: Int, targetMidiNote: Double, stretch: Double,
                              refMidi: Double?, cancellationCheck: (() throws -> Void)? = nil) throws -> [Float] {
    guard count > 0, count <= 1_440_000, !source.isEmpty, source.count <= 720_000,
      source.allSatisfy(\.isFinite), stretch.isFinite, (0.05...2).contains(stretch),
      targetMidiNote.isFinite, (24...100).contains(targetMidiNote)
    else { throw Failure.invalidInput }
    let frames = try track(source, cancellationCheck: cancellationCheck)
    guard frames.contains(where: { $0.pitch != nil }) else {
      return timeStretchedDry(source, count: count, stretch: stretch)
    }
    var output = [Float](repeating: 0, count: count)
    var norm = [Float](repeating: 0, count: count)
    var position = 0.0
    var mark: Double?
    while position < Double(count) {
      try cancellationCheck?()
      let centre = position * stretch
      let frame = min(frames.count - 1, max(0, Int(centre) / trackingHop))
      if let pitch = frames[frame].pitch, centre < Double(source.count) {
        let sourcePeriod = Double(sampleRate) / pitch.hertz
        var note = targetMidiNote
        if let refMidi {
          // The written intervals remain intact; retain one fifth of the
          // source syllable's own inflection around its reference pitch.
          note += 0.2 * max(-12, min(12, pitch.midiNote - refMidi))
        }
        let targetPeriod = Double(sampleRate) / (440 * pow(2, (note - 69) / 12))
        let pulse = crest(source, prediction: mark, sourcePosition: centre,
                          period: sourcePeriod)
        mark = pulse
        // The lab uses the entire source period. For strong upward shifts,
        // that support cancels a pure tone; retain the existing shorter grain.
        let half = min(1200, max(24, Int(min(sourcePeriod, targetPeriod).rounded())))
        layGrain(source, centre: pulse, at: position, half: half,
                 removeDC: true, output: &output, norm: &norm)
        position += targetPeriod
      } else {
        mark = nil
        layGrain(source, centre: centre, at: position, half: 240,
                 output: &output, norm: &norm)
        position += 240
      }
    }
    for i in output.indices { output[i] /= max(0.35, norm[i]) }
    return output
  }

  private static func crest(_ source: [Float], prediction: Double?,
                            sourcePosition: Double, period: Double) -> Double {
    var pulse = prediction ?? sourcePosition
    let reacquire = prediction == nil || abs(pulse - sourcePosition) > period
    if reacquire { pulse = sourcePosition }
    while pulse < sourcePosition - period / 2 { pulse += period }
    // A continuous fractional peak avoids the 10 ms pitch-frame jitter.
    // A lower target can advance by more than a source period. After that
    // jump the phase is unknown: search a full cycle to find a real crest,
    // rather than treating the edge of a quarter-cycle search as a peak.
    let radius = period * (reacquire ? 0.5 : 0.25)
    let lo = max(0, Int((pulse - radius).rounded(.down)))
    let hi = min(source.count - 1, Int((pulse + radius).rounded(.down)))
    guard hi > lo else { return pulse }
    var peak = lo
    for i in (lo + 1)...hi where source[i] > source[peak] { peak = i }
    guard peak > 0 && peak + 1 < source.count else { return Double(peak) }
    let a = Double(source[peak - 1]), b = Double(source[peak]), c = Double(source[peak + 1])
    let denominator = a - 2 * b + c
    return Double(peak) + (abs(denominator) > 1e-9
      ? max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) : 0)
  }

  private static func layGrain(_ source: [Float], centre: Double, at: Double, half: Int,
                               removeDC: Bool = false, output: inout [Float], norm: inout [Float]) {
    guard half >= 8 else { return }
    // A short crest-centred grain can contain mostly the positive half of a
    // high upward shift. Remove its local DC so it cannot become a pulsing
    // offset; leave unvoiced grains untouched for consonant identity.
    let grainLo = max(0, Int(ceil(centre - Double(half))))
    let grainHi = min(source.count, Int(floor(centre + Double(half))) + 1)
    let mean: Float = removeDC && grainHi > grainLo
      ? source[grainLo..<grainHi].reduce(0, +) / Float(grainHi - grainLo) : 0
    let base = Int(floor(at))
    let fraction = at - Double(base)
    for k in -half..<half {
      let i = base + k
      guard i >= 0, i < output.count else { continue }
      let sourcePosition = centre + Double(k) - fraction
      guard sourcePosition >= 0, sourcePosition <= Double(source.count - 1) else { continue }
      let weight = Float(0.5 + 0.5 * cos(Double.pi * Double(k) / Double(half)))
      output[i] += (read(source, at: sourcePosition) - mean) * weight
      norm[i] += weight
    }
  }

  /// Overlap speech grains at a new pace while matching each grain to the
  /// preceding waveform. This supplies the unvoiced/undetected portions of
  /// renderStretched without changing their pitch by resampling them.
  private static func timeStretchedDry(_ source: [Float], count: Int, stretch: Double) -> [Float] {
    if stretch == 1 {
      return (0..<count).map { $0 < source.count ? source[$0] : 0 }
    }
    let half = 480, hop = 480 // 20 ms Hann grains, placed every 10 ms.
    var output = [Float](repeating: 0, count: count)
    var weights = [Float](repeating: 0, count: count)
    for centre in stride(from: 0, to: count + half, by: hop) {
      let expected = Int((Double(centre) * stretch).rounded())
      var selected = expected
      if centre > 0 {
        var best = -Double.infinity
        for candidate in stride(from: max(0, expected - 240),
                                through: min(source.count - 1, expected + 240), by: 8) {
          var ab = 0.0, aa = 0.0, bb = 0.0
          for offset in stride(from: -half, to: half, by: 8) {
            let i = centre + offset, s = candidate + offset
            guard i >= 0, i < count, s >= 0, s < source.count, weights[i] > 0.2 else { continue }
            let a = Double(output[i] / weights[i]), b = Double(source[s])
            ab += a * b; aa += a * a; bb += b * b
          }
          if aa > 1e-8, bb > 1e-8 {
            let score = ab / sqrt(aa * bb)
            if score > best { best = score; selected = candidate }
          }
        }
      }
      for offset in -half..<half {
        let i = centre + offset, s = selected + offset
        guard i >= 0, i < count, s >= 0, s < source.count else { continue }
        let weight = Float(0.5 + 0.5 * cos(Double.pi * Double(offset) / Double(half)))
        output[i] += source[s] * weight
        weights[i] += weight
      }
    }
    for i in output.indices where weights[i] > 0.000_1 { output[i] /= weights[i] }
    return output
  }

  private static let trackingHop = 480 // Lab analysis advances every 10 ms.
  fileprivate struct Frame {
    let pitch: Pitch?
  }

  private static func track(_ source: [Float], cancellationCheck: (() throws -> Void)? = nil) throws -> [Frame] {
    var candidates: [Pitch?] = []
    var levels: [Double] = []
    for offset in stride(from: 0, to: source.count, by: trackingHop) {
      try cancellationCheck?()
      let n = min(1920, source.count)
      let start = max(0, min(source.count - n, offset))
      let level = sqrt(source[start..<(start + n)].reduce(0.0) {
        $0 + Double($1) * Double($1)
      } / Double(n))
      levels.append(level)
      candidates.append(estimate(source, start: start, count: n,
                                 maximumHertz: 4000, threshold: 0.2,
                                 minimumConfidence: 0.6, allowBestFallback: true))
    }
    let floor = (levels.max() ?? 0) * 0.12
    let voiced = candidates.indices.map { candidates[$0] != nil && levels[$0] > floor }
    return candidates.indices.map { index in
      guard voiced[index], let pitch = candidates[index] else { return Frame(pitch: nil) }
      let near = max(0, index - 2)...min(candidates.count - 1, index + 2)
      let notes = near.compactMap { voiced[$0] ? candidates[$0]?.midiNote : nil }.sorted()
      let midi = notes[notes.count / 2]
      let hertz = 440 * pow(2, (midi - 69) / 12)
      return Frame(pitch: Pitch(hertz: hertz, confidence: pitch.confidence))
    }
  }

  private static func noteAt(_ offset: Int, steps: [NoteStep], index: Int, transition: Int = 384) -> Double {
    let current = steps[index]
    guard index > 0 else { return current.midiNote }
    let previous = steps[index - 1]
    let gap = current.offsetSamples - (previous.offsetSamples + previous.durationSamples)
    // Eight milliseconds, not an audible beat-long glide. Natural syllables
    // continue through small articulation gaps in the source score.
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
