import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';

AnalyzedClip _clip(int i, {bool voiced = true}) => AnalyzedClip(
  assetId: 'clip-$i',
  sourceStartSample: 4800,
  durationSamples: 144000,
  sampleRate: 48000,
  onsetSamples: [9600 + i * 480, 60000],
  audibleRegions: const [
    AudibleRegion(startSample: 9600, durationSamples: 48000),
    AudibleRegion(startSample: 72000, durationSamples: 60000),
  ],
  peak: .8,
  rms: .2,
  suggestedRole: i == 0 ? SuggestedRole.transient : SuggestedRole.sustain,
  registerMidiNote: 50.0 + i * 4,
  syllables: const [
    AudibleRegion(startSample: 9600, durationSamples: 9600, fundamentalMidiNote: 55),
    AudibleRegion(startSample: 19200, durationSamples: 12000, fundamentalMidiNote: 57),
    AudibleRegion(startSample: 31200, durationSamples: 26400),
    AudibleRegion(startSample: 72000, durationSamples: 60000, fundamentalMidiNote: 56),
  ],
  voicedRuns: voiced
      ? const [
          AudibleRegion(startSample: 9600, durationSamples: 21600),
          AudibleRegion(startSample: 72000, durationSamples: 60000),
        ]
      : const [],
  pitchSpread: voiced ? 2.0 + i : 30,
  purity: i == 1 ? .9 : .1,
);

void main() {
  test('MAD arrangements stay inside the contract for every shape', () {
    for (final count in [1, 2, 3, 6]) {
      final clips = [for (var i = 0; i < count; i++) _clip(i, voiced: i != 2)];
      for (final seconds in [15, 30]) {
        for (final melody in [MelodyTemplate.midiScore, MelodyTemplate.none]) {
          for (final seed in [1, 2, 3, 4, 5]) {
            final a = arrange(
              clips: clips,
              style: ArrangementStyle.lively,
              seed: seed,
              melodyTemplate: melody,
              performanceMode: PerformanceMode.mad,
              durationSeconds: seconds,
            );
            final b = Arrangement.fromJson(a.toJson());
            expect(b.performanceMode, PerformanceMode.mad);
            expect(b.totalSamples, seconds * 48000);
            expect(b.events.length, lessThanOrEqualTo(Arrangement.maxEvents));
            expect(b.toJson(), a.toJson());
            for (final e in a.events) {
              final clip = clips.singleWhere((c) => c.assetId == e.assetId);
              expect(e.sourceStartSample, greaterThanOrEqualTo(clip.sourceStartSample));
              expect(
                e.sourceStartSample + e.effectiveSourceDurationSamples,
                lessThanOrEqualTo(clip.sourceStartSample + clip.durationSamples),
              );
              expect(SoundEvent.roles.contains(e.role), isTrue);
            }
            if (melody == MelodyTemplate.none) {
              expect(
                a.events.every((e) => e.targetMidiNote == null && e.pitchSteps.isEmpty),
                isTrue,
                reason: 'rhythm only stays unpitched',
              );
            }
          }
        }
      }
    }
  });

  test('a melody note is a raw syllable attack followed by a tuned body', () {
    final a = arrange(
      clips: [_clip(0), _clip(2)],
      style: ArrangementStyle.lively,
      seed: 3,
      melodyTemplate: MelodyTemplate.midiScore,
      performanceMode: PerformanceMode.mad,
      durationSeconds: 30,
    );
    final melody = a.events.where((e) => e.role == 'melody').toList();
    final attacks = melody.where((e) => e.targetMidiNote == null && e.rate == null);
    final bodies = melody.where((e) => e.targetMidiNote != null);
    expect(attacks, isNotEmpty);
    expect(bodies, isNotEmpty);
    for (final body in bodies) {
      expect(
        attacks.any(
          (h) => h.destinationStartSample + h.durationSamples == body.destinationStartSample,
        ),
        isTrue,
        reason: 'each body continues straight from its attack',
      );
    }
  });

  test('the seed changes the effects but the same seed repeats exactly', () {
    final clips = [_clip(0), _clip(1), _clip(3)];
    Map<String, Object?> make(int seed) => arrange(
      clips: clips,
      style: ArrangementStyle.lively,
      seed: seed,
      melodyTemplate: MelodyTemplate.midiScore,
      performanceMode: PerformanceMode.mad,
      durationSeconds: 30,
    ).toJson();
    expect(make(7), make(7));
    final variants = {
      for (var seed = 1; seed <= 8; seed++) make(seed).toString().hashCode,
    };
    expect(variants.length, greaterThan(4));
  });

  test('a whistle-like clip is retuned by speed, not by grains', () {
    final a = arrange(
      clips: [_clip(1)],
      style: ArrangementStyle.lively,
      seed: 2,
      melodyTemplate: MelodyTemplate.midiScore,
      performanceMode: PerformanceMode.mad,
      durationSeconds: 15,
    );
    final bodies = a.events.where((e) => e.role == 'melody' && e.rate != null);
    expect(bodies, isNotEmpty);
    expect(bodies.every((e) => e.targetMidiNote == null), isTrue);
  });

  test('every clip is heard beyond the drum kit, cameos quietly behind the melody', () {
    final clips = [for (var i = 0; i < 6; i++) _clip(i, voiced: i != 2)];
    for (final seconds in [15, 30]) {
      for (final seed in [1, 2, 3]) {
        final a = arrange(
          clips: clips,
          style: ArrangementStyle.lively,
          seed: seed,
          melodyTemplate: MelodyTemplate.midiScore,
          performanceMode: PerformanceMode.mad,
          durationSeconds: seconds,
        );
        for (final clip in clips) {
          expect(
            a.events.any((e) =>
                e.assetId == clip.assetId &&
                const {'phrase', 'melody', 'bass', 'backing'}.contains(e.role)),
            isTrue,
            reason: '${clip.assetId} ${seconds}s seed $seed',
          );
        }
        final backing = a.events.where((e) => e.role == 'backing').toList();
        expect(backing, hasLength(seconds == 30 ? 4 : 2));
        for (final e in backing) {
          expect(e.gain, lessThan(.5));
          expect(e.treatment, SoundTreatment.phrase);
        }
      }
    }
  });
}
