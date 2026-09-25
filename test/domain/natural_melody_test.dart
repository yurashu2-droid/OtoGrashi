import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/midi_score_data.dart';

AnalyzedClip _voice(String id, {double? note, int length = 384000}) =>
    AnalyzedClip(
      assetId: id,
      durationSamples: length,
      sampleRate: 48000,
      onsetSamples: const [0],
      audibleRegions: [AudibleRegion(startSample: 0, durationSamples: length)],
      peak: .5,
      rms: .14,
      suggestedRole: SuggestedRole.sustain,
      fundamentalMidiNote: note,
    );

void main() {
  test('a melody moves through speech without restarting at each beat', () {
    final result = arrange(
      clips: [_voice('voice', note: 57)],
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.hop,
      seed: 7,
    );
    final phrases = result.events
        .where((e) => e.pitchSteps.isNotEmpty)
        .toList();
    expect(phrases, isNotEmpty);
    expect(phrases.every((e) => e.durationSamples >= 45000), isTrue);
    expect(phrases.every((e) => e.pitchSteps.length >= 2), isTrue);
    expect(
      phrases
          .expand((e) => e.pitchSteps)
          .every((p) => p.durationSamples >= 22500),
      isTrue,
    );
    for (var i = 1; i < phrases.length; i++) {
      // Eight seconds of input: the first four bars must advance without a wrap.
      if (phrases[i - 1].sourceStartSample +
              phrases[i - 1].durationSamples +
              phrases[i].durationSamples <=
          384000) {
        expect(
          phrases[i].sourceStartSample,
          phrases[i - 1].sourceStartSample + phrases[i - 1].durationSamples,
        );
      }
    }
    for (var i = 0; i < result.events.length; i++) {
      expect(
        result.videoEvents[i].sourceVideoStartTime.numerator,
        result.events[i].sourceStartSample,
      );
      expect(
        result.videoEvents[i].effectiveSourceDurationSamples,
        result.events[i].effectiveSourceDurationSamples,
      );
    }
    expect(Arrangement.fromJson(result.toJson()).toJson(), result.toJson());
  });

  test('short pauses join words into a continuing phrase instead of looping a word', () {
    final voice = AnalyzedClip(
      assetId: 'sentence',
      durationSamples: 144000,
      sampleRate: 48000,
      onsetSamples: const [0, 26400, 55200],
      peak: .5,
      rms: .14,
      suggestedRole: SuggestedRole.sustain,
      registerMidiNote: 48,
      audibleRegions: [
        AudibleRegion(startSample: 55200, durationSamples: 43200),
        AudibleRegion(startSample: 0, durationSamples: 16800),
        AudibleRegion(startSample: 26400, durationSamples: 16800),
      ],
    );
    final result = arrange(
      clips: [voice],
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.hop,
      seed: 0,
    );
    final lead = result.events.where((e) => e.pitchSteps.isNotEmpty).toList();
    expect(lead.first.sourceStartSample, 0);
    expect(lead.first.effectiveSourceDurationSamples, 45000);
    expect(lead[1].sourceStartSample, 45000);
    // Changing speech's register hint is used without inventing a stable F0.
    expect(voice.fundamentalMidiNote, isNull);
    expect(
      lead
          .expand((e) => e.pitchSteps)
          .every((p) => p.midiNote >= 44 && p.midiNote <= 53),
      isTrue,
    );
    expect(AnalyzedClip.fromJson(voice.toJson()).registerMidiNote, 48);
  });

  test('MIDI still has 148 note positions inside its continuous phrases', () {
    final result = arrange(
      clips: [
        _voice('low', note: 49),
        _voice('voice', note: 65),
        _voice('keys', note: 58),
      ],
      style: ArrangementStyle.sparse,
      melodyTemplate: MelodyTemplate.midiScore,
      seed: 3,
    );
    final actual = <String>[];
    for (final e in result.events.where((e) => e.targetMidiNote != null)) {
      final steps = e.pitchSteps.isNotEmpty
          ? e.pitchSteps
          : [
              PitchStep(
                offsetSamples: 0,
                durationSamples: e.durationSamples,
                midiNote: e.targetMidiNote!,
              ),
            ];
      for (final p in steps) {
        actual.add(
          '${e.destinationStartSample + p.offsetSamples}:${p.durationSamples}:${p.midiNote.round() % 12}',
        );
      }
    }
    final expected = midiScoreNotes.expand((lane) => lane).map((n) {
      final start = (n[0] * 720000 / 15360).round();
      final end = ((n[0] + n[1]) * 720000 / 15360).round();
      return '$start:${end - start}:${n[2] % 12}';
    }).toList();
    expect(actual..sort(), expected..sort());
    expect(result.events.any((e) => e.pitchSteps.length > 1), isTrue);
  });

  test('overlapping or out of range pitch automation is rejected', () {
    final original = arrange(
      clips: [_voice('voice', note: 57)],
      style: ArrangementStyle.sparse,
      melodyTemplate: MelodyTemplate.hop,
      seed: 7,
    ).toJson();
    final events = original['events'] as List;
    final event = events.cast<Map<String, Object?>>().firstWhere(
      (e) => e.containsKey('pitchSteps'),
    );
    event['pitchSteps'] = [
      {'offsetSamples': 0, 'durationSamples': 22500, 'midiNote': 57.0},
      {'offsetSamples': 100, 'durationSamples': 22500, 'midiNote': 60.0},
    ];
    expect(
      () => Arrangement.fromJson(original),
      throwsA(isA<MediaContractException>()),
    );
    event['pitchSteps'] = [
      {'offsetSamples': 0, 'durationSamples': 999999, 'midiNote': 57.0},
    ];
    expect(
      () => Arrangement.fromJson(original),
      throwsA(isA<MediaContractException>()),
    );
  });
}
