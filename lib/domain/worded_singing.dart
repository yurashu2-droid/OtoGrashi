import 'dart:math' as math;

import 'arrangement.dart';

/// Speech sings its words: one syllable per note, in order. Each note opens
/// with the syllable as said (consonant and the start of its vowel, up to
/// 90 ms, at most 1.4x faster), so the word is heard; the rest of the note
/// holds the middle of that syllable's own voiced part, stretched and tuned
/// onto the note, so the tune is heard. Mostly-breath syllables are skipped.
final class WordedSinger {
  WordedSinger(this.clip) : _syllables = _voiced(clip);

  final AnalyzedClip clip;
  final List<AudibleRegion> _syllables;
  int _next = 0;

  /// Several syllables and not a tone (a crow or a whistle stays tonal).
  static bool isSpeech(AnalyzedClip clip) =>
      clip.syllables.length >= 4 && (clip.purity ?? 0) < .8;

  static List<AudibleRegion> _voiced(AnalyzedClip clip) {
    final all = clip.syllables.toList()
      ..sort((a, b) => a.startSample.compareTo(b.startSample));
    final voiced = all
        .where((s) => _overlap(clip, s).$2 * 10 >= s.durationSamples * 6)
        .toList();
    return voiced.isNotEmpty ? voiced : all;
  }

  /// The longest stretch of `s` inside one voiced run: (start, length).
  static (int, int) _overlap(AnalyzedClip clip, AudibleRegion s) {
    var best = (s.startSample, 0);
    final end = s.startSample + s.durationSamples;
    for (final r in clip.voicedRuns) {
      final from = math.max(s.startSample, r.startSample);
      final to = math.min(end, r.startSample + r.durationSamples);
      if (to - from > best.$2) best = (from, to - from);
    }
    return best;
  }

  /// The events that sing one note of `duration` samples at `start`.
  List<SoundEvent> sing(int start, int duration, double midi, {required double gain}) {
    if (_syllables.isEmpty || duration < 48) return const <SoundEvent>[];
    final syllable = _syllables[_next++ % _syllables.length];
    final said = math.min(
      math.min(syllable.durationSamples, 4320),
      (duration / .7).round(),
    );
    final head = math.max(1, math.min(duration, said));
    final events = [
      _event(syllable.startSample, start, head, said / head, midi, gain),
    ];
    final hold = duration - head;
    if (hold > 1440) {
      final (voicedStart, voicedLength) = _overlap(clip, syllable);
      final length = voicedLength > 0 ? voicedLength : syllable.durationSamples;
      final from = voicedLength > 0 ? voicedStart : syllable.startSample;
      final core = math.max(1, math.min(3840, length));
      events.add(
        _event(
          from + (length - core) ~/ 2,
          start + head,
          hold,
          (core / hold).clamp(.12, 1.0).toDouble(),
          midi,
          gain,
        ),
      );
    }
    return events;
  }

  SoundEvent _event(int source, int start, int duration, double stretch, double midi, double gain) {
    final clipStart = clip.sourceStartSample;
    final clipEnd = clipStart + clip.durationSamples;
    final rounded = ((stretch * 10000).roundToDouble() / 10000).clamp(.1, 2.0).toDouble();
    final read = math.max(1, math.min((duration * rounded).ceil() + 2, clipEnd - clipStart));
    final from = math.max(clipStart, math.min(source, clipEnd - read));
    return SoundEvent(
      assetId: clip.assetId,
      sourceStartSample: from,
      sourceDurationSamples: read,
      destinationStartSample: start,
      durationSamples: duration,
      gain: gain,
      fades: EventFades(
        fadeInSamples: math.min(96, duration ~/ 4),
        fadeOutSamples: math.min(480, duration ~/ 4),
      ),
      targetMidiNote: midi.clamp(24.0, 100.0).toDouble(),
      treatment: SoundTreatment.tuned,
      stretch: rounded,
    );
  }
}
