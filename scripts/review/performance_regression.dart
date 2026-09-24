import 'dart:convert';
import 'dart:io';

import '../../lib/domain/arrangement.dart';
import '../../lib/domain/arrangement_engine.dart';
import '../../lib/domain/video_recipe.dart';
import '../../lib/domain/melody_template.dart';

void check(bool pass, String message) {
  if (!pass) throw StateError(message);
}

void main() {
  var checks = 0;
  for (final count in [1, 2, 3, 6]) {
    final clips = List.generate(
      count,
      (i) => AnalyzedClip(
        assetId: 'clip-$i',
        sourceStartSample: 4800,
        durationSamples: 216000,
        sampleRate: 48000,
        onsetSamples: [9600],
        peak: .8,
        rms: .2,
        suggestedRole: i == 0 ? SuggestedRole.transient : SuggestedRole.sustain,
        fundamentalMidiNote: i.isEven ? null : 55.0 + i,
        audibleRegions: const [
          AudibleRegion(startSample: 4800, durationSamples: 48000),
          AudibleRegion(startSample: 72000, durationSamples: 96000),
        ],
      ),
    );
    for (final mode in PerformanceMode.values) {
      for (final seconds in [15, 30]) {
        final a = arrange(
          clips: clips,
          style: ArrangementStyle.lively,
          seed: 12,
          melodyTemplate: MelodyTemplate.hop,
          performanceMode: mode,
          durationSeconds: seconds,
        );
        final b = Arrangement.fromJson(a.toJson());
        check(
          b.totalSamples == seconds * 48000 && b.performanceMode == mode,
          'clock/mode roundtrip',
        );
        check(a.events.length <= Arrangement.maxEvents, 'event limit');
        check(
          a.events.any((e) => e.durationSamples >= 22500),
          'preserve long voice',
        );
        for (final e in a.events) {
          final clip = clips.singleWhere((c) => c.assetId == e.assetId);
          check(
            e.sourceStartSample >= clip.sourceStartSample &&
                e.sourceStartSample + e.effectiveSourceDurationSamples <=
                    clip.sourceStartSample + clip.durationSamples,
            'source trim',
          );
          check(
            e.destinationStartSample + e.durationSamples <= a.totalSamples,
            'destination',
          );
        }
        final v = VideoRecipe.fromArrangement(
          arrangement: a,
          layout: VideoLayout.buildUp,
        );
        check(
          VideoRecipe.fromJson(v.toJson()).events.last.destinationEndSample ==
              a.totalSamples,
          'video duration',
        );
        for (var t = 0; t < a.totalSamples; t += 1600) {
          final live = a.events
              .where(
                (e) =>
                    e.destinationStartSample <= t &&
                    t < e.destinationStartSample + e.durationSamples,
              )
              .map((e) => e.assetId)
              .toSet();
          final scene = v.events.singleWhere(
            (e) => e.destinationStartSample <= t && t < e.destinationEndSample,
          );
          check(live.every(scene.assetIds.contains), 'live source hidden');
        }
        if (count <= 2 && mode != PerformanceMode.natural) {
          check(
            a.events.map((e) => e.partIndex).toSet().length >= 2,
            'different moments as parts',
          );
        }
        if (mode == PerformanceMode.vinyl)
          check(a.events.any((e) => e.reverse), 'scratch reversal');
        if (seconds == 30)
          check(
            a.events.any((e) => e.destinationStartSample >= 720000),
            '30s second section',
          );
        checks++;
        if (count == 3) {
          Directory('ci-artifacts').createSync(recursive: true);
          File('ci-artifacts/performance-${mode.name}-$seconds.json')
              .writeAsStringSync(
                jsonEncode({
                  'schemaVersion': 1,
                  'operationId': 'performance-${mode.name}-$seconds',
                  'projectId': 'performance',
                  'revision': 1,
                  'quality': 'preview',
                  'arrangement': a.toJson(),
                  'video': v.toJson(),
                }),
              );
        }
      }
    }
  }
  exportNativeFixtures();
  print(
    'PASS $checks arrangements, clocks, source bounds, modes, video frame coverage',
  );
}

void exportNativeFixtures() {
  final clips = [
    AnalyzedClip(
      assetId: 'tap',
      durationSamples: 48000,
      sampleRate: 48000,
      onsetSamples: const [12000],
      audibleRegions: const [
        AudibleRegion(startSample: 11520, durationSamples: 9600),
      ],
      peak: .8,
      rms: .2,
      suggestedRole: SuggestedRole.transient,
    ),
    AnalyzedClip(
      assetId: 'sustain',
      durationSamples: 48000,
      sampleRate: 48000,
      onsetSamples: const [0],
      audibleRegions: const [
        AudibleRegion(startSample: 0, durationSamples: 47520),
      ],
      peak: .6,
      rms: .2,
      suggestedRole: SuggestedRole.sustain,
      fundamentalMidiNote: 57,
    ),
    AnalyzedClip(
      assetId: 'texture',
      durationSamples: 72000,
      sampleRate: 48000,
      onsetSamples: const [0],
      audibleRegions: const [
        AudibleRegion(startSample: 0, durationSamples: 71520),
      ],
      peak: .5,
      rms: .2,
      suggestedRole: SuggestedRole.texture,
    ),
  ];
  for (final mode in PerformanceMode.values.where(
    (v) => v != PerformanceMode.natural,
  )) {
    final seconds = mode == PerformanceMode.sampler ? 30 : 15;
    final a = arrange(
      clips: clips,
      style: ArrangementStyle.lively,
      seed: 8,
      melodyTemplate: MelodyTemplate.hop,
      performanceMode: mode,
      durationSeconds: seconds,
    );
    final v = VideoRecipe.fromArrangement(
      arrangement: a,
      layout: VideoLayout.buildUp,
    );
    File('ci-artifacts/native-${mode.name}.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'operationId': 'native-${mode.name}',
        'projectId': 'native',
        'revision': 1,
        'quality': 'preview',
        'arrangement': a.toJson(),
        'video': v.toJson(),
      }),
    );
  }
}
