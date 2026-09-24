# Source-preserving melody

## Intent
Everyday speech should become music without losing the person, words, consonants,
original time evolution or the synchronized picture. Replace single-cycle wavetable
resynthesis; merely adding a dry phrase elsewhere is insufficient.

## Decisions / plan
- Use local pitch marks and pitch-synchronous overlap-add, copying native-rate
  waveform neighborhoods, never compressing one period into a repeating table.
  Unvoiced consonants remain dry. Unpitched textures retain mostly their waveform
  with modest source-driven resonance rather than an injected fundamental.
- Analyze pitch more finely than the musical beat. Add a bounded, optional
  per-event pitch-step curve. Ordinary leads use one continuous bar-length source
  passage with beat-aligned target notes and short glides, not 50 ms restarts.
- Advance MIDI source windows through a passage while retaining score note timing.
  Keep short stutters/echoes as accents, not the primary melody. Lower the default
  vocal register and center the motif on measured pitch when available.
- Keep the audio/video source clock, source duration, reverse, and 15-second
  export contract unchanged. Old event JSON without a curve remains decodable.

## Verification tasks
1. Reproduce unvoiced loss and spectral-envelope shift with the current Swift DSP.
2. Implement native-rate overlap-add and test consonants, vowels/formants, pitch,
   evolving speech, silence, short sources, looping, reverse, curve boundaries.
3. Extend Dart/Swift contracts together; reject invalid/unsorted curves. Test real
   arranger continuity, MIDI timing/source progression and serialization.
4. Build iOS and run existing native/Flutter suites. Export reproducible comparisons
   labeled as synthetic or TTS, not as recordings of the user's friends.

## Tradeoffs
A whisper or impact does not become an accurate sung note without timbre change.
Preserve its identity and rhythmic utility rather than replace it with an oscillator.
Large shifts, polyphonic speech, and wrong pitch estimates can still sound artificial.
