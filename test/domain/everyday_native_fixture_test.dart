import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/video_recipe.dart';

// Produce the REAL Dart timeline for the native renderer regression, not a
// manually maintained approximation of what the app sends over the channel.
void main() {
  test('export cross-language MAD renderer fixture from real arranger', () {
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
    final arrangement = arrange(
      clips: clips,
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.answer,
      seed: 5,
    );
    final recipe = VideoRecipe.fromArrangement(
      arrangement: arrangement,
      layout: VideoLayout.buildUp,
    );
    final payload = {
      'schemaVersion': 1,
      'operationId': 'everyday-mad-fixture',
      'projectId': 'review',
      'revision': 1,
      'quality': 'preview',
      'arrangement': arrangement.toJson(),
      'video': recipe.toJson(),
    };
    Directory('ci-artifacts').createSync(recursive: true);
    File('ci-artifacts/everyday-mad-request.json')
        .writeAsStringSync(jsonEncode(payload));
    expect(arrangement.events.any((e) => e.reverse), isTrue);
    expect(arrangement.events.any((e) => e.durationSamples > 48000), isTrue);
  });
}
