import Foundation

@main struct NaturalVoiceRegression {
  static var failures = 0
  static func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
  }
  static func tone(_ hz: Double, _ count: Int) -> [Float] {
    (0..<count).map { Float(0.25 * sin(2 * Double.pi * hz * Double($0) / 48000)) }
  }
  static func correlation(_ a: [Float], _ b: [Float]) -> Double {
    let ab = zip(a,b).reduce(0.0) { $0 + Double($1.0 * $1.1) }
    let aa = a.reduce(0.0) { $0 + Double($1 * $1) }
    let bb = b.reduce(0.0) { $0 + Double($1 * $1) }
    return ab / max(1e-12, sqrt(aa * bb))
  }
  static func main() throws {
    var state: UInt32 = 913
    let noise: [Float] = (0..<48000).map { _ in
      state = state &* 1664525 &+ 1013904223
      return Float(Double(state) / Double(UInt32.max) - 0.5) * 0.3
    }
    let breath = try EverydayAudioDSP.render(noise, count: noise.count, targetMidiNote: 60)
    let similarity = correlation(noise, breath)
    check(similarity > 0.8, "unpitched texture retains waveform, correlation=\(similarity)")
    let syllables = tone(180, 14400) + Array(repeating: Float(0), count: 9600) +
      Array(noise[0..<9600]) + tone(220, 14400)
    let voice = try EverydayAudioDSP.render(syllables, count: syllables.count, targetMidiNote: 60)
    check(voice[16500..<22000].allSatisfy { abs($0) < 0.00001 }, "internal speech pause stays silent")
    let consonant = correlation(Array(syllables[27000..<31000]), Array(voice[27000..<31000]))
    check(consonant > 0.9, "consonant stays recognizable, correlation=\(consonant)")
    for hz in [140.0, 220, 440] {
      let target = 69 + 12 * log2(hz / 440) + 3
      let output = try EverydayAudioDSP.render(tone(hz,48000), count:48000, targetMidiNote:target)
      let actual = EverydayAudioDSP.estimate(output, start:18000)?.midiNote ?? -1000
      check(abs(actual-target) < 0.25, "voiced source \(hz)Hz reaches +3 semitones: \(actual-target)")
      check(output.allSatisfy(\.isFinite), "finite voiced output")
    }
    let changing = tone(220,24000) + tone(330,24000)
    let register = EverydayAudioDSP.registerNote(changing)
    check(EverydayAudioDSP.stableNote(changing) == nil && register != nil && (57...65).contains(register!),
      "changing speech gets a register, not a false stable fundamental")
    let steps: [EverydayAudioDSP.NoteStep] = [
      .init(offsetSamples: 0, durationSamples: 24000, midiNote: 57),
      .init(offsetSamples: 24000, durationSamples: 24000, midiNote: 60),
    ]
    let flow = try EverydayAudioDSP.render(tone(220, 48000), count: 48000, targetMidiNote: 57, pitchSteps: steps)
    for (start, target) in [(12000, 57.0), (36000, 60.0)] {
      let actual = EverydayAudioDSP.estimate(flow, start: start)?.midiNote ?? -1000
      check(abs(actual-target) < 0.2, "continuous note at \(start): \(actual)")
    }
    check(abs(flow[24000] - flow[23999]) < 0.1, "no click at note boundary")
    let window = flow[23950..<24050]
    check(window.reduce(0) { $0 + abs($1) } / Float(window.count) > 0.03, "no per-note fade-to-zero reset")
    check(!EverydayAudioDSP.validSteps([
      .init(offsetSamples: 0, durationSamples: 24000, midiNote: 57),
      .init(offsetSamples: 100, durationSamples: 24000, midiNote: 60),
    ], count: 48000), "reject overlapping automation")
    check(!EverydayAudioDSP.validSteps([
      .init(offsetSamples: Int.max, durationSamples: 1, midiNote: 57),
    ], count: 48000), "reject huge offset without integer overflow")
    check(!EverydayAudioDSP.validSteps([
      .init(offsetSamples: 0, durationSamples: Int.max, midiNote: 57),
    ], count: 48000), "reject huge duration without integer overflow")
    let rested = try EverydayAudioDSP.render(tone(220,48000), count:48000, targetMidiNote:57,
      pitchSteps: [.init(offsetSamples:0,durationSamples:12000,midiNote:57),
        .init(offsetSamples:24000,durationSamples:24000,midiNote:60)])
    check(rested[12500..<23500].allSatisfy { $0 == 0 }, "real musical rests stay silent")
    print("Failures: \(failures)")
    if failures != 0 { exit(1) }
  }
}
