"""Compile the actual Swift payload, mixing envelope and layout helpers on Linux/macOS.
Not an AVFoundation build. Run performance_regression.dart first to emit JSON.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
audio = (ROOT / 'ios/Runner/Media/AudioRenderer.swift').read_text()
video = (ROOT / 'ios/Runner/Media/VideoRenderer.swift').read_text()
code = audio[:audio.index('struct AudioRenderReport:')].replace('import AVFoundation\n', '')
code += video[video.index('enum VideoRenderError:'):video.index('struct VideoRenderReport')]
mix = audio[audio.index('  private func mixEvent('):audio.index('  private func loop(')].replace('private func', 'func')
rects = video[video.index('  static func performanceRects('):video.index('  private func drawPerformanceFrame(')]
code += '\nstruct Probe { let originalGain: Float = 1\n' + mix + rects + '\n}\n'
code += r'''
@main struct Check {
  static var checks = 0
  static func expect(_ condition: Bool, _ name: String) {
    precondition(condition, name); checks += 1
  }
  static func main() throws {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("performance-") || $0.lastPathComponent.hasPrefix("native-") }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    expect(files.count == 20, "20 generated native payload fixtures")
    for path in files {
      let request = try JSONDecoder().decode(VideoRenderRequestPayload.self, from: Data(contentsOf: path))
      expect(request.video.totalSamples == request.arrangement.totalSamples, "matching duration")
      for (a,v) in zip(request.arrangement.events, request.arrangement.videoEvents) {
        expect(a.sourceStartSample == v.sourceVideoStartTime.numerator, "same source sample")
        expect(a.effectiveSourceDurationSamples == v.effectiveSourceDurationSamples, "same loop")
        expect(a.isReversed == v.isReversed && a.partIndex == v.partIndex, "same part and direction")
      }
      print("PASS native decode and exact audio/video event contract: \(path.lastPathComponent)")
    }
    let probe = Probe()
    var mix = [Float](repeating: 0, count: 4800)
    let a = probe.mixEvent([Float](repeating: 0.8, count: 3200), destinationStart: 0,
      eventGain: 0.5, fadeInSamples: 0, fadeOutSamples: 0, into: &mix)
    let b = probe.mixEvent([Float](repeating: 0.2, count: 1600), destinationStart: 1600,
      eventGain: 0.25, fadeInSamples: 0, fadeOutSamples: 0, into: &mix)
    expect(a == [0.4,0.4] && b == [0.05], "each pad uses own gain-adjusted audio")
    expect(abs(mix[1700] - 0.45) < 0.00001, "voices really overlap in the mix")
    let silent = probe.mixEvent([Float](repeating: 0, count: 1600), destinationStart: 0,
      eventGain: 1, fadeInSamples: 0, fadeOutSamples: 0, into: &mix)
    expect(silent == [0], "silent pad does not pulse because a different voice plays")
    var faded = [Float](repeating: 0, count: 3200)
    let envelope = probe.mixEvent([Float](repeating: 1, count: 3200), destinationStart: 0,
      eventGain: 1, fadeInSamples: 3200, fadeOutSamples: 0, into: &faded)
    expect(envelope[0] < 0.5 && envelope[1] > 0.99 && faded[0] == 0, "visual envelope includes actual fades")
    print("PASS individual-pad audio envelope, silence, overlap and fades")
    for mode in ["mosaic","vinyl","sampler","voiceLead","neonTune","loopStation"] {
      for count in 1...18 {
        let rects = Probe.performanceRects(count: count, mode: mode, width: 360, height: 640)
        expect(rects.count == count, "one layout rect per pad")
        for rect in rects {
          expect(rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.maxX <= 360 &&
            rect.minY >= 0 && rect.maxY <= 640, "pad stays inside video")
        }
      }
    }
    print("PASS layout bounds: 6 modes x 18 pad counts")
    print("Native contract/layout/envelope checks: \(checks), failures: 0")
  }
}
'''
with tempfile.TemporaryDirectory() as temp:
    p = Path(temp) / 'PerformanceContract.swift'
    p.write_text(code)
    exe = Path(temp) / 'check'
    subprocess.run(['swiftc', str(ROOT / 'ios/Runner/Media/EverydayAudioDSP.swift'),
                    str(p), '-o', str(exe)], check=True)
    subprocess.run([str(exe), str(ROOT / 'ci-artifacts')], check=True)
