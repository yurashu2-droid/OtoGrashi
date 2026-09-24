import Foundation

/// Regression for a moving vowel: a confidence-weighted dry/wet blend can keep
/// the original, off-key F0 audible even when the source is clearly voiced.
@main struct DynamicVoiceRegression {
  static func main() throws {
    var phase = 0.0
    let source = (0..<48000).map { i -> Float in
      let t = Double(i) / 48000
      let hz = 130 + 80 * pow(sin(.pi * 2 * t), 2)
      phase += 2 * .pi * hz / 48000
      var value = 0.0
      for harmonic in 1...24 {
        let f = Double(harmonic) * hz
        let amplitude = (0.2 + 5 * exp(-pow((f - 700) / 180, 2) / 2)
          + 3 * exp(-pow((f - 1700) / 240, 2) / 2)) / Double(harmonic)
        value += amplitude * sin(Double(harmonic) * phase)
      }
      return Float(value * 0.07)
    }
    let output = try EverydayAudioDSP.render(source, count: source.count, targetMidiNote: 57)
    let notes = stride(from: 4800, to: source.count - 4800, by: 2400).map {
      EverydayAudioDSP.estimate(output, start: $0, count: 2048)?.midiNote
    }
    let matched = notes.filter { $0.map { abs($0 - 57) < 0.5 } ?? false }.count
    print("Moving vowel follows target: \(matched)/\(notes.count)")
    guard matched >= notes.count * 9 / 10 else { exit(1) }
  }
}
