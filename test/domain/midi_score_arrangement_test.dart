import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/midi_score_data.dart';

void main() {
  test('bundled score preserves all three MIDI parts in eight bars', () {
    expect(midiScoreNotes.map((part) => part.length), [76, 32, 40]);
    expect(midiScoreNotes[0].first, [0, 110, 65]);
    expect(midiScoreNotes[1].first, [0, 576, 55]);
    expect(midiScoreNotes[2].first, [0, 294, 62]);
    for (final part in midiScoreNotes) {
      expect(
        part.every(
          (note) =>
              note[0] >= 0 &&
              note[1] > 0 &&
              note[0] + note[1] <= 15360 &&
              note[2] >= 0 &&
              note[2] <= 127,
        ),
        isTrue,
      );
    }
  });

  test('MIDI events use recorded sources with synchronized video and bounded pitch', () {
    final clips = [
      _clip('low', 49, SuggestedRole.sustain),
      _clip('high', 70, SuggestedRole.sustain),
      _clip('keys', 58, SuggestedRole.texture),
      _clip('tap', null, SuggestedRole.transient),
      _clip('other', 63, SuggestedRole.sustain),
      _clip('room', null, SuggestedRole.texture),
    ];
    final result = arrange(
      clips: clips,
      style: ArrangementStyle.sparse,
      melodyTemplate: MelodyTemplate.midiScore,
      seed: 3,
    );
    expect(result.templateId, 'score-image-3part-128bpm-8bar');
    expect(
      result.events.where((e) => e.treatment == SoundTreatment.tuned),
      hasLength(148),
    );
    expect(result.songRoles?.melody, 'high');
    expect(result.songRoles?.bass, 'low');
    expect(
      result.events.map((event) => event.assetId).toSet(),
      clips.map((clip) => clip.assetId).toSet(),
    );
    expect(
      result.toJson(),
      arrange(
        clips: clips,
        style: ArrangementStyle.sparse,
        melodyTemplate: MelodyTemplate.midiScore,
        seed: 3,
      ).toJson(),
    );
    for (var i = 0; i < result.events.length; i++) {
      final audio = result.events[i];
      final video = result.videoEvents[i];
      final clip = clips.singleWhere((value) => value.assetId == audio.assetId);
      expect(audio.destinationStartSample, video.destinationStartSample);
      expect(audio.durationSamples, video.durationSamples);
      expect(
        video.sourceVideoStartTime,
        RationalTime(audio.sourceStartSample, 48000),
      );
      expect(
        audio.sourceStartSample,
        greaterThanOrEqualTo(clip.sourceStartSample),
      );
      expect(
        audio.sourceStartSample + audio.effectiveSourceDurationSamples,
        lessThanOrEqualTo(clip.sourceStartSample + clip.durationSamples),
      );
      expect(audio.pitchSemitones.abs(), lessThanOrEqualTo(12));
      if (clip.fundamentalMidiNote == null) expect(audio.pitchSemitones, 0);
    }
    expect(Arrangement.fromJson(result.toJson()).toJson(), result.toJson());
  });

  test(
    'short audible region sustains scored notes without moving their onset',
    () {
      final clips = [
        _clip('a', 60, SuggestedRole.sustain, regionLength: 4000),
        _clip('b', 55, SuggestedRole.sustain, regionLength: 4000),
        _clip('c', null, SuggestedRole.texture, regionLength: 4000),
      ];
      final result = arrange(
        clips: clips,
        style: ArrangementStyle.lively,
        melodyTemplate: MelodyTemplate.midiScore,
        seed: 9,
      );
      expect(
        result.events.where((e) => e.treatment == SoundTreatment.tuned),
        hasLength(148),
      );
      expect(
        result.events.every(
          (event) => event.effectiveSourceDurationSamples <= 4000,
        ),
        isTrue,
      );
      expect(
        result.events
            .where(
              (event) =>
                  event.destinationStartSample == 0 &&
                  event.treatment == SoundTreatment.tuned,
            )
            .length,
        3,
      );
    },
  );
}

AnalyzedClip _clip(
  String id,
  double? pitch,
  SuggestedRole role, {
  int regionLength = 48000,
}) => AnalyzedClip(
  assetId: id,
  durationSamples: 96000,
  sampleRate: 48000,
  onsetSamples: const [],
  audibleRegions: [
    AudibleRegion(startSample: 12000, durationSamples: regionLength),
  ],
  peak: 0.6,
  rms: 0.2,
  suggestedRole: role,
  fundamentalMidiNote: pitch,
);
