import 'dart:math' as math;

import 'arrangement.dart';
import 'everyday_arranger.dart';
import 'melody_template.dart';

/// Add performance gestures to source-preserving phrases. No oscillator or
/// single-cycle resynthesis: the production voice DSP still owns every note.
Arrangement arrangePerformance({
  required List<AnalyzedClip> clips,
  required ArrangementStyle style,
  required int seed,
  required MelodyTemplate melodyTemplate,
  required PerformanceMode mode,
  required int seconds,
}) {
  if (seconds != 15 && seconds != 30) {
    throw const MediaContractException('Choose a 15 or 30 second performance.');
  }
  final total = seconds * 48000;
  final usable = clips.where((c) => c.isUsable).toList();
  // Keep validation, measured voice selection and the original musical motif.
  final base = arrangeEveryday(
    clips: clips,
    style: style,
    seed: seed,
    melodyTemplate: melodyTemplate,
  );
  final roles = base.songRoles!;
  final events = <SoundEvent>[];
  final animated = mode != PerformanceMode.natural;
  final byId = {for (final c in usable) c.assetId: c};
  final lead = byId[roles.melody] ?? usable.first;
  final bass = byId[roles.bass] ?? lead;
  final beat = byId[roles.beat] ?? usable.first;
  final root = ((lead.fundamentalMidiNote?.round() ?? 57) - 3).clamp(45, 76);

  // A part is a bounded passage, not a duplicate asset. Few recordings can
  // supply an attack, a middle word, and a tail; audio/video retain the same ID.
  AudibleRegion part(AnalyzedClip clip, int index) {
    final spans = clip.audibleRegions.toList()
      ..sort((a, b) => a.startSample.compareTo(b.startSample));
    if (spans.isEmpty) {
      spans.add(
        AudibleRegion(
          startSample: clip.sourceStartSample,
          durationSamples: clip.durationSamples,
        ),
      );
    }
    final region = spans[index % spans.length];
    if (spans.length > 1 || region.durationSamples < 36000) return region;
    final length = math.min(
      region.durationSamples,
      math.max(24000, region.durationSamples ~/ 2),
    );
    final start = (region.durationSamples - length) * (index % 3) ~/ 2;
    return AudibleRegion(
      startSample: region.startSample + start,
      durationSamples: length,
    );
  }

  SoundEvent copy(SoundEvent e, Map<String, Object?> changes) {
    final values = {...e.toJson(), ...changes};
    final duration = values['durationSamples'] as int;
    final fades = (values['fades'] as Map).cast<String, Object?>();
    values['fades'] = {
      'fadeInSamples': (fades['fadeInSamples'] as int).clamp(0, duration ~/ 4),
      'fadeOutSamples': (fades['fadeOutSamples'] as int).clamp(
        0,
        duration ~/ 4,
      ),
    };
    return SoundEvent.fromJson(values);
  }

  void hit(
    AnalyzedClip clip,
    int start,
    int duration, {
    int partIndex = 0,
    double gain = .4,
    double? note,
    bool reverse = false,
    SoundTreatment treatment = SoundTreatment.rhythm,
    List<PitchStep> steps = const [],
    bool tail = false,
  }) {
    if (start < 0 || start >= total || duration <= 0) return;
    final span = part(clip, partIndex);
    final size = math.min(duration, total - start);
    final available = math.min(
      span.durationSamples,
      math.max(size, note == null ? size : 14400),
    );
    final from = tail
        ? span.startSample + span.durationSamples - available
        : span.startSample;
    final sounding = treatment == SoundTreatment.phrase
        ? math.min(size, available)
        : size;
    events.add(
      SoundEvent(
        assetId: clip.assetId,
        sourceStartSample: from,
        sourceDurationSamples: available,
        destinationStartSample: start,
        durationSamples: sounding,
        gain: gain,
        targetMidiNote: note,
        reverse: reverse,
        partIndex: partIndex,
        treatment: treatment,
        pitchSteps: steps,
        fades: EventFades(
          fadeInSamples: math.min(96, sounding ~/ 8),
          fadeOutSamples: math.min(240, sounding ~/ 8),
        ),
      ),
    );
  }

  if (mode == PerformanceMode.loopStation) {
    final bars = total ~/ 90000;
    final bassEntry = bars ~/ 4;
    final leadEntry = bars ~/ 2;
    for (var bar = 0; bar < bars; bar++) {
      final start = bar * 90000;
      // Four-on-the-floor, then bass, then a continuous two-beat vocal lead.
      for (var b = 0; b < 4; b++) {
        hit(
          beat,
          start + b * 22500,
          math.min(12000, part(beat, 0).durationSamples),
          gain: .52,
        );
      }
      if (bar >= bassEntry) {
        hit(
          bass,
          start,
          81000,
          partIndex: 1,
          note: (root - 12 + (bar % 4 == 3 ? 5 : 0)).toDouble(),
          treatment: SoundTreatment.tuned,
          gain: .35,
        );
      }
      if (bar >= leadEntry) {
        final notes = [0, 2, 4, 7, 4, 2, 7, 0];
        final n = (root + notes[(bar + seed) % notes.length]).toDouble();
        hit(
          lead,
          start,
          90000,
          partIndex: 2,
          note: n,
          treatment: SoundTreatment.tuned,
          gain: .47,
          steps: [
            PitchStep(offsetSamples: 0, midiNote: n),
            PitchStep(
              offsetSamples: 45000,
              midiNote: (root + notes[(bar + seed + 1) % notes.length])
                  .toDouble(),
            ),
          ],
        );
      }
      if (bar >= bars * 3 ~/ 4 && bar.isOdd) {
        hit(
          usable[(bar ~/ 2) % usable.length],
          start + 22500,
          math.min(96000, total - start - 22500),
          partIndex: 3,
          gain: .64,
          treatment: SoundTreatment.phrase,
        );
      }
    }
  } else {
    for (var segment = 0; segment < seconds ~/ 15; segment++) {
      final arrangement = segment == 0
          ? base
          : arrangeEveryday(
              clips: clips,
              style: ArrangementStyle.lively,
              seed: seed + 3,
              melodyTemplate: melodyTemplate,
            );
      for (final e in arrangement.events) {
        final position = e.destinationStartSample + segment * 720000;
        final patch = <String, Object?>{'destinationStartSample': position};
        if (animated && usable.length <= 2) {
          final index = switch (e.treatment) {
            SoundTreatment.rhythm => 0,
            SoundTreatment.phrase => 3,
            _ => e.assetId == roles.bass && e.pitchSteps.isEmpty ? 1 : 2,
          };
          final span = part(byId[e.assetId]!, index);
          patch.addAll({
            'partIndex': index,
            'sourceStartSample': span.startSample,
            'sourceDurationSamples': math.min(
              span.durationSamples,
              e.effectiveSourceDurationSamples,
            ),
          });
          if (e.treatment == SoundTreatment.phrase) {
            patch['durationSamples'] = math.min(
              e.durationSamples,
              span.durationSamples,
            );
          }
        }
        if (mode == PerformanceMode.voiceLead && e.pitchSteps.isNotEmpty) {
          final span = part(lead, 2);
          patch.addAll({
            'assetId': lead.assetId,
            'partIndex': 2,
            'sourceStartSample': span.startSample,
            'sourceDurationSamples': math.min(90000, span.durationSamples),
            'gain': .34,
          });
        }
        // Only the explicitly chosen tune mode receives faster, hard note changes.
        if (mode == PerformanceMode.neonTune && e.pitchSteps.isNotEmpty) {
          final curve = <Map<String, Object?>>[];
          for (var t = 0; t < e.durationSamples; t += 11250) {
            curve.add(
              PitchStep(
                offsetSamples: t,
                midiNote: (root + [0, 7, 4, 12][(t ~/ 11250) % 4]).toDouble(),
              ).toJson(),
            );
          }
          patch['pitchSteps'] = curve;
        }
        // A second half is a variation, not a time-stretched copy: denser
        // response, changed motif, and a brief stop before the closing hook.
        if (animated &&
            segment == 1 &&
            position >= 1327500 &&
            position < 1350000 &&
            e.treatment == SoundTreatment.rhythm)
          continue;
        events.add(copy(e, patch));
      }
    }
  }

  if (animated && mode != PerformanceMode.loopStation) {
    for (var section = 0; section < seconds ~/ 15; section++) {
      for (var cue = 0; cue < 2; cue++) {
        final clip = usable[(cue + section + seed.abs()) % usable.length];
        final start = section * 720000 + (cue == 0 ? 247500 : 540000);
        final span = part(clip, 0);
        final syllable = math.min(5625, span.durationSamples);
        // 'a-a-a-arigatou ... tou ... tou': acoustic head/full/tail selection,
        // not speech recognition or a claim that the app understands words.
        for (var r = 0; r < 3; r++) {
          hit(clip, start + r * 5625, syllable, gain: .39 + r * .05);
        }
        final phraseStart = start + 16875;
        final phraseLength = math.min(67500, span.durationSamples);
        // Avoid an overlapping unmodified phrase being doubled by this reveal.
        events.removeWhere(
          (e) =>
              e.treatment == SoundTreatment.phrase &&
              e.destinationStartSample < phraseStart + phraseLength &&
              e.destinationStartSample + e.durationSamples > start,
        );
        hit(
          clip,
          phraseStart,
          phraseLength,
          gain: .69,
          treatment: SoundTreatment.phrase,
        );
        for (var r = 0; r < 2; r++) {
          hit(
            clip,
            phraseStart + phraseLength + r * 11250,
            math.min(11250, span.durationSamples),
            gain: r == 0 ? .31 : .20,
            tail: true,
          );
        }
      }
    }
  }
  if (mode == PerformanceMode.vinyl) {
    for (var group = 0; group < seconds ~/ 5; group++) {
      final clip = usable[group % usable.length];
      final start = group * 240000 + 180000;
      final sourceNote = clip.fundamentalMidiNote ?? 57;
      for (var step = 0; step < 4; step++) {
        hit(
          clip,
          start + step * 11250,
          11250,
          partIndex: 1,
          gain: .46,
          reverse: step.isOdd,
          note: sourceNote,
          steps: [
            PitchStep(
              offsetSamples: 0,
              midiNote: sourceNote + (step.isOdd ? 7 : -5),
            ),
            PitchStep(
              offsetSamples: 5625,
              midiNote: sourceNote + (step.isOdd ? -5 : 7),
            ),
          ],
        );
      }
    }
  }
  if (mode == PerformanceMode.voiceLead) {
    // Recognizable long reactions in front of one recurrent melody source.
    for (var at = 90000, i = 0; at < total - 45000; at += 180000, i++) {
      final clip = usable[(i + 1) % usable.length];
      hit(
        clip,
        at,
        math.min(108000, part(clip, 3).durationSamples),
        partIndex: 3,
        gain: .67,
        treatment: SoundTreatment.phrase,
      );
    }
  }

  final phrases = events
      .where((e) => e.treatment == SoundTreatment.phrase)
      .toList();
  // Ducking is conservative; do not erase a long backing note merely because
  // a phrase overlaps it. Speech takes the foreground without removing rhythm.
  final ordered = events.indexed.toList()
    ..sort((a, b) {
      final d = a.$2.destinationStartSample.compareTo(
        b.$2.destinationStartSample,
      );
      return d == 0 ? a.$1.compareTo(b.$1) : d;
    });
  final sound = <SoundEvent>[];
  final video = <VideoEvent>[];
  for (final entry in ordered) {
    var e = entry.$2;
    if (melodyTemplate == MelodyTemplate.none) {
      e = copy(e, {
        'targetMidiNote': null,
        'pitchSteps': <Object?>[],
        'pitchSemitones': 0.0,
      });
    }
    if (animated &&
        e.treatment != SoundTreatment.phrase &&
        phrases.any(
          (p) =>
              p.destinationStartSample <
                  e.destinationStartSample + e.durationSamples &&
              p.destinationStartSample + p.durationSamples >
                  e.destinationStartSample,
        )) {
      e = copy(e, {'gain': e.gain * .72});
    }
    sound.add(e);
    video.add(
      VideoEvent(
        assetId: e.assetId,
        destinationStartSample: e.destinationStartSample,
        durationSamples: e.durationSamples,
        sourceVideoStartTime: RationalTime(e.sourceStartSample, 48000),
        sourceDurationSamples: e.sourceDurationSamples,
        crop: NormalizedCrop.fullFrame,
        loopMode: e.durationSamples > e.effectiveSourceDurationSamples
            ? VideoLoopMode.loop
            : VideoLoopMode.once,
        reverse: e.reverse,
        mirror: animated && entry.$1.isOdd,
        partIndex: e.partIndex,
      ),
    );
  }
  return Arrangement(
    templateId: 'performance-${mode.name}-$seconds-${melodyTemplate.name}',
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: seed,
    style: style,
    melodyTemplate: melodyTemplate,
    songRoles: roles,
    sourceAssetIds: base.sourceAssetIds,
    unusableAssetIds: base.unusableAssetIds,
    events: sound,
    videoEvents: video,
    totalSamples: total,
    performanceMode: mode,
  );
}
