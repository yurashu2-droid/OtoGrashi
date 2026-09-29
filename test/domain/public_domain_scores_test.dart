import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/public_domain_scores.dart';

void main() {
  final songs = MelodyTemplate.values
      .where((value) => value.scoreId != null)
      .toList();

  test('every public-domain song has melody, bass and keys in 32 beats', () {
    expect(songs, hasLength(6));
    expect(publicDomainScores.keys.toSet(), songs.map((s) => s.scoreId).toSet());
    for (final song in songs) {
      final lanes = song.scoreNotes;
      expect(lanes, hasLength(3), reason: song.name);
      for (final lane in lanes) {
        expect(lane, isNotEmpty, reason: song.name);
        for (final note in lane) {
          expect(note[0], greaterThanOrEqualTo(0));
          expect(note[1], greaterThan(0));
          expect(note[0] + note[1], lessThanOrEqualTo(15360));
          expect(note[2], inInclusiveRange(0, 127));
        }
      }
      expect(song.isMidiScore, isTrue);
      expect(song.label, isNotEmpty);
    }
    expect(MelodyTemplate.midiScore.scoreNotes, isNot(same(songs.first.scoreNotes)));
  });

  test('each song plays its own melody from the recordings, natural and MAD', () {
    final clips = [
      _clip('low', 49, SuggestedRole.sustain),
      _clip('high', 70, SuggestedRole.sustain),
      _clip('keys', 58, SuggestedRole.texture),
      _clip('tap', null, SuggestedRole.transient),
    ];
    final natural = <String, Object?>{};
    for (final song in songs) {
      final result = arrange(
        clips: clips,
        style: ArrangementStyle.sparse,
        melodyTemplate: song,
        seed: 4,
      );
      expect(result.templateId, contains(song.scoreId!));
      expect(result.melodyTemplate, song);
      expect(Arrangement.fromJson(result.toJson()).toJson(), result.toJson());
      natural[song.name] = result.toJson()['events'];

      final mad = arrange(
        clips: clips,
        style: ArrangementStyle.lively,
        melodyTemplate: song,
        performanceMode: PerformanceMode.mad,
        seed: 4,
      );
      expect(mad.events, isNotEmpty, reason: song.name);
      expect(
        mad.events.map((e) => e.assetId).toSet().difference(
          clips.map((c) => c.assetId).toSet(),
        ),
        isEmpty,
      );
    }
    // different scores give different songs from the same recordings
    expect(natural.values.map((events) => events.toString()).toSet(), hasLength(6));
  });
}

AnalyzedClip _clip(String id, double? pitch, SuggestedRole role) => AnalyzedClip(
  assetId: id,
  durationSamples: 96000,
  sampleRate: 48000,
  onsetSamples: const [],
  audibleRegions: const [AudibleRegion(startSample: 12000, durationSamples: 48000)],
  peak: 0.6,
  rms: 0.2,
  suggestedRole: role,
  fundamentalMidiNote: pitch,
);
