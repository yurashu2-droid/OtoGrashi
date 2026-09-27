import 'dart:math' as math;

import 'arrangement.dart';

/// Sings speech in source order. A short note may contain only part of a
/// syllable; the following note continues where it left off. Long notes hold
/// the voiced centre while the onset and ending are spoken at natural speed.
final class WordedSinger {
  WordedSinger(this.clip)
    : _syllables = clip.syllables.toList()
        ..sort((a, b) => a.startSample.compareTo(b.startSample));

  final AnalyzedClip clip;
  final List<AudibleRegion> _syllables;
  int _next = 0;
  int _offset = 0;

  static bool isSpeech(AnalyzedClip clip) =>
      clip.syllables.length >= 4 && (clip.purity ?? 0) < .8;

  /// The longest voiced run inside this syllable, trimmed at both edges so
  /// consonants and transitions are not stretched along with the vowel.
  (int, int)? _vowel(AudibleRegion syllable) {
    final end = syllable.startSample + syllable.durationSamples;
    var bestStart = 0;
    var bestLength = 0;
    for (final run in clip.voicedRuns) {
      final from = math.max(syllable.startSample, run.startSample);
      final to = math.min(end, run.startSample + run.durationSamples);
      if (to - from > bestLength) {
        bestStart = from;
        bestLength = to - from;
      }
    }
    if (bestLength < 2400) return null;
    final margin = math.min(480, bestLength ~/ 8);
    return (bestStart + margin, bestLength - 2 * margin);
  }

  List<SoundEvent> sing(
    int start,
    int duration,
    double midi, {
    required double gain,
    String? role,
    int partIndex = 0,
  }) {
    if (_syllables.isEmpty || duration < 48) return const <SoundEvent>[];
    final syllable = _syllables[_next];
    final source = syllable.startSample + _offset;
    final remaining = syllable.durationSamples - _offset;
    final events = <SoundEvent>[];

    void add(int from, int at, int output, int input) {
      if (output > 0 && input > 0) {
        events.add(
          _event(from, at, output, input, midi, gain, role, partIndex),
        );
      }
    }

    if (_offset != 0 || remaining > duration) {
      // Preserve consonants at their original speed. Later notes take over
      // when the syllable is longer than this one.
      final input = math.min(remaining, duration);
      add(source, start, input, input);
      _offset += input;
    } else {
      final vowel = _vowel(syllable);
      if (vowel == null || duration == remaining) {
        add(source, start, remaining, remaining);
      } else {
        final (vowelStart, vowelLength) = vowel;
        final onset = vowelStart - source;
        final tail = remaining - onset - vowelLength;
        // The renderer supports down to 0.1x. If a note is still longer,
        // leave its final space silent rather than repeating earlier speech.
        final held = math.min(duration - onset - tail, vowelLength * 10);
        add(source, start, onset, onset);
        add(vowelStart, start + onset, held, vowelLength);
        add(vowelStart + vowelLength, start + onset + held, tail, tail);
      }
      _offset = remaining;
    }

    if (_offset >= syllable.durationSamples) {
      _next = (_next + 1) % _syllables.length;
      _offset = 0;
    }
    return events;
  }

  SoundEvent _event(
    int source,
    int start,
    int duration,
    int input,
    double midi,
    double gain,
    String? role,
    int partIndex,
  ) {
    final clipEnd = clip.sourceStartSample + clip.durationSamples;
    final read = math.min(input + 2, clipEnd - source);
    return SoundEvent(
      assetId: clip.assetId,
      sourceStartSample: source,
      sourceDurationSamples: read,
      destinationStartSample: start,
      durationSamples: duration,
      gain: gain,
      fades: EventFades(
        fadeInSamples: math.min(96, duration ~/ 4),
        fadeOutSamples: math.min(480, duration ~/ 4),
      ),
      partIndex: partIndex,
      targetMidiNote: midi.clamp(24.0, 100.0).toDouble(),
      treatment: SoundTreatment.tuned,
      role: role,
      stretch: ((input / duration * 10000).roundToDouble() / 10000)
          .clamp(.1, 2.0)
          .toDouble(),
    );
  }
}
