import 'dart:math' as math;

import 'arrangement.dart';

/// Sings complete speech syllables in source order or in short seeded motifs.
/// A short note may contain only part of a syllable; the following note
/// continues where it left off. Long notes hold the voiced centre while the
/// onset and ending are spoken at natural speed.
final class WordedSinger {
  WordedSinger(this.clip, {int? seed})
    : _random = seed == null ? null : math.Random(_stableSeed(seed, clip.assetId)),
      _syllables = clip.syllables.where((s) => s.durationSamples > 0).toList()
        ..sort((a, b) => a.startSample.compareTo(b.startSample));

  final AnalyzedClip clip;
  final List<AudibleRegion> _syllables;
  final math.Random? _random;
  List<int> _motif = const [];
  int _motifPosition = 0;
  int _next = 0;
  int _offset = 0;

  static int _stableSeed(int seed, String assetId) {
    var hash = 0x811c9dc5 ^ (seed & 0xffffffff);
    for (final code in assetId.codeUnits) {
      hash = ((hash ^ code) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  void _chooseMotif() {
    final random = _random;
    if (random == null || _motif.isNotEmpty) return;
    final count = _syllables.length;
    final anchor = _next;
    final choice = random.nextInt(count >= 3 ? 4 : count == 2 ? 3 : 2);
    _motif = switch (choice) {
      0 => [for (var i = 0; i < math.min(count, 2 + random.nextInt(3)); i++)
          (anchor + i) % count],
      1 => List<int>.filled(2 + random.nextInt(3), anchor),
      2 => [anchor, (anchor + 1) % count, anchor, (anchor + 1) % count],
      _ => [anchor, (anchor + 2) % count, (anchor + 3) % count],
    };
    _motifPosition = 0;
  }

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
    final events = <SoundEvent>[];

    void add(int from, int at, int output, int input) {
      if (output > 0 && input > 0) {
        events.add(
          _event(from, at, output, input, midi, gain, role, partIndex),
        );
      }
    }

    var at = start;
    final end = start + duration;
    while (at < end) {
      _chooseMotif();
      final syllable = _syllables[_next];
      final source = syllable.startSample + _offset;
      final remaining = syllable.durationSamples - _offset;
      final available = end - at;
      if (_offset != 0 || remaining >= available) {
        // Finish an interrupted syllable at natural speed, then continue in
        // source order if there is room for another one in the same note.
        final input = math.min(remaining, available);
        add(source, at, input, input);
        at += input;
        _offset += input;
      } else {
        final vowel = _vowel(syllable);
        if (vowel == null) {
          add(source, at, remaining, remaining);
          at += remaining;
        } else {
          final (vowelStart, vowelLength) = vowel;
          final onset = vowelStart - source;
          final tail = remaining - onset - vowelLength;
          // Stretch only the voiced centre, up to the renderer's 0.1x limit.
          // Any further space flows into the next syllable.
          final held = math.min(available - onset - tail, vowelLength * 10);
          add(source, at, onset, onset);
          add(vowelStart, at + onset, held, vowelLength);
          add(vowelStart + vowelLength, at + onset + held, tail, tail);
          at += onset + held + tail;
        }
        _offset = syllable.durationSamples;
      }
      if (_offset >= syllable.durationSamples) {
        final reachedEnd = _next + 1 == _syllables.length;
        if (_random == null) {
          _next = (_next + 1) % _syllables.length;
        } else if (++_motifPosition < _motif.length) {
          _next = _motif[_motifPosition];
        } else {
          _next = (_motif.last + 1) % _syllables.length;
          _motif = const [];
        }
        _offset = 0;
        // Chronological playback restarts on a later note. Seeded motifs may
        // intentionally retrigger a completed syllable inside this note.
        if (_random == null && reachedEnd) break;
      }
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
