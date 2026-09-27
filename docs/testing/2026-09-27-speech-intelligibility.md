# Speech intelligibility repair

## Scope

Repair speech that becomes unintelligible when mapped to melody notes, and deliver an unsigned iPhone Release IPA. Start from `26eb505` on `claude/video-styles`. Preserve existing visuals and source recordings. No signing credentials or TestFlight configuration.

## Confirmed code-level causes

- Both speech arrangers selected at most 90 ms of an onset and 80 ms of a central vowel, omitting the rest of the syllable. The central selection could move backwards over already played samples.
- Filtering syllables by a 60% voiced-overlap threshold discarded consonant-heavy material. These boundaries are loudness valleys, not recognized words.
- The minimum vowel playback rate could consume samples beyond the selected vowel. End-of-clip clamping could move the selected source start backwards.
- Native stretched rendering re-estimated pitch on each extracted fragment. When tracking failed, ordinary resampling changed both speed and pitch.
- The Python lab limited reference-free pitch shifts to one octave; the native stretched path did not. Lab renders therefore did not demonstrate native equivalence.

## Implementation and validation plan

1. Share speech sequencing between natural and MAD arrangements; keep source order, carry remaining phonemes across short notes, preserve consonants and tails, and extend only suitable voiced material.
2. Repair native stretched rendering so missing pitch does not turn the source into a slowed, lowered voice; bound extreme speech retuning. Keep existing event/audio/video contracts.
3. Add focused regressions for chronological speech coverage and native pitch/stretch behavior. Run relevant Dart checks locally; validate native code in the existing macOS CI.
4. Review the combined change, push once when ready, and use the existing unsigned IPA workflow. Verify the successful run, artifact commit, and packaged IPA.

## Limits

Code and signal tests cannot certify how understandable every recording sounds. The installed IPA/version and the user's original/rendered audio pair were not available for a listening comparison. Previously exported videos keep their old audio; recreate a work from its source recordings to exercise the repaired arrangement.

## Local verification

- Focused Flutter tests: `worded_natural_test.dart` and `mad_arranger_test.dart`, 10 passed.
- Dart analysis of both changed production files and both changed test files: no issues.
- Combined code review: no remaining blocking findings; no audio/video payload schema changes.
- Two native regressions cover bounded retuning and preservation of pitch when a fragment is too short for tracking. Their execution requires the macOS CI runner.
- A numerical fallback probe retained the 220 Hz component rather than halving it to 110 Hz (energy ratio 15.7). This is supporting signal evidence, not an iPhone listening test.
- A proposed grain-width change was rejected: a source-period Hann grain cancelled most of a pure tone at an octave shift. The existing limited grain width is retained.

## Follow-up: melody contour regression in Build 48

The per-frame one-octave limit added in `c5bd670` was the wrong constraint: a source at MIDI 57 mapped target notes 72, 74 and 76 to the same MIDI 69. The passing clamp regression tested that limit, not preservation of the musical intervals. Register selection already happens for an entire melody in the arrangers; native rendering must respect the resulting distinct targets.

Remove the per-note clipping, retaining only a small bounded source-inflection offset when a reference pitch is provided. Keep the pitch-preserving fallback and chronological speech sequencing. Also fill the unused portion of a note by continuing into the next syllable, rather than ending the event when a carried-over syllable finishes. Replace the clamp assertion with a three-note pitch-contour regression and add a no-gap source-continuation regression. Real-device melody/word balance still needs a listening comparison.
