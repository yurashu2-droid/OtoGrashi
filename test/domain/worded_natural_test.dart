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

void main() {
  test('short notes carry all syllables forward at natural speed', () {
    final singer = WordedSinger(_speaker(0));
    final events = <SoundEvent>[];
    for (var i = 0; i < 30; i++) {
      events.addAll(singer.sing(i * 3200, 3000, 60, gain: .5));
      if (events.last.sourceStartSample + events.last.sourceDurationSamples! >= 50400) break;
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
