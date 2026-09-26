// Command-line review tool: it reports on stdout.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';

void main() {
  var count = 0;
  var failures = 0;
  for (final length in [240, 2400, 4000, 48000, 216000]) {
    for (final register in [24.0, 57.0, 100.0]) {
      for (final seconds in [15, 30]) {
        for (final mode in PerformanceMode.values) {
          for (final melody in MelodyTemplate.values) {
            for (final style in ArrangementStyle.values) {
              for (final seed in [-7, 0]) {
                final clips = [
                  AnalyzedClip(
                    assetId: 'v',
                    durationSamples: length,
                    sourceStartSample: 4800,
                    sampleRate: 48000,
                    onsetSamples: const [],
                    audibleRegions: [
                      AudibleRegion(startSample: 4800, durationSamples: length),
                    ],
                    peak: .5,
                    rms: .2,
                    suggestedRole: SuggestedRole.sustain,
                    registerMidiNote: register,
                  ),
                ];
                try {
                  final a = arrange(
                    clips: clips,
                    style: style,
                    seed: seed,
                    melodyTemplate: melody,
                    performanceMode: mode,
                    durationSeconds: seconds,
                  );
                  for (final e in a.events) {
                    if (e.sourceStartSample < 4800 ||
                        e.sourceStartSample + e.effectiveSourceDurationSamples >
                            4800 + length) {
                      throw StateError('out of selected source');
                    }
                    if (!e.hasValidPitchSteps) {
                      throw StateError('invalid note duration');
                    }
                  }
                  Arrangement.fromJson(a.toJson());
                  count++;
                } catch (e, st) {
                  if (failures++ < 8) {
                    print(
                      'FAIL length=$length register=$register $seconds $mode $melody $style seed=$seed: $e\n${st.toString().split('\n').take(4).join('\n')}',
                    );
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  print('PASS $count edge arrangements; failures=$failures');
  if (failures > 0) exit(1);
}
