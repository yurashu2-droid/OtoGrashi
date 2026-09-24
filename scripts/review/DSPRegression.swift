import Foundation

@main struct DSPRegression {
  static var failures = 0
  static func check(_ value: Bool, _ label: String) {
    print("\(value ? "PASS" : "FAIL") \(label)")
    if !value { failures += 1 }
  }
  static func tone(_ hz: Double, _ n: Int = 24000) -> [Float] {
    (0..<n).map { Float(0.3 * sin(2 * Double.pi * hz * Double($0) / 48000)) }
  }
  static func main() throws {
    for hz in [60.0, 82.4069, 100, 220, 440, 880, 1046.502, 1174.659, 1760] {
      let p = EverydayAudioDSP.estimate(tone(hz))
      let cents = p.map { 1200 * log2($0.hertz / hz) } ?? 10000
      check(abs(cents) < 8, "YIN \(hz) Hz, error=\(cents) cents")
    }
    check(EverydayAudioDSP.estimate([Float](repeating: 0, count: 4096)) == nil, "silence is not a note")
    var state: UInt32 = 91
    let noise: [Float] = (0..<24000).map { _ in
      state = state &* 1664525 &+ 1013904223
      return Float(Double(state) / Double(UInt32.max) - 0.5) * 0.5
    }
    check(EverydayAudioDSP.estimate(noise) == nil, "noise not falsely measured as a stable fundamental")
    let glide: [Float] = (0..<24000).map { i in
      let time = Double(i) / 48000.0
      let phase = 2.0 * Double.pi * (170.0 * time + 80.0 * time * time)
      return Float(0.3 * sin(phase))
    }
    let fixtures: [(String, [Float])] = [("tone", tone(220)), ("glide", glide), ("noise", noise)]
    for (name, input) in fixtures {
      for target in [48.0, 60, 72, 82] {
        let output = try EverydayAudioDSP.render(input, count: 36000, targetMidiNote: target)
        let p = EverydayAudioDSP.estimate(Array(output[8000..<16000]))
        let actual = p?.midiNote ?? -1000
        check(output.count == 36000 && output.allSatisfy(\.isFinite), "\(name) target \(target): exact length / finite")
        check(abs(actual - target) < 0.2, "\(name) target \(target): measured MIDI \(actual)")
      }
    }
    let original: [Float] = [0.1, 0.2, 0.3, 0.4]
    let reversed = try EverydayAudioDSP.render(original, count: 4, targetMidiNote: nil, reverse: true)
    check(reversed == original.reversed().map { $0 }, "original reverse is exact")
    check(EverydayAudioDSP.sourceOffset(outputOffset: 12, sourceCount: 5, reverse: false) == 2, "audio/video loop mapping")
    check(EverydayAudioDSP.sourceOffset(outputOffset: 12, sourceCount: 5, reverse: true) == 2, "audio/video reverse mapping")
    let quiet = tone(220).map { $0 * 0.01 }
    let normalized = EverydayAudioDSP.matchLevel(quiet)
    check((normalized.map { abs($0) }.max() ?? 0) > 0.06, "quiet source becomes audible")
    let zero = try EverydayAudioDSP.render([Float](repeating: 0, count: 1000), count: 4000, targetMidiNote: 60)
    check(zero.allSatisfy { $0 == 0 }, "no unrelated sound is synthesized from silence")
    print("Failures: \(failures)")
    if failures != 0 { exit(1) }
  }
}
