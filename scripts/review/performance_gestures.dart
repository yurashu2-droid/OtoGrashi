// Command-line review tool: it reports on stdout.
// ignore_for_file: avoid_print

import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';

void check(bool value, String why) {
  if (!value) throw StateError(why);
}

void main() {
  final clip = AnalyzedClip(
    assetId: 'speech',
    sourceStartSample: 12000,
    durationSamples: 216000,
    sampleRate: 48000,
    onsetSamples: [12000],
    peak: .8,
    rms: .2,
    suggestedRole: SuggestedRole.sustain,
    fundamentalMidiNote: 57,
    registerMidiNote: 57,
    audibleRegions: [
      AudibleRegion(startSample: 12000, durationSamples: 216000),
    ],
  );
  var checks = 0;
  for (final mode in PerformanceMode.values) {
    for (final seconds in [15, 30]) {
      final rhythm = arrange(
        clips: [clip],
        style: ArrangementStyle.lively,
        seed: 7,
        melodyTemplate: MelodyTemplate.none,
        performanceMode: mode,
        durationSeconds: seconds,
      );
      check(
        rhythm.events.every(
          (e) =>
              e.targetMidiNote == null &&
              e.pitchSteps.isEmpty &&
              e.pitchSemitones == 0,
        ),
        'rhythm-only must remain unpitched',
      );
      checks++;
      // MAD places its own stutters by song structure, not on these cues.
      if (mode == PerformanceMode.natural ||
          mode == PerformanceMode.loopStation ||
          mode == PerformanceMode.mad) {
        continue;
      }
      final a = arrange(
        clips: [clip],
        style: ArrangementStyle.lively,
        seed: 7,
        melodyTemplate: MelodyTemplate.hop,
        performanceMode: mode,
        durationSeconds: seconds,
      );
      for (var section = 0; section < seconds ~/ 15; section++) {
        for (final cue in [247500, 540000]) {
          final start = section * 720000 + cue;
          final head = a.events.singleWhere(
            (e) =>
                e.destinationStartSample == start &&
                    (e.gain - .39 * .72).abs() < 1e-8 ||
                e.destinationStartSample == start &&
                    (e.gain - .39).abs() < 1e-8,
          );
          final phrase = a.events.singleWhere(
            (e) =>
                e.destinationStartSample == start + 16875 &&
                e.treatment == SoundTreatment.phrase,
          );
          check(
            head.sourceStartSample == phrase.sourceStartSample,
            'stutter must introduce the same phrase',
          );
          checks++;
          for (var i = 0; i < 2; i++) {
            final at =
                phrase.destinationStartSample +
                phrase.durationSamples +
                i * 11250;
            final tail = a.events
                .where(
                  (e) =>
                      e.destinationStartSample == at &&
                      e.treatment == SoundTreatment.rhythm,
                )
                .firstWhere(
                  (e) =>
                      e.sourceStartSample + e.effectiveSourceDurationSamples ==
                      phrase.sourceStartSample +
                          phrase.effectiveSourceDurationSamples,
                );
            check(
              tail.sourceStartSample >= phrase.sourceStartSample &&
                  tail.sourceStartSample +
                          tail.effectiveSourceDurationSamples ==
                      phrase.sourceStartSample +
                          phrase.effectiveSourceDurationSamples,
              'tail must echo the phrase just heard, not a later part of the video',
            );
            checks++;
          }
        }
      }
    }
  }
  print(
    'PASS $checks gesture checks: original/reveal/tail alignment and rhythm-only behavior',
  );
}
