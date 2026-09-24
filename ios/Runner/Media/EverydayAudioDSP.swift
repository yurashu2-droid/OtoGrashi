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

  /// Phase-coherent granular resynthesis: neighboring atoms are aligned to the
  /// recording's local waveform and crossfaded at a fixed target period. This
  /// follows changing speech, while noisy atoms acquire musical periodicity.
  /// Natural phrases use target=nil and remain entirely unmodified in pitch.
  static func render(
    _ input: [Float], count: Int, targetMidiNote: Double?, reverse: Bool = false
  ) throws -> [Float] {
    guard count > 0, count <= 720_000, !input.isEmpty, input.count <= 720_000,
      input.allSatisfy(\.isFinite),
      targetMidiNote == nil || (targetMidiNote!.isFinite && (24...100).contains(targetMidiNote!))
    else { throw Failure.invalidInput }
    let source = reverse ? Array(input.reversed()) : input
    guard let note = targetMidiNote else {
      if count <= source.count { return Array(source.prefix(count)) }
      var result = (0..<count).map { source[$0 % source.count] }
      // Crossfade without shortening the source period. The picture loops on
      // EXACTLY the same sourceCount, not on sourceCount - crossfade.
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
    let targetHz = 440 * pow(2, (note - 69) / 12)
    let tableSize = 128
    let hop = 960
    let tableCount = max(2, (source.count + hop - 1) / hop + 1)
    var atoms = [[Float]]()
    atoms.reserveCapacity(tableCount)
    var lastPitch: Pitch?
    for frame in 0..<tableCount {
      let center = min(source.count - 1, frame * hop)
      let windowStart = max(0, min(source.count - min(4096, source.count), center - 2048))
      // Reuse a 40 ms pitch estimate for adjacent 20 ms atom frames.
      if frame % 2 == 0 || frame == tableCount - 1 {
        lastPitch = estimate(source, start: windowStart)
      }
      atoms.append(atom(source, center: center, pitch: lastPitch,
                        tableSize: tableSize, targetHz: targetHz))
    }
    var output = [Float](repeating: 0, count: count)
    let phaseStep = targetHz / Double(sampleRate)
    for i in output.indices {
      let position = Double(i % source.count) / Double(hop)
      let a = min(Int(position), atoms.count - 2)
      let blend = Float(position - Double(a))
      let phase = (Double(i) * phaseStep).truncatingRemainder(dividingBy: 1)
      let tablePosition = phase * Double(tableSize)
      let lo = Int(tablePosition) % tableSize
      let hi = (lo + 1) % tableSize
      let fraction = Float(tablePosition - floor(tablePosition))
      let v0 = atoms[a][lo] * (1 - fraction) + atoms[a][hi] * fraction
      let v1 = atoms[a + 1][lo] * (1 - fraction) + atoms[a + 1][hi] * fraction
      output[i] = v0 * (1 - blend) + v1 * blend
    }
    return output
  }

  private static func atom(
    _ source: [Float], center: Int, pitch: Pitch?, tableSize: Int, targetHz: Double
  ) -> [Float] {
    let period = min(Double(max(2, source.count / 2)), pitch.map { Double(sampleRate) / $0.hertz } ?? 256)
    let lo = max(0, min(source.count - 1, center - Int(period / 2)))
    let hi = min(source.count - 1, lo + max(1, Int(period)))
    var peak = lo
    if hi > lo {
      for i in lo...hi where source[i] > source[peak] { peak = i }
    }
    let start = min(Double(peak), max(0, Double(source.count - 1) - period))
    func read(_ position: Double) -> Float {
      let p = max(0, min(Double(source.count - 1), position))
      let a = Int(p), b = min(a + 1, source.count - 1)
      let t = Float(p - Double(a))
      return source[a] * (1 - t) + source[b] * t
    }
    var table = (0..<tableSize).map { read(start + Double($0) * period / Double(tableSize)) }
    let mean = table.reduce(0, +) / Float(tableSize)
    for i in table.indices { table[i] -= mean }
    let energy = sqrt(table.reduce(0) { $0 + $1 * $1 } / Float(tableSize))
    guard energy > 1e-7 else { return table.map { _ in 0 } }

    // Keep the original spectral fingerprint, but strengthen its first harmonic
    // when an unpitched sound has no clear fundamental. Its amplitude comes
    // from the recording; silence remains silence (no separate backing synth).
    var cosine: Float = 0, sine: Float = 0
    for i in table.indices {
      let phase = 2 * Double.pi * Double(i) / Double(tableSize)
      cosine += table[i] * Float(cos(phase)) * 2 / Float(tableSize)
      sine += table[i] * Float(sin(phase)) * 2 / Float(tableSize)
    }
    let fundamental = sqrt(cosine * cosine + sine * sine)
    if pitch == nil {
      // Align the resonant fundamental across noisy atoms: arbitrary phase
      // changes here otherwise destroy low bass notes during crossfades.
      for i in table.indices {
        let phase = 2 * Double.pi * Double(i) / Double(tableSize)
        table[i] += (energy * 1.5 - cosine) * Float(cos(phase)) - sine * Float(sin(phase))
      }
    } else if fundamental < energy * 0.8 {
      let phaseOffset = fundamental > 1e-7 ? atan2(Double(sine), Double(cosine)) : 0
      let addition = energy * 0.8 - fundamental
      for i in table.indices {
        table[i] += addition * Float(cos(2 * Double.pi * Double(i) / Double(tableSize) - phaseOffset))
      }
    }
    // Circular smoothing prevents bright noise grains aliasing excessively at
    // high target notes. It never changes the period or event clock.
    let radius = min(16, max(1, Int(ceil(Double(tableSize) * targetHz / 24_000))))
    if radius > 1 {
      let original = table
      for i in table.indices {
        var value: Float = 0
        for j in -radius...radius {
          value += original[(i + j + tableSize) % tableSize]
        }
        table[i] = value / Float(2 * radius + 1)
      }
    }
    return table
  }
}
