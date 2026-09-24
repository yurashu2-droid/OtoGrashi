import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';

import '../../scripts/review/performance_regression.dart' as regression;

void main() {
  test(
    '56 mode/length/source-count combinations preserve the source clock',
    regression.main,
  );
  test('rhythm only never silently becomes a melody in performance mode', () {
    final clip = AnalyzedClip(
      assetId: 'voice',
      durationSamples: 96000,
      sampleRate: 48000,
      onsetSamples: const [],
      peak: .8,
      rms: .2,
      suggestedRole: SuggestedRole.sustain,
    );
    for (final mode in PerformanceMode.values) {
      final result = arrange(
        clips: [clip],
        style: ArrangementStyle.lively,
        seed: 1,
        performanceMode: mode,
        durationSeconds: 30,
        melodyTemplate: MelodyTemplate.none,
      );
      expect(
        result.events.every(
          (e) =>
              e.targetMidiNote == null &&
              e.pitchSteps.isEmpty &&
              e.pitchSemitones == 0,
        ),
        isTrue,
      );
    }
  });
}
