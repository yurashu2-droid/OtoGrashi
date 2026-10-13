import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/public_domain_scores.dart';

void main() {
  final clips = [
    _clip('low', 49, SuggestedRole.sustain),
    _clip('high', 70, SuggestedRole.sustain),
    _clip('keys', 58, SuggestedRole.texture),
    _clip('tap', null, SuggestedRole.transient),
  ];

  List<Object?> played(Arrangement arrangement) => [
    for (final event in arrangement.events)
      [
        event.assetId,
        event.destinationStartSample,
        event.durationSamples,
        event.targetMidiNote,
      ],
  ];

  test('an imported score plays exactly like the same score bundled', () {
    final score = publicDomainScores['twinkle_twinkle']!;
    for (final (mode, seconds) in const [
      (PerformanceMode.natural, 15),
      (PerformanceMode.mad, 15),
      (PerformanceMode.mad, 30),
      (PerformanceMode.collect, 15),
      (PerformanceMode.vinyl, 30),
    ]) {
      Arrangement make(MelodyTemplate melody, List<List<List<int>>>? notes) =>
          arrange(
            clips: clips,
            style: ArrangementStyle.sparse,
            melodyTemplate: melody,
            performanceMode: mode,
            durationSeconds: seconds,
            seed: 4,
            score: notes,
          );
      final bundled = make(MelodyTemplate.twinkle, null);
      final imported = make(MelodyTemplate.imported, score);
      expect(played(imported), played(bundled), reason: '${mode.name} $seconds');
      expect(imported.melodyTemplate, MelodyTemplate.imported);
      expect(
        Arrangement.fromJson(imported.toJson()).toJson(),
        imported.toJson(),
      );
    }
  });

  test('a score is ignored unless the song is one that plays a score', () {
    final score = publicDomainScores['twinkle_twinkle']!;
    Arrangement make(List<List<List<int>>>? notes) => arrange(
      clips: clips,
      style: ArrangementStyle.sparse,
      melodyTemplate: MelodyTemplate.hop,
      seed: 4,
      score: notes,
    );
    expect(played(make(score)), played(make(null)));
  });

  test('a melody alone is enough for a song', () {
    final melody = publicDomainScores['ode_to_joy']!.first;
    for (final mode in const [
      PerformanceMode.natural,
      PerformanceMode.mad,
      PerformanceMode.window,
    ]) {
      final song = arrange(
        clips: clips,
        style: ArrangementStyle.lively,
        melodyTemplate: MelodyTemplate.imported,
        performanceMode: mode,
        seed: 9,
        score: [melody],
      );
      expect(song.events, isNotEmpty, reason: mode.name);
      expect(song.events.length, lessThanOrEqualTo(Arrangement.maxEvents));
    }
  });

  test('a score from outside is fitted to eight bars and three lanes', () {
    final fitted = fitScore([
      [
        [480, 480, 64],
        [0, 480, 60],
        [15000, 960, 67], // runs past the end of bar 8
        [15360, 240, 72], // starts after the end
        [-10, 240, 60],
        [960, 0, 60],
        [960, 240, 200],
        [1, 2],
      ],
      [
        for (var i = 0; i < 6; i++) [0, 1920, 36 + i],
      ],
    ]);
    expect(fitted, hasLength(3));
    expect(fitted[0], [
      [0, 480, 60],
      [480, 480, 64],
      [15000, 360, 67],
    ]);
    // only the chords lane limits how many notes sound together
    expect(fitted[1], hasLength(6));
    expect(fitted[2], isEmpty);

    final chords = fitScore([
      [
        [0, 480, 60],
      ],
      const [],
      [
        for (var i = 0; i < 6; i++) [0, 1920, 48 + i],
        [1920, 1920, 50],
      ],
    ])[2];
    expect(chords.map((note) => note[2]), [48, 49, 50, 51, 50]);

    final long = fitScore([
      [
        for (var i = 0; i < 400; i++) [i * 30, 30, 60],
      ],
    ]);
    expect(long[0], hasLength(128));

    // the bundled songs pass through unchanged
    for (final score in publicDomainScores.values) {
      expect(fitScore(score), score);
    }
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
