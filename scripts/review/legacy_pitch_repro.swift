// Diagnostic extraction for yurashu2-droid/OtoGrashi @ 9ccf5396b49c5d45047cdcdae3fa05a889e3a123.
// The computational bodies of AudioAnalyzer.measure, stableFundamental,
// fundamental, and audibleRegions are copied from ios/Runner/Media/AudioAnalyzer.swift.
// AVFoundation/media I/O and unrelated contracts are omitted. No app code is modified.
import Foundation

enum AudioAnalysisError: Error { case emptyAudio }
enum SuggestedRole: String { case transient, sustain, texture }
struct AudibleRegion { let startSample: Int; let durationSamples: Int }
struct SignalMetrics {
  let frameRMS: [Double]
  let differenceEnergy: [Double]
  let peak: Double
  let rms: Double
  let onsetSamples: [Int]
  let audibleRegions: [AudibleRegion]
  let suggestedRole: SuggestedRole
  let fundamentalMidiNote: Double?
}
struct AudioAnalyzer {
  static let sampleRate = 48_000
  static let frameSamples = 480
  static let minimumOnsetSpacingSamples = 2_400
  func measure(samples: [Float]) throws -> SignalMetrics {
    guard !samples.isEmpty else { throw AudioAnalysisError.emptyAudio }
    var frameRMS = [Double]()
    var differenceEnergy = [Double]()
    var peak = 0.0
    var totalSquares = 0.0
    var previousFrameRMS = 0.0
    for frameStart in stride(from: 0, to: samples.count, by: Self.frameSamples) {
      let frameEnd = min(frameStart + Self.frameSamples, samples.count)
      var frameSquares = 0.0
      for index in frameStart..<frameEnd {
        let sample = min(1.0, max(-1.0, Double(samples[index])))
        peak = max(peak, abs(sample))
        frameSquares += sample * sample
      }
      totalSquares += frameSquares
      let value = sqrt(frameSquares / Double(frameEnd - frameStart))
      frameRMS.append(value)
      differenceEnergy.append(abs(value - previousFrameRMS))
      previousFrameRMS = value
    }
    let rms = sqrt(totalSquares / Double(samples.count))
    let rmsThreshold = max(0.01, rms * 1.5)
    let differenceThreshold = max(0.01, rms * 0.5)
    var onsets = [Int]()
    for frame in frameRMS.indices
    where frameRMS[frame] >= rmsThreshold
      && differenceEnergy[frame] >= differenceThreshold
    {
      let candidate = frame * Self.frameSamples
      if onsets.last.map({ candidate - $0 >= Self.minimumOnsetSpacingSamples }) ?? true {
        onsets.append(candidate)
      }
    }
    if onsets.isEmpty, rms >= 0.001,
      let loudestFrame = frameRMS.indices.max(by: { frameRMS[$0] < frameRMS[$1] }),
      frameRMS[loudestFrame] >= max(0.005, rms * 0.5) {
      onsets.append(max(0, loudestFrame * Self.frameSamples - 2_400))
    }
    let role: SuggestedRole
    if peak < 0.001 && rms < 0.0001 {
      role = .texture
    } else if !onsets.isEmpty && peak >= max(0.05, rms * 3) {
      role = .transient
    } else if rms >= 0.01 {
      role = .sustain
    } else {
      role = .texture
    }
    let audibleRegions = Self.audibleRegions(
      frameRMS: frameRMS,
      sampleCount: samples.count,
      rms: rms
    )
    return SignalMetrics(
      frameRMS: frameRMS,
      differenceEnergy: differenceEnergy,
      peak: peak,
      rms: rms,
      onsetSamples: onsets,
      audibleRegions: audibleRegions,
      suggestedRole: role,
      fundamentalMidiNote: role == .sustain
        ? audibleRegions.first(where: { $0.durationSamples >= 12_000 }).flatMap {
          Self.stableFundamental(samples: samples, region: $0)
        }
        : nil
    )
  }
  private static func stableFundamental(
    samples: [Float], region: AudibleRegion
  ) -> Double? {
    let start = region.startSample
    let end = min(samples.count, start + region.durationSamples)
    let window = 4_096
    guard end - start >= 12_000 else { return nil }
    let available = end - start - window
    let offsets = [available / 6, available / 2, available * 5 / 6]
    let notes = offsets.compactMap {
      fundamental(in: samples, start: start + $0, count: window)
    }
    guard notes.count == 3,
      (notes.max()! - notes.min()!) <= 0.35
    else { return nil }
    return notes.reduce(0, +) / 3
  }
  private static func fundamental(in samples: [Float], start: Int, count: Int) -> Double? {
    let signal = (start..<(start + count)).map { Double(samples[$0]) }
    let mean = signal.reduce(0, +) / Double(count)
    let centered = signal.map { $0 - mean }
    let variance = centered.reduce(0) { $0 + $1 * $1 } / Double(count)
    guard variance >= 0.000_1 else { return nil }
    let minimumLag = sampleRate / 1_000
    let maximumLag = sampleRate / 100
    var runningDifference = 0.0
    var previous = 1.0
    var bestLag: Int?
    var bestValue = 1.0
    for lag in 1...maximumLag {
      var difference = 0.0
      for index in 0..<(count - maximumLag) {
        let delta = centered[index] - centered[index + lag]
        difference += delta * delta
      }
      runningDifference += difference
      guard lag >= minimumLag, runningDifference > 0 else { continue }
      let normalized = difference * Double(lag) / runningDifference
      if normalized < 0.18 && normalized < bestValue {
        bestLag = lag
        bestValue = normalized
      } else if let bestLag, normalized > previous,
        bestValue < 0.18 {
        let hertz = Double(sampleRate) / Double(bestLag)
        let midi = 69 + 12 * log2(hertz / 440)
        return (40...88).contains(midi) ? midi : nil
      }
      previous = normalized
    }
    return nil
  }
  private static func audibleRegions(
    frameRMS: [Double],
    sampleCount: Int,
    rms: Double
  ) -> [AudibleRegion] {
    let threshold = max(0.003, max(rms * 0.35, (frameRMS.max() ?? 0) * 0.10))
    var active = frameRMS.map { $0 >= threshold }
    guard active.contains(true) else { return [] }
    if active.count > 2 {
      for frame in active.indices where frame > 0 &&
        frame + 1 < active.count && !active[frame] {
        let before = max(0, frame - 5)
        let after = min(active.count - 1, frame + 5)
        if active[before..<frame].contains(true) &&
          active[(frame + 1)...after].contains(true) {
          active[frame] = true
        }
      }
    }
    var scored: [(region: AudibleRegion, score: Double)] = []
    var frame = 0
    while frame < active.count {
      guard active[frame] else { frame += 1; continue }
      let begin = frame
      var energy = 0.0
      var strongest = 0.0
      while frame < active.count && active[frame] {
        let level = frameRMS[frame]
        energy += level * level
        strongest = max(strongest, level)
        frame += 1
      }
      let start = max(0, begin * frameSamples - 960)
      let end = min(sampleCount, frame * frameSamples + 1_920)
      guard end > start else { continue }
      let meanEnergy = energy / Double(frame - begin)
      scored.append((
        region: AudibleRegion(startSample: start, durationSamples: end - start),
        score: meanEnergy + strongest * strongest
      ))
    }
    return scored.sorted { $0.score > $1.score }
      .prefix(16).map { $0.region }
  }
}

func tone(_ frequency: Double, _ seconds: Double, amplitude: Double = 0.4) -> [Float] {
  (0..<Int((48_000 * seconds).rounded())).map {
    Float(amplitude * sin(2 * .pi * frequency * Double($0) / 48_000))
  }
}
func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int((seconds * 48_000).rounded())) }
func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
func report(_ name: String, _ samples: [Float], expectedHz: Double? = nil) throws -> SignalMetrics {
  let m = try AudioAnalyzer().measure(samples: samples)
  var result: [String: Any] = ["case": name, "role": m.suggestedRole.rawValue,
    "samples": samples.count, "rms": m.rms,
    "regions": m.audibleRegions.map { ["start": $0.startSample, "duration": $0.durationSamples] }]
  if let n = m.fundamentalMidiNote {
    result["detectedMidi"] = n; result["detectedHz"] = hz(n)
    if let f = expectedHz { result["errorCents"] = 1200 * log2(hz(n) / f) }
  } else { result["detectedMidi"] = NSNull() }
  print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
  return m
}
let pure = try report("220 Hz, 0.5 seconds", tone(220, 0.5), expectedHz: 220)
_ = try report("same tone with 1.25 seconds silence on each side", silence(1.25) + tone(220, 0.5) + silence(1.25), expectedHz: 220)
for f in [82.406889, 98.0, 100.0, 101.0, 440.0, 880.0, 987.766603, 1046.502261, 1174.659072, 1318.510228] {
  _ = try report("frequency sweep \(f)", tone(f, 0.5), expectedHz: f)
}
// Dart region selection mirrored literally: first fitting, else longest.
let two = tone(220, 0.3, amplitude: 0.5) + silence(0.4) + tone(330, 1.0, amplitude: 0.3)
let twoMetrics = try report("short loud 220 Hz then long quieter 330 Hz", two)
let desired = 22_500
let selected = twoMetrics.audibleRegions.first(where: { $0.durationSamples >= desired })
  ?? twoMetrics.audibleRegions.max(by: { $0.durationSamples < $1.durationSamples })!
let actualFragment = Array(two[selected.startSample..<(selected.startSample + desired)])
_ = try report("selected score fragment, desired duration 22500 samples", actualFragment, expectedHz: 330)
if let fundamental = twoMetrics.fundamentalMidiNote {
  let shift = 60 - fundamental
  print("REGION_MISMATCH targetMidi=60 shift=\(shift) selectedTrueHz=330 impliedOutputMidi=\(69 + 12 * log2(330.0/440.0) + shift)")
}
_ = try report("first 100 ms is 330 Hz, remainder 220 Hz", tone(330, 0.1) + tone(220, 0.9))
// Dart _pitchForNote arithmetic mirrored for the legacy template's -3 note.
if let fundamental = pure.fundamentalMidiNote {
  let root = fundamental.rounded()
  let shift = root - 3 - fundamental
  let applied = shift >= -3 && shift <= 3 ? shift : 0
  print("LEGACY_RANGE fundamental=\(fundamental) target=\(root - 3) requested=\(shift) applied=\(applied) outputMidi=\(fundamental + applied)")
}
