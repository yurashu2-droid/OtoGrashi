import 'dart:math' as math;

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

  test('whatever score arrives, every form can still make a song', () {
    // a posted song is only as careful as the client that posted it
    final random = math.Random(20261014);
    List<List<int>> lane(int notes, int low, int high, int longest) => [
      for (var i = 0; i < notes; i++)
        [
          random.nextInt(scoreTicks + 2000) - 500,
          random.nextInt(longest) - 20,
          low + random.nextInt(high - low + 1),
        ],
    ];
    // one voice, the usual mix, and a full set that includes plain noises
    final casts = [
      [_clip('solo', 62, SuggestedRole.sustain)],
      clips,
      [
        ...clips,
        _clip('clap', null, SuggestedRole.transient),
        _clip('hiss', null, SuggestedRole.texture),
      ],
    ];
    for (var round = 0; round < 60; round++) {
      final score = [
        lane(1 + random.nextInt(round.isEven ? 60 : 700), 0, 127, 2400),
        if (random.nextInt(4) > 0) lane(random.nextInt(400), 0, 127, 4000),
        if (random.nextInt(4) > 0) lane(random.nextInt(900), 0, 127, 4000),
      ];
      if (fitScore(score).first.isEmpty) continue;
      for (final (mode, seconds) in const [
        (PerformanceMode.natural, 15),
        (PerformanceMode.mad, 15),
        (PerformanceMode.mad, 30),
        (PerformanceMode.collect, 30),
        (PerformanceMode.window, 30),
        (PerformanceMode.vinyl, 30),
      ]) {
        final song = arrange(
          clips: casts[round % casts.length],
          style: ArrangementStyle.values[round % 3],
          melodyTemplate: MelodyTemplate.imported,
          performanceMode: mode,
          durationSeconds: seconds,
          seed: round,
          score: score,
        );
        expect(
          song.events.length,
          lessThanOrEqualTo(Arrangement.maxEvents),
          reason: 'round $round ${mode.name} $seconds',
        );
      }
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
    // the bass plays one note at a time: of six that start together, the lowest
    expect(fitted[1], [
      [0, 1920, 36],
    ]);
    expect(fitted[2], isEmpty);

    // the melody too: the highest of a chord, and a note stops for the next
    expect(
      fitScore([
        [
          [0, 480, 60],
          [0, 480, 67],
          [480, 960, 62],
          [960, 480, 72],
          [1440, 10, 60], // too short to place
          [1440, 480, 108], // five octaves above the rest
        ],
      ])[0],
      [
        [0, 480, 67],
        [480, 480, 62],
        [960, 480, 72],
        [1440, 480, 96],
      ],
    );

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
    expect(long[0], hasLength(96));

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
