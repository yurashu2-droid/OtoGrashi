# Everyday sounds → MAD music

New song arrangements use source recordings in two ways: identifiable natural phrases, and source-derived pitched/chopped instruments. Pitch detection and suggested roles are hints, not eligibility requirements. Silent recordings remain silent and are not replaced with an unrelated backing track.

- Natural phrase spotlights use the longest detected audible region (not speech recognition). Automatic songs allow up to 2.25 seconds per spotlight; MIDI arrangements allow 1.25 seconds while preserving the score's 148 note events.
- Tuned material can hold a note beyond the short source window. Voice/noise grains are made periodic at the target MIDI pitch; the resulting robotic/MAD timbre is intentional, not a claim of transparent studio-quality vocal tuning.
- `sourceDurationSamples` and `reverse` are shared by matching audio/video events. Repeated audio and video use the same source-window period. Visual frames remain quantized to 30 fps.
- Mirror cuts, beat punches, and duplicate panels are driven by actual sounding events. Duplicate sound events really overlap in the audio mix.
- Compact library cards play inline on tap. Long press opens the detail sheet with rename and reuse actions. Updating a trim remounts the native player with the updated segment identity.
- Existing serialized events without the new optional fields keep their legacy rendering path; newly created song templates use the new arranger. The `none` rhythm-only template remains available.

Validation is tracked in the PR and CI evidence. Real iPhone playback, intelligibility of friends' speech, and subjective editing quality still require listening/viewing with representative recordings; synthetic DSP tests do not establish those properties.
