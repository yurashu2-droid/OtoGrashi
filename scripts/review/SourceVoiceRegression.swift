import Foundation
@main struct SourceVoiceRegression {
  static var failures = 0
  static func check(_ value: Bool, _ label: String) {
    print("\(value ? "PASS" : "FAIL") \(label)")
    if !value { failures += 1 }
  }
  static func correlation(_ x: [Float], _ y: [Float]) -> Double {
    let xy = zip(x,y).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    let xx = x.reduce(0.0) { $0 + Double($1) * Double($1) }
    let yy = y.reduce(0.0) { $0 + Double($1) * Double($1) }
    return xy / max(1e-15, sqrt(xx * yy))
  }
  static func vowel(_ hz: Double, count: Int, formant: Double = 900) -> [Float] {
    var result = [Float](repeating: 0, count: count)
    for h in 1...32 {
      let f = hz * Double(h)
      let amplitude = 0.09 * exp(-0.5 * pow((f - formant) / 180, 2)) + 0.02 / Double(h)
      for i in result.indices {
        result[i] += Float(amplitude * cos(2 * Double.pi * f * Double(i) / 48000))
      }
    }
    return result
  }
  static func bandEnergy(_ x: [Float], hz: Double) -> Double {
    var re = 0.0, im = 0.0
    for i in x.indices {
      let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(x.count))
      let phase = 2 * Double.pi * hz * Double(i) / 48000
      re += Double(x[i]) * w * cos(phase); im += Double(x[i]) * w * sin(phase)
    }
    return re * re + im * im
  }
  static func main() throws {
    var state: UInt32 = 75
    let noise = (0..<9600).map { _ -> Float in
      state = state &* 1664525 &+ 1013904223
      return Float(Double(state) / Double(UInt32.max) - 0.5) * 0.35
    }
    let speech = noise + vowel(160, count: 28800) + noise
    let changed = try EverydayAudioDSP.render(speech, count: speech.count, targetMidiNote: 60)
    let consonant = correlation(Array(speech[0..<7000]), Array(changed[0..<7000]))
    check(consonant > 0.98, "unvoiced consonant correlation > .98: \(consonant)")
    let input = vowel(160, count: 48000)
    let targetHz = 220.0
    let shifted = try EverydayAudioDSP.render(input, count: input.count, targetMidiNote: 57)
    let body = Array(shifted[12000..<36000])
    let aroundOriginalFormant = bandEnergy(body, hz: 4 * targetHz)
    let shiftedFormant = bandEnergy(body, hz: 6 * targetHz)
    check(aroundOriginalFormant > shiftedFormant * 2,
      "vowel resonance stays near 900Hz, not transposed to 1240Hz: ratio \(aroundOriginalFormant / max(1e-15, shiftedFormant))")
    let pitch = EverydayAudioDSP.estimate(body)?.midiNote ?? 0
    check(abs(pitch - 57) < 0.25, "voiced output follows note: \(pitch)")
    check(changed.count == speech.count && changed.allSatisfy(\.isFinite), "duration / finite")
    let curve: [EverydayAudioDSP.PitchStep] = [
      .init(offsetSamples: 0, midiNote: 53),
      .init(offsetSamples: 22500, midiNote: 57),
      .init(offsetSamples: 45000, midiNote: 60),
      .init(offsetSamples: 67500, midiNote: 55),
    ]
    let passage = vowel(160, count: 90000)
    let sung = try EverydayAudioDSP.render(passage, count: passage.count,
      targetMidiNote: 53, pitchSteps: curve)
    for step in curve {
      let lo = step.offsetSamples + 6000, hi = step.offsetSamples + 14000
      let window = Array(sung[lo..<hi])
      let actual = EverydayAudioDSP.estimate(window)?.midiNote ?? -100
      check(abs(actual - step.midiNote) < 0.25, "continuous curve target \(step.midiNote): \(actual)")
      check((window.map(\.magnitude).max() ?? 0) > 0.02, "no vanished vowel at \(step.offsetSamples)")
    }
    let evolving = vowel(160, count: 24000, formant: 900) + vowel(160, count: 24000, formant: 1800)
    let evolved = try EverydayAudioDSP.render(evolving, count: 48000, targetMidiNote: 57)
    let first = Array(evolved[8000..<20000]), second = Array(evolved[32000..<44000])
    check(bandEnergy(first, hz: 880) > bandEnergy(first, hz: 1760) * 3,
      "first vowel keeps its original spectral identity")
    check(bandEnergy(second, hz: 1760) > bandEnergy(second, hz: 880) * 3,
      "second vowel advances in time instead of freezing the first")
    let natural = try EverydayAudioDSP.render(speech, count: speech.count, targetMidiNote: nil)
    check(natural == speech, "dry phrase bit-identical")
    let reverse = try EverydayAudioDSP.render(speech, count: speech.count, targetMidiNote: nil, reverse: true)
    check(reverse == Array(speech.reversed()), "dry reverse preserves exact clock")
    for length in [1, 240, 1000] {
      let short = Array(noise.prefix(length))
      let rendered = try EverydayAudioDSP.render(short, count: 24000, targetMidiNote: 57)
      check(rendered.count == 24000 && rendered.allSatisfy(\.isFinite), "very short source \(length) stays bounded")
    }
    for points: [EverydayAudioDSP.PitchStep] in [
      [.init(offsetSamples: 1, midiNote: 57)],
      [.init(offsetSamples: 0, midiNote: .nan)],
      [.init(offsetSamples: 0, midiNote: 57), .init(offsetSamples: 0, midiNote: 60)],
      [.init(offsetSamples: 0, midiNote: 57), .init(offsetSamples: 90000, midiNote: 60)],
    ] {
      do {
        _ = try EverydayAudioDSP.render(passage, count: 90000, targetMidiNote: 57, pitchSteps: points)
        check(false, "reject malformed curve")
      } catch { check(true, "reject malformed curve") }
    }
    print("Failures: \(failures)")
    if failures > 0 { exit(1) }
  }
}
