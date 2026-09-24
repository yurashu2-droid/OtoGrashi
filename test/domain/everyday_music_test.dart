import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/midi_score_data.dart';
import 'package:otogurashi/domain/video_recipe.dart';

AnalyzedClip clip(
  String id, {
  int length = 96000,
  SuggestedRole role = SuggestedRole.sustain,
}) => AnalyzedClip(
  assetId: id,
  durationSamples: length,
  sampleRate: 48000,
  onsetSamples: const [0],
  audibleRegions: [AudibleRegion(startSample: 0, durationSamples: length)],
  peak: .5,
  rms: .12,
  suggestedRole: role,
);

void main() {
  test(
    'unmeasured conversations get BOTH natural phrases and tuned melody',
    () {
      final result = arrange(
        clips: [clip('a'), clip('b'), clip('c')],
        style: ArrangementStyle.lively,
        melodyTemplate: MelodyTemplate.hop,
        seed: 7,
      );
      expect(result.events.any((e) => e.targetMidiNote != null), isTrue);
      for (final id in ['a', 'b', 'c']) {
        expect(
          result.events.any(
            (e) =>
                e.assetId == id &&
                e.treatment == SoundTreatment.phrase &&
                e.durationSamples >= 36000,
          ),
          isTrue,
        );
      }
      expect(result.videoEvents.any((e) => e.mirror), isTrue);
      expect(result.events.any((e) => e.reverse), isTrue);
      expect(Arrangement.fromJson(result.toJson()).toJson(), result.toJson());
    },
  );
  test(
    'short noises sustain full target notes without reading past their source',
    () {
      final sources = [
        clip('a', length: 4800),
        clip('b', length: 4800),
        clip('c', length: 4800),
      ];
      final result = arrange(
        clips: sources,
        style: ArrangementStyle.sparse,
        melodyTemplate: MelodyTemplate.midiScore,
        seed: 4,
      );
      final notes = result.events
          .where((e) => e.treatment == SoundTreatment.tuned)
          .toList();
      expect(notes.length, 148);
      expect(
        notes.any((e) => e.durationSamples > e.effectiveSourceDurationSamples),
        isTrue,
      );
      for (var i = 0; i < result.events.length; i++) {
        final a = result.events[i], v = result.videoEvents[i];
        expect(
          a.sourceStartSample + a.effectiveSourceDurationSamples,
          lessThanOrEqualTo(4800),
        );
        expect(
          v.effectiveSourceDurationSamples,
          a.effectiveSourceDurationSamples,
        );
        expect(v.reverse, a.reverse);
      }
      expect(
        notes.map((e) => e.targetMidiNote).toSet(),
        midiScoreNotes.expand((p) => p).map((n) => n[2].toDouble()).toSet(),
      );
    },
  );
  test('scenes change at sound boundaries and never hide an active source', () {
    final result = arrange(
      clips: [for (var i = 0; i < 6; i++) clip('$i')],
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.hop,
      seed: 3,
    );
    final recipe = VideoRecipe.fromArrangement(
      arrangement: result,
      layout: VideoLayout.buildUp,
    );
    expect(recipe.effects.enabled, contains('beatPunch'));
    expect(
      recipe.events.any((e) => e.destinationStartSample % 90000 != 0),
      isTrue,
    );
    for (final scene in recipe.events) {
      final active = result.events
          .where(
            (e) =>
                e.destinationStartSample <= scene.destinationStartSample &&
                e.destinationStartSample + e.durationSamples >
                    scene.destinationStartSample,
          )
          .map((e) => e.assetId)
          .toSet();
      if (active.isNotEmpty) expect(scene.assetIds.toSet(), active);
    }
    expect(recipe.events.last.destinationEndSample, 720000);
    expect(VideoRecipe.fromJson(recipe.toJson()).toJson(), recipe.toJson());
  });
  test('one incidental source can become a complete arrangement', () {
    final result = arrange(
      clips: [clip('solo')],
      style: ArrangementStyle.swaying,
      melodyTemplate: MelodyTemplate.answer,
      seed: 1,
    );
    expect(result.events.any((e) => e.targetMidiNote != null), isTrue);
    expect(
      VideoRecipe.fromArrangement(
        arrangement: result,
        layout: VideoLayout.buildUp,
      ).events,
      isNotEmpty,
    );
  });
}
