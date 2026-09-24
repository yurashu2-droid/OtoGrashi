# Natural voice melody implementation plan and execution record

Goal: recognize the original person / sound while it plays a melody, instead of reducing it to a periodic oscillator.
Target baseline: f02eab5619815668ba1bf2136348dca9265f56f7, codex/everyday-mad-overhaul.
Delivery: local patch and changed-file archive. No GitHub writes, PR update, merge or new CI run were performed this turn; the current connector exposes read operations only.
User authorized implementation directly; this corrects the earlier audio concept.
Spec: docs/design/natural-voice-melody.md

Architecture: preserve advancing source time; retune voiced audio using pitch-synchronous overlapping source grains without single-cycle tables or added oscillators. Copy unvoiced consonants. Wholly unpitched sounds get modest source-excited resonance. Note automation changes pitch inside longer audio/video events, without restarting speech. Serialized additions are optional.

- [x] Run identity regression against previous DSP: two failures (noise waveform and consonant preservation) reproduced.
- [x] Replace cycle tables with pitch-synchronous overlap-add and continuous voiced/unvoiced tracking; rerun actual Swift tests successfully.
- [x] Add optional bounded pitch steps to Dart/Swift payloads and include all steps in the actual renderer cache key; compile/run native payload and cache tests.
- [x] Implement advancing phrases, joined short pauses, beat-length targets and register selection. Add Flutter regression tests for these rules and MIDI positions.
- [x] Drive visual beat accents from internal note steps, without restarting the video clock; compile/run the pure timing function.
- [x] Generate old/new comparisons using identical synthetic speech and actual old/new Swift DSP, with matched RMS levels.
- [x] Run portable checks: 40 DSP + 18 natural-voice + 2 analyzer + 15 payload/timing/cache checks, zero failures. Parse all five edited Swift files.
- [ ] Run Flutter formatting, static analysis and full Flutter test suite (SDK unavailable here).
- [ ] Run native XCTest and an iOS build; audition real voices on device (not available here).

Review focus: preserve silence and unvoiced attacks, respect source trim bounds, keep loop/reverse clocks, validate automation ranges, and never confuse cached melodies that differ after the first beat. Numerical tests do not prove subjective naturalness. Existing previously passing CI is not validation of this patch.
