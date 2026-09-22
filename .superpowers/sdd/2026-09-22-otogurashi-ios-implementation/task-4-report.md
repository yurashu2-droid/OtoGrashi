# Task 4 implementation report

## Result

Implemented the versioned media-analysis messages, deterministic 15-second arrangement engine, AVFoundation mono/48 kHz analyzer, native XCTest registration, and simulator XCTest CI evidence capture. Rendering, capture UI, playback, and fake media output remain outside this task.

## Contracts

- `lib/media/media_messages.dart`
  - `MediaAnalysisRequest` schema v1 carries `assetId`, managed `relativePath`, project selection in integer microseconds, and `audioTrackStartUs`. The latter preserves a non-zero audio-track PTS instead of treating decoded sample zero as video time zero.
  - `AnalyzedClip` schema/analysis v1 carries `assetId`, selection `sourceStartSample`, selected `durationSamples`, mono `sampleRate=48000`, absolute-source `onsetSamples`, finite normalized peak/RMS, and the acoustic-only role `transient|sustain|texture`.
  - Unsupported versions, malformed ranges, non-finite levels, and onset positions outside the selected source interval are rejected.
- `lib/media/media_gateway.dart`
  - `MediaAnalysisGateway.analyze(MediaAnalysisRequest)` is the Task 3 boundary; no capture implementation or fake success is included.
- `lib/domain/arrangement.dart`
  - Arrangement schema v1 fixes `sampleRate=48000`, `totalSamples=720000`, bar=90000, beat=22500, and versions for template, analysis, and renderer.
  - Sound events store integer source/destination positions, duration, gain, and fades. Video events store corresponding asset/destination/duration, rational source time, normalized crop, and `loop|hold|once`.
  - Decoding rejects unsupported versions, invalid ranges/crops, and broken audio/video correspondence. `toJson()` remains compatible with Task 2's immutable versioned Project JSON fields.

## Arrangement behavior

- Uses a locally specified xorshift32 with a `0xffffffff` mask after every XOR/shift stage. A 32-bit zero seed is replaced with `0x6d2b79f5`.
- Three explicit 128 BPM / 8-bar templates implement sparse, swaying, and lively density, swing, gain, and role-dependent durations/fades.
- Bars 1-3 introduce the first three usable sources; bars 4-7 combine all usable sources; bar 8 supplies a pickup into the loop.
- Every event is bounded by both its selected source interval and the 720000-sample destination. Weak/no onset candidates fall back to deterministic interval selection.
- Silent source IDs remain in `sourceAssetIds` and are reported in `unusableAssetIds`, but receive no invented sound event. All-silent and fewer-than-three-usable inputs produce recoverable typed rejection reasons.

## Native analyzer and CI

- `AudioAnalyzer.swift` reads with AVFoundation, converts to non-interleaved mono Float32 at 48 kHz, and measures RMS plus frame-to-frame difference energy in 480-sample (10 ms) windows, peak, onset candidates with a 2400-sample minimum interval, and acoustic transient/sustain/texture role.
- File selection converts onset positions back to the original media sample timeline. `audioTrackStartUs` is subtracted only for decoding and retained through the absolute `sourceStartSample` result.
- `AudioAnalyzer.swift` and `AudioAnalyzerTests.swift` are explicit PBX file references and members of the Runner and RunnerTests Sources phases. The generated empty test was removed.
- CI discovers an available installed iPhone simulator from `simctl ... --json`, boots by UDID without hard-coding architecture or device name, runs `xcodebuild test` unsigned, and uploads logs plus `RunnerTests.xcresult` on every outcome.

## Test evidence

- TDD red evidence: the Dart test initially failed because arrangement/media types did not exist; the source-timeline test failed on the missing `sourceStartSample`; crop validation failed by accepting `x=-0.1`; each was made green by the scoped production change.
- `flutter test test/domain`: 13/13 passed.
- `flutter test`: 25/25 passed.
- `flutter analyze --fatal-infos`: no issues, exit 0.
- `git diff --check`: clean before the report was written.

Swift/XCTest cannot run on this Windows host. The tests and Xcode registration are checked in for the pinned macOS 26 / Xcode 26.6 CI job; its compile/test result and xcresult remain remote validation, not a local pass claim.

## Fixtures

- `test/fixtures/media_analysis_request_v1.json`: Dart/Swift request serialization contract.
- `test/fixtures/media_analysis_v1.json`: Dart/Swift analysis-result serialization contract.
- `test/fixtures/arrangement_seed_0_v1.json`: hand-reviewed stable zero-seed event signature for xorshift/template regression detection.

## Remaining limits

- Synthetic unit signals cover silence, mixed energy, separated impulses, sustained audio, resampling, and selection bounds. Real-world listening evaluation remains Task 5 evidence and is not claimed here.
- The gateway is a contract only. Task 3 will connect capture/import inspection; Tasks 5/6 will consume these contracts for real audio/video rendering.
