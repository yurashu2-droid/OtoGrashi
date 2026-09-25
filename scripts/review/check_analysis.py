from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'ios/Runner/Media/AudioAnalyzer.swift').read_text()
models=s[s.index('enum AudioAnalysisError'):s.index('struct AudioAnalyzer {')]
measure=s[s.index('  func measure('):s.index('  private static func samples(')]
source='import Foundation\n'+models+'\nstruct AudioAnalyzer {\nstatic let sampleRate=48000\nstatic let frameSamples=480\nstatic let minimumOnsetSpacingSamples=2400\n'+measure+'\n}\n'
source+='''
@main struct Regression {
  static func main() throws {
    func tone(_ hz: Double, _ n: Int, _ gain: Double = 0.4) -> [Float] {
      (0..<n).map { Float(gain * sin(2 * Double.pi * hz * Double($0) / 48000)) }
    }
    let padding = [Float](repeating: 0, count: 60000)
    let padded = try AudioAnalyzer().measure(samples: padding + tone(220, 24000) + padding)
    precondition(padded.suggestedRole == .sustain)
    precondition(abs(padded.fundamentalMidiNote! - 57) < 0.1)
    print("PASS silence padding keeps sustained pitch", padded.fundamentalMidiNote!)
    let mixed = tone(220, 14400) + [Float](repeating: 0, count: 9600) + tone(330, 48000, 0.3)
    let regions = try AudioAnalyzer().measure(samples: mixed)
    precondition(regions.audibleRegions.count == 2 && regions.fundamentalMidiNote == nil)
    let notes = regions.audibleRegions.compactMap(\\.fundamentalMidiNote).sorted()
    precondition(notes.count == 2 && abs(notes[0] - 57) < 0.1 && abs(notes[1] - 64.01955) < 0.1)
    print("PASS separate regions keep independent pitch", notes)
  }
}
'''
with tempfile.TemporaryDirectory() as temp:
  path=Path(temp)/'analysis.swift';path.write_text(source)
  executable=Path(temp)/'regression'
  subprocess.run(['swiftc','-O',str(root/'ios/Runner/Media/EverydayAudioDSP.swift'),str(path),'-o',str(executable)],check=True)
  subprocess.run([str(executable)],check=True)
