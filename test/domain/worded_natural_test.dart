import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/worded_singing.dart';

AnalyzedClip _speaker(int i) => AnalyzedClip(
  assetId: 'talk-$i',
  sourceStartSample: 0,
  durationSamples: 144000,
  sampleRate: 48000,
  onsetSamples: const [4800, 30000],
  audibleRegions: const [AudibleRegion(startSample: 4800, durationSamples: 120000)],
  peak: .8,
  rms: .2,
  suggestedRole: i == 0 ? SuggestedRole.transient : SuggestedRole.sustain,
  registerMidiNote: 50.0 + i * 3,
  syllables: const [
    AudibleRegion(startSample: 4800, durationSamples: 9600, fundamentalMidiNote: 52),
    AudibleRegion(startSample: 14400, durationSamples: 12000, fundamentalMidiNote: 54),
    AudibleRegion(startSample: 26400, durationSamples: 14400, fundamentalMidiNote: 51),
    AudibleRegion(startSample: 40800, durationSamples: 9600, fundamentalMidiNote: 53),
  ],
  voicedRuns: const [AudibleRegion(startSample: 4800, durationSamples: 45600)],
  pitchSpread: 4,
  purity: .1,
);

AnalyzedClip _motifSpeaker() => AnalyzedClip(
  assetId: 'motif-voice',
  sourceStartSample: 0,
  durationSamples: 18000,
  sampleRate: 48000,
  onsetSamples: const [0],
  audibleRegions: const [AudibleRegion(startSample: 0, durationSamples: 15000)],
  peak: .8,
  rms: .2,
  suggestedRole: SuggestedRole.sustain,
  syllables: const [
    AudibleRegion(startSample: 0, durationSamples: 3000),
    AudibleRegion(startSample: 3000, durationSamples: 3000),
    AudibleRegion(startSample: 6000, durationSamples: 3000),
    AudibleRegion(startSample: 9000, durationSamples: 3000),
    AudibleRegion(startSample: 12000, durationSamples: 3000),
  ],
  purity: .1,
);

void main() {
  test(
    'lab speech retriggers a short head and holds its own vowel per note',
    () {
      final singer = WordedSinger(_speaker(0), labArticulation: true);
      final first = singer.sing(0, 24000, 60, gain: .5);
      final second = singer.sing(25000, 24000, 64, gain: .5);
      expect(first, hasLength(2));
      expect(second, hasLength(2));
      expect(first.first.sourceStartSample, 4800);
      expect(second.first.sourceStartSample, 14400);
      expect(first.first.durationSamples, 4320);
      expect(second.first.durationSamples, 4320);
      expect(first.last.destinationStartSample, 4320);
      expect(first.last.stretch, lessThan(1));
      expect(first.every((e) => e.targetMidiNote == 60), isTrue);
      expect(second.every((e) => e.targetMidiNote == 64), isTrue);
      expect(
        first.last.sourceStartSample + first.last.sourceDurationSamples!,
        lessThanOrEqualTo(14400),
      );
      expect(
        second.last.sourceStartSample + second.last.sourceDurationSamples!,
        lessThanOrEqualTo(26400),
      );
    },
  );

  test('lab speech keeps seeded repeats and skips on separate notes', () {
    List<int> sequence(int seed) {
      final singer = WordedSinger(
        _motifSpeaker(),
        seed: seed,
        labArticulation: true,
      );
      return [
        for (var note = 0; note < 24; note++)
          singer
                  .sing(note * 10000, 8000, 60, gain: .5)
                  .first
                  .sourceStartSample ~/
              3000,
      ];
    }

    final patterns = [for (var seed = 0; seed < 32; seed++) sequence(seed)];
    expect(sequence(7), sequence(7));
    expect(
      patterns.any(
        (p) =>
            [for (var i = 1; i < p.length; i++) p[i] == p[i - 1]]
                .contains(true),
      ),
      isTrue,
    );
    expect(
      patterns.any(
        (p) =>
            [for (var i = 1; i < p.length; i++) p[i] == (p[i - 1] + 2) % 5]
                .contains(true),
      ),
      isTrue,
    );
  });

  test('lab speech caps a very long vowel hold inside its syllable', () {
    final events = WordedSinger(
      _speaker(0),
      labArticulation: true,
    ).sing(0, 100000, 60, gain: .5);
    expect(events, hasLength(2));
    expect(events.last.durationSamples, lessThan(100000 - 4320));
    expect(events.last.stretch, .1);
    expect(
      events.last.sourceStartSample + events.last.sourceDurationSamples!,
      lessThanOrEqualTo(14400),
    );
    final singer = WordedSinger(_speaker(0), labArticulation: true);
    singer.sing(0, 3000, 60, gain: .5);
    singer.sing(4000, 3000, 62, gain: .5);
    final breathy = singer.sing(8000, 100000, 64, gain: .5);
    expect(
      breathy.last.sourceStartSample + breathy.last.sourceDurationSamples!,
      lessThanOrEqualTo(40800),
    );
  });

  test('seeded speech selects repeat, alternating, and jumping motifs', () {
    List<int> sequence(int seed) {
      final singer = WordedSinger(_motifSpeaker(), seed: seed);
      return [
        for (var note = 0; note < 24; note++)
          singer.sing(note * 3200, 3000, 60, gain: .5).single.sourceStartSample ~/ 3000,
      ];
    }

    final patterns = [for (var seed = 0; seed < 32; seed++) sequence(seed)];
    expect(sequence(7), sequence(7));
    expect(patterns.map((p) => p.join(',')).toSet().length, greaterThan(1));
    expect(patterns.any((p) => [for (var i = 1; i < p.length; i++) p[i] == p[i - 1]].contains(true)), isTrue);
    expect(patterns.any((p) => [for (var i = 3; i < p.length; i++)
      p[i] == p[i - 2] && p[i - 1] == p[i - 3] && p[i] != p[i - 1]].contains(true)), isTrue);
    expect(patterns.any((p) => [for (var i = 1; i < p.length; i++)
      p[i] == (p[i - 1] + 2) % 5].contains(true)), isTrue);

    List<Map<String, Object?>> score(int seed) {
      final singer = WordedSinger(_motifSpeaker(), seed: seed);
      return [
        for (var note = 0; note < 24; note++)
          for (final event in singer.sing(note * 3200, 3000, 60 + note % 5,
              gain: .5))
            event.toJson(),
      ];
    }
    expect(score(7), score(7));
    expect(score(7), isNot(score(8)));
  });

  test('seeded speech completes a partial syllable before repeating it', () {
    final singer = WordedSinger(_motifSpeaker(), seed: 7);
    final first = singer.sing(0, 1800, 60, gain: .5).single;
    final second = singer.sing(2000, 1200, 62, gain: .5).single;
    expect(first.sourceStartSample, 0);
    expect(second.sourceStartSample, 1800);
    expect(first.sourceDurationSamples! + second.sourceDurationSamples!,
        greaterThanOrEqualTo(3000));
  });

  test('short notes carry all syllables forward at natural speed', () {
    final singer = WordedSinger(_speaker(0));
    final events = <SoundEvent>[];
    var reachedEnd = false;
    for (var i = 0; i < 30; i++) {
      for (final event in singer.sing(i * 3200, 3000, 60, gain: .5)) {
        events.add(event);
        if (event.sourceStartSample + event.sourceDurationSamples! >= 50400) {
          reachedEnd = true;
          break;
        }
      }
      if (reachedEnd) break;
    }
    expect(events.first.sourceStartSample, 4800);
    expect(events.every((e) => e.stretch == 1), isTrue);
    for (var i = 1; i < events.length; i++) {
      expect(events[i].sourceStartSample, greaterThanOrEqualTo(events[i - 1].sourceStartSample));
      expect(events[i].sourceStartSample,
          lessThanOrEqualTo(events[i - 1].sourceStartSample + events[i - 1].sourceDurationSamples!));
    }
    expect(events.last.sourceStartSample + events.last.sourceDurationSamples!,
        greaterThanOrEqualTo(50400));
    expect(events.any((e) => e.sourceStartSample <= 26400 &&
        e.sourceStartSample + e.sourceDurationSamples! > 26400), isTrue);
  });

  test('a partial syllable continues into the next one without a note gap', () {
    final singer = WordedSinger(_speaker(0));
    singer.sing(0, 3000, 60, gain: .5);
    final events = singer.sing(3200, 12000, 62, gain: .5);
    expect(events, hasLength(2));
    expect(events[0].sourceStartSample, 7800);
    expect(events[1].sourceStartSample, 14400);
    expect(events.every((e) => e.stretch == 1), isTrue);
    expect(events[0].durationSamples + events[1].durationSamples, 12000);
    expect(events[1].destinationStartSample,
        events[0].destinationStartSample + events[0].durationSamples);
  });

  test('a vowel hold at its stretch limit continues into the next syllable', () {
    final events = WordedSinger(_speaker(0)).sing(0, 100000, 60, gain: .5);
    expect(events.any((e) => e.sourceStartSample >= 14400), isTrue);
    expect(events.last.destinationStartSample + events.last.durationSamples, 100000);
    for (var i = 1; i < events.length; i++) {
      expect(events[i].destinationStartSample,
          events[i - 1].destinationStartSample + events[i - 1].durationSamples);
      expect(events[i].sourceStartSample, greaterThan(events[i - 1].sourceStartSample));
    }
  });

  test('long notes hold only the voiced centre, after onset and before ending', () {
    final events = WordedSinger(_speaker(0)).sing(0, 30000, 60, gain: .5);
    expect(events, hasLength(3));
    expect(events.first.sourceStartSample, 4800);
    expect(events.first.stretch, 1);
    expect(events[1].stretch, lessThan(1));
    expect(events.last.stretch, 1);
    expect(events.last.sourceStartSample + events.last.sourceDurationSamples!,
        greaterThanOrEqualTo(14400));
    for (var i = 1; i < events.length; i++) {
      expect(events[i].sourceStartSample, greaterThan(events[i - 1].sourceStartSample));
      expect(events[i].destinationStartSample,
          events[i - 1].destinationStartSample + events[i - 1].durationSamples);
    }
  });

  test('原声を楽しむ sings speech word by word; other modes keep their line', () {
    final clips = [for (var i = 0; i < 3; i++) _speaker(i)];
    for (final template in [MelodyTemplate.hop, MelodyTemplate.midiScore]) {
      for (final seconds in [15, 30]) {
        final natural = arrange(
          clips: clips,
          style: ArrangementStyle.swaying,
          seed: 5,
          melodyTemplate: template,
          durationSeconds: seconds,
        );
        final sung = natural.events.where((e) => e.stretch != null).toList();
        expect(sung, isNotEmpty, reason: '$template ${seconds}s');
        expect(sung.every((e) => e.targetMidiNote != null && e.pitchSteps.isEmpty), isTrue);
        expect(Arrangement.fromJson(natural.toJson()).toJson(), natural.toJson());
      }
      final mosaic = arrange(
        clips: clips,
        style: ArrangementStyle.swaying,
        seed: 5,
        melodyTemplate: template,
        performanceMode: PerformanceMode.mosaic,
        durationSeconds: 15,
      );
      expect(mosaic.events.any((e) => e.stretch != null), isFalse);
    }
    final dry = arrange(
      clips: clips,
      style: ArrangementStyle.swaying,
      seed: 5,
      melodyTemplate: MelodyTemplate.none,
      durationSeconds: 30,
    );
    expect(dry.events.every((e) => e.stretch == null && e.targetMidiNote == null), isTrue);
  });
}
