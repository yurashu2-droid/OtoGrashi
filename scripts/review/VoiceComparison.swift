import Foundation

/// Build with the production DSP plus the previous commit's DSP renamed to
/// LegacyEverydayAudioDSP. Input: mono 48kHz little-endian Float32 PCM.
@main struct VoiceComparison {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else { fatalError("input.f32 output-directory") }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let input = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    guard !input.isEmpty, input.count <= 720000 else { fatalError("invalid PCM length") }
    let source = EverydayAudioDSP.matchLevel(input)
    let folder = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let observations = stride(from: 0, to: max(1, source.count - 4096), by: 2400)
      .compactMap { EverydayAudioDSP.estimate(source, start: $0)?.midiNote }.sorted()
    let reference = observations.isEmpty ? 57 : observations[observations.count / 2]
    let root = max(48, min(76, reference.rounded() - 4))
    let motif = [0.0, 2, 4, 7, 4, 2, 0, -2]
    let steps = stride(from: 0, to: source.count, by: 22500).enumerated().map {
      EverydayAudioDSP.PitchStep(offsetSamples: $0.element,
        midiNote: root + motif[$0.offset % motif.count])
    }
    let refined = try EverydayAudioDSP.render(source, count: source.count,
      targetMidiNote: root, pitchSteps: steps)
    var before = [Float]()
    for (index, step) in steps.enumerated() {
      let start = step.offsetSamples
      let end = index + 1 < steps.count ? steps[index + 1].offsetSamples : source.count
      // Same source position, same beat targets: isolate DSP differences.
      let contextEnd = min(source.count, max(end, start + 14400))
      before += try LegacyEverydayAudioDSP.render(Array(source[start..<contextEnd]),
        count: end - start, targetMidiNote: step.midiNote)
    }
    let a = EverydayAudioDSP.matchLevel(before)
    let b = EverydayAudioDSP.matchLevel(refined)
    try write(source, folder.appendingPathComponent("01-original.wav"))
    try write(a, folder.appendingPathComponent("02-previous-wavetable.wav"))
    try write(b, folder.appendingPathComponent("03-source-preserving.wav"))
    let silence = [Float](repeating: 0, count: 24000)
    try write(source + silence + a + silence + b,
      folder.appendingPathComponent("original-before-after.wav"))
    let report: [String: Any] = [
      "sampleRate": 48000, "samplesPerVersion": source.count,
      "sourceMedianMidi": reference, "melodyRootMidi": root,
      "targets": steps.map { ["offsetSamples": $0.offsetSamples, "midiNote": $0.midiNote] },
      "comparison": "identical source positions and targets; each version level-matched",
      "finite": b.allSatisfy(\.isFinite),
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: folder.appendingPathComponent("comparison.json"))
    print("Wrote original / previous / refined comparisons, \(source.count) samples each")
  }

  static func write(_ samples: [Float], _ url: URL) throws {
    var data = Data()
    func text(_ value: String) { data.append(value.data(using: .ascii)!) }
    func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    text("RIFF"); u32(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
    u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
    text("data"); u32(UInt32(samples.count * 2))
    for sample in samples {
      var value = Int16(max(-32767, min(32767, (sample * 32767).rounded()))).littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    try data.write(to: url)
  }
}
