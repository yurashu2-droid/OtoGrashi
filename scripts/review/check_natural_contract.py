"""Compile and execute ACTUAL Swift payload/visual-timing code without AVFoundation.

This is not a Flutter test or an iOS build. It checks the shared native contract,
cache identity and the pure timing function on platforms with swiftc installed.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
renderer = (ROOT / 'ios/Runner/Media/AudioRenderer.swift').read_text()
contract = renderer[:renderer.index('struct AudioRenderReport:')].replace('import AVFoundation\n', '')
video = (ROOT / 'ios/Runner/Media/VideoRenderer.swift').read_text()
start = video.index('  static func musicalAccentAge(')
end = video.index('\n  static func buildUpTileCount', start)
contract += '\nstruct VisualTimingProbe {\n' + video[start:end] + '\n}\n'
contract += r'''
@main struct ContractRegression {
  static var checks = 0
  static func check(_ valid: Bool, _ message: String) {
    precondition(valid, message)
    checks += 1
    print("PASS \(message)")
  }
  static func decode(_ json: [String: Any]) throws -> ArrangementPayload {
    try JSONDecoder().decode(ArrangementPayload.self,
      from: JSONSerialization.data(withJSONObject: json))
  }
  static func main() throws {
    let event: [String: Any] = [
      "assetId": "voice", "sourceStartSample": 2400,
      "destinationStartSample": 48000, "durationSamples": 48000, "gain": 0.5,
      "fades": ["fadeInSamples": 72, "fadeOutSamples": 240],
      "sourceDurationSamples": 48000, "targetMidiNote": 57.0,
      "pitchSteps": [
        ["offsetSamples": 0, "durationSamples": 24000, "midiNote": 57.0],
        ["offsetSamples": 24000, "durationSamples": 24000, "midiNote": 60.0],
      ],
    ]
    var video: [String: Any] = [
      "assetId": "voice", "destinationStartSample": 48000, "durationSamples": 48000,
      "sourceDurationSamples": 48000,
      "sourceVideoStartTime": ["numerator": 2400, "denominator": 48000],
      "crop": ["x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0], "loopMode": "once",
    ]
    var json: [String: Any] = [
      "schemaVersion": 1, "sampleRate": 48000, "totalSamples": 720000,
      "templateId": "natural-check", "templateVersion": 1,
      "analysisVersion": 1, "rendererVersion": 1, "seed": 7, "style": "sparse",
      "sourceAssetIds": ["voice"], "unusableAssetIds": [String](),
      "events": [event], "videoEvents": [video],
    ]
    let decoded = try decode(json)
    let sound = decoded.events[0]
    check(sound.pitchSteps?.count == 2, "native payload accepts a continuing two-note phrase")
    let roundtrip = try JSONDecoder().decode(SoundEventPayload.self, from: JSONEncoder().encode(sound))
    check(roundtrip == sound, "native pitch automation roundtrip is lossless")
    check(decoded.videoEvents[0].sourceVideoStartTime.numerator == sound.sourceStartSample,
      "audio and video retain identical source start")
    check(VisualTimingProbe.musicalAccentAge(event: sound, sample: 72500) == 500,
      "visual accent follows the second beat without rewinding video")
    check(EverydayAudioDSP.sourceOffset(outputOffset: 24500, sourceCount: 48000, reverse: false) == 24500,
      "source video clock advances across the pitch boundary")
    var changed = sound
    changed.pitchSteps = [
      .init(offsetSamples: 0, durationSamples: 24000, midiNote: 57),
      .init(offsetSamples: 24000, durationSamples: 24000, midiNote: 64),
    ]
    check(sound.musicalCacheKey != changed.musicalCacheKey,
      "cache distinguishes melodies with the same first note")
    check(sound.musicalCacheKey == roundtrip.musicalCacheKey, "cache identity survives serialization")
    let invalidSteps: [[[String: Any]]] = [
      [["offsetSamples": 0, "durationSamples": 24000, "midiNote": 57.0],
       ["offsetSamples": 100, "durationSamples": 24000, "midiNote": 60.0]],
      [["offsetSamples": 47999, "durationSamples": 2, "midiNote": 57.0]],
      [["offsetSamples": Int.max, "durationSamples": 1, "midiNote": 57.0]],
      [["offsetSamples": 0, "durationSamples": Int.max, "midiNote": 57.0]],
      [["offsetSamples": 0, "durationSamples": 48000, "midiNote": 101.0]],
    ]
    for (index, steps) in invalidSteps.enumerated() {
      var invalid = event
      invalid["pitchSteps"] = steps
      json["events"] = [invalid]
      var rejected = false
      do { _ = try decode(json) } catch { rejected = true }
      check(rejected, "reject malformed pitch automation \(index + 1)")
    }
    var missingSource = event
    missingSource.removeValue(forKey: "sourceDurationSamples")
    json["events"] = [missingSource]
    check((try? decode(json)) == nil, "automation requires an explicit source range")
    json["events"] = [event]
    video["sourceDurationSamples"] = 47000
    json["videoEvents"] = [video]
    check((try? decode(json)) == nil, "reject audio/video source-range disagreement")
    var legacy = event
    legacy.removeValue(forKey: "pitchSteps")
    legacy.removeValue(forKey: "sourceDurationSamples")
    legacy.removeValue(forKey: "targetMidiNote")
    video.removeValue(forKey: "sourceDurationSamples")
    json["events"] = [legacy]; json["videoEvents"] = [video]
    let old = try decode(json)
    check(old.events[0].pitchSteps == nil && old.events[0].effectiveSourceDurationSamples == 48000,
      "legacy payload without automation keeps its old defaults")
    print("Contract checks: \(checks), failures: 0")
  }
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'NativeContract.swift'
    path.write_text(contract)
    executable = Path(directory) / 'contract-regression'
    subprocess.run(['swiftc', '-O', str(ROOT / 'ios/Runner/Media/EverydayAudioDSP.swift'),
                    str(path), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
