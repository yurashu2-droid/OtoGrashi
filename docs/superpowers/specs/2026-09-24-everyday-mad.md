# Everyday sound → music / MAD redesign

## Intent (user-authorized behavior change)
Make casual recordings, conversations and reactions become a shareable 15-second music video. Do not require intentional singing, stable sustained notes, or musical skill. Keep recognizable phrases and long sounds as well as aggressively tuned/chopped notes. Spatial mirroring, reverse pickups, overlapping voices and growing video tiles must be driven by the sounds that actually play. Fix stock/popup playback without discarding the latest inline playback UI.

## Design
- Retain the 48 kHz / 720,000-sample clock, existing MIDI source data, local-only processing, and saved v1 projects.
- Detect pitch inside playable regions, independently of whole-file silence/role classification. Extend YIN range, interpolate the trough, and expose per-region pitch metadata. Top-level pitch is advisory, not authoritative for rendering.
- Add optional event fields for a bounded source duration, absolute target note, reversal, mirroring and treatment. Old events default to the old timing/processing. New events carry source bounds to BOTH audio and video. A native, sample-derived musicalizer measures the actual selected sound, tracks changing voices and imposes periodicity on unpitched sounds rather than inventing unrelated accompaniment.
- Introduce a deterministic arrangement with phrase spotlight → groove → pitched/chopped hook → layered climax. Keep original phrases at natural speed, sustain long notes, normalize quiet sources, and make real repeated/overlapping sound events for visual duplication. Preserve the bundled MIDI's pitches/relative intervals rather than folding individual notes.
- Derive scene boundaries from sound starts/ends; allow all 1–6 active sources. Rests hold a still frame, never an unrelated talking video. Every mirror/reverse/repetition uses the same event as the PCM renderer.
- Serialize playback commands; reject stale async replies; recreate native views when their source/trim changes; detach/pause on disposal and background. Use explicit per-track preview composition transforms so portrait/landscape/rotated sources stay centered. Preserve delayed audio-track timing.

## Non-goals / limitations
No speech transcription or semantic claims about which words are funny; phrase choice is acoustic. No guarantee of studio-quality results for every noisy/polyphonic recording. True silence remains unusable. No changes to capture privacy, permissions, sharing destinations, or source files.

## Evidence required
Portable Swift signal tests: low/high/boundary pitch, silence padding, changing pitches, voiced/noisy musicalization, output duration/finiteness, source loop and reverse. Dart contract/arrangement/scene/playback tests. iOS native build/tests and rendered audio/video artifacts on the existing CI runner where possible. Disclose anything not actually executed.
