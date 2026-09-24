import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';

AnalyzedClip _voice(String id, double pitch) => AnalyzedClip(
  assetId: id,
  sourceStartSample: 24000,
  durationSamples: 192000,
  sampleRate: 48000,
  onsetSamples: const [24000],
  audibleRegions: const [
    AudibleRegion(startSample: 24000, durationSamples: 192000),
  ],
  peak: .5,
  rms: .1,
  suggestedRole: SuggestedRole.sustain,
  fundamentalMidiNote: pitch,
);

void main() {
  test('lead is a continuous full passage with beat-aligned notes', () {
    final result = arrange(
      clips: [_voice('voice', 57)],
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.hop,
      seed: 1,
    );
    final phrases = result.events
        .where((e) => e.pitchSteps.isNotEmpty)
        .toList();
    expect(phrases, hasLength(5));
    for (final e in phrases) {
      expect(e.durationSamples, 90000);
      expect(e.effectiveSourceDurationSamples, greaterThanOrEqualTo(90000));
      expect(e.pitchSteps.map((p) => p.offsetSamples), [
        0,
        22500,
        45000,
        67500,
      ]);
      expect(e.hasValidPitchSteps, isTrue);
      final video = result.videoEvents[result.events.indexOf(e)];
      expect(video.sourceVideoStartTime.numerator, e.sourceStartSample);
      expect(video.durationSamples, e.durationSamples);
      expect(
        video.effectiveSourceDurationSamples,
        e.effectiveSourceDurationSamples,
      );
    }
    expect(
      phrases[1].sourceStartSample,
      phrases[0].sourceStartSample + phrases[0].durationSamples,
    );
    expect(Arrangement.fromJson(result.toJson()).toJson(), result.toJson());
    expect(result.events.any((e) => e.reverse), isTrue);
  });

  test(
    'MIDI advances through words and shifts a whole part by one octave choice',
    () {
      final result = arrange(
        clips: [_voice('voice', 57)],
        style: ArrangementStyle.lively,
        melodyTemplate: MelodyTemplate.midiScore,
        seed: 1,
      );
      // Select the three first melody onsets independent of any ducking gain.
      final note1 = result.events.firstWhere(
        (e) => e.destinationStartSample == 5625 && e.targetMidiNote != null,
      );
      final note2 = result.events.firstWhere(
        (e) => e.destinationStartSample == 11250 && e.targetMidiNote != null,
      );
      expect(note2.sourceStartSample - note1.sourceStartSample, 5625);
      expect(note1.effectiveSourceDurationSamples, greaterThanOrEqualTo(14400));
      expect(note1.targetMidiNote! % 12, 67 % 12);
      expect(note2.targetMidiNote! - note1.targetMidiNote!, 3);
    },
  );

  test(
    'pitch curves reject duplicate/out-of-range steps; old JSON remains valid',
    () {
      final result = arrange(
        clips: [_voice('voice', 57)],
        style: ArrangementStyle.sparse,
        melodyTemplate: MelodyTemplate.hop,
        seed: 1,
      );
      for (final offsets in [
        [1, 1000],
        [0, 0],
        [0, 90000],
        [0, -1],
      ]) {
        final json = result.toJson();
        final events = (json['events'] as List).cast<Map<String, Object?>>();
        final event = events.firstWhere((e) => e.containsKey('pitchSteps'));
        event['pitchSteps'] = [
          for (final offset in offsets)
            {'offsetSamples': offset, 'midiNote': 57},
        ];
        expect(
          () => Arrangement.fromJson(json),
          throwsA(isA<MediaContractException>()),
        );
      }
      final legacy = const SoundEvent(
        assetId: 'v',
        sourceStartSample: 0,
        destinationStartSample: 0,
        durationSamples: 4000,
        gain: .5,
        fades: EventFades(fadeInSamples: 0, fadeOutSamples: 0),
      );
      expect(SoundEvent.fromJson(legacy.toJson()).pitchSteps, isEmpty);
    },
  );
}
