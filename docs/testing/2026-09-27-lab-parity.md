# Lab parity: audio and picture processing

Reference: `tool/video_lab/lab_audio.py`, `mad_arranger.py`, `render_styles.py` and `lab_fx.py` at e85f30a. The supplied seed3 movie is a visual reference, not a reproducible recipe: its original arrangement/environment are not bundled with it.

## Target

Match the lab's speech articulation, pitch tracking and picture treatment in the iOS MAD renderer. Preserve seeded syllable repeats (AA, ABAB, skips) requested by the user. Keep natural mode's full-syllable behavior, since this request compares MAD outputs. Avoid an unrelated UI redesign or new effects.

## Work

- Audio: align tracking cadence/smoothing and PSOLA source marks, unvoiced handling and overlap normalization with the lab. Preserve known pure-tone safeguards and written melody intervals; do not restore the octave clamp which previously collapsed distinct notes.
- MAD speech: select a syllable per note, play a short head and sustain its vowel. Keep seed-based selection; never read outside the chosen region when stretching.
- Video: match PIL's encoded-RGB multiplicative brightness and saturation in Core Image, preserving alpha. Compare motion/flash rules against the director path rather than the optional PopGlitch look.

## Verification boundary

Run focused Dart arrangement tests after the grouped change. Native Swift and Core Image require the existing macOS CI. Source parity does not prove that the supplied movies will become identical: seed, source analysis and event recipes also influence the arrangement. Device listening remains the final check for perceived voice flutter.

## Implemented and checked

- MAD opts into lab-style <=90 ms syllable head plus <=80 ms voiced core; natural articulation remains unchanged. Seeded repetitions/alternation/skips are retained. Extremely long holds stop at the 0.1x stretch floor instead of reading outside their vowel.
- Both native pitched paths use 10 ms tracking, a voiced five-frame median, fractional crest alignment, unvoiced grains and overlap normalization. Upward-shift narrow grains and the short-fragment pitch-preserving fallback remain deliberate safeguards.
- MAD lighting uses display-encoded BT.709 multiplication, matching the writer's output space, with alpha preserved. The lab's scene flash condition/order is restored; existing punch motion already matched the lab.
- Related Flutter tests: 17 passed. Targeted Dart analysis: no issues. `git diff --check`: passed.
- Added native checks for steady voiced level, consonant continuity and brightness/alpha behavior. Native execution pending the grouped macOS CI run.

Remaining differences: source analysis and seed generators are not shared across Python/Dart; the vowel core uses app voiced-run metadata rather than lab per-frame stability scoring. Decoder/range differences can affect exact color matching. These changes do not claim byte-identical reproduction of seed3.mp4.
