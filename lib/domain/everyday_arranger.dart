import 'dart:math' as math;

import 'arrangement.dart';
import 'melody_template.dart';
import 'midi_score_data.dart';

/// Turn recordings into instruments AND keep the people behind those sounds.
/// SuggestedRole/pitch are hints, never gates that discard voices or noises.
Arrangement arrangeEveryday({
  required List<AnalyzedClip> clips,
  required ArrangementStyle style,
  required int seed,
  required MelodyTemplate melodyTemplate,
}) {
  if (clips.isEmpty) {
    throw const ArrangementRejected(
      reason: ArrangementRejectionReason.noSources,
      assetIds: [],
    );
  }
  if (clips.length > 6 ||
      clips.map((c) => c.assetId).toSet().length != clips.length) {
    throw const MediaContractException(
      'Arrangement requires 1 to 6 unique sources.',
    );
  }
  final usable = clips.where((c) => c.isUsable).toList();
  if (usable.isEmpty) {
    throw ArrangementRejected(
      reason: ArrangementRejectionReason.allSilent,
      assetIds: clips.map((c) => c.assetId).toList(),
    );
  }
  final byLength = usable.toList()
    ..sort((a, b) {
      final order = _longest(b).compareTo(_longest(a));
      return order != 0 ? order : a.assetId.compareTo(b.assetId);
    });
  final measured = usable.where((c) => c.fundamentalMidiNote != null).toList()
    ..sort((a, b) => a.fundamentalMidiNote!.compareTo(b.fundamentalMidiNote!));
  final beat =
      usable
          .where((c) => c.suggestedRole == SuggestedRole.transient)
          .firstOrNull ??
      byLength.last;
  final melody = measured.lastOrNull ?? byLength.first;
  final bass =
      measured.firstOrNull ??
      byLength.where((c) => c.assetId != melody.assetId).firstOrNull ??
      melody;
  final candidates = usable
      .where((c) => c.assetId != bass.assetId && c.assetId != melody.assetId)
      .toList();
  final keys =
      candidates.where((c) => c.assetId != beat.assetId).firstOrNull ??
      candidates.firstOrNull ??
      beat;
  final roles = SongRoles(
    beat: beat.assetId,
    bass: bass.assetId,
    keys: keys.assetId,
    melody: melody.assetId,
  );
  final events = <SoundEvent>[];
  final mirror = <SoundEvent, bool>{};
  var serial = 0;

  void add(
    AnalyzedClip clip,
    int start,
    int wanted, {
    double? note,
    double gain = .48,
    SoundTreatment treatment = SoundTreatment.tuned,
    bool reverse = false,
    int variation = 0,
    bool flip = false,
  }) {
    if (start >= 720000 || wanted <= 0) return;
    final region = _window(
      clip,
      phrase: treatment == SoundTreatment.phrase,
      variation: variation,
    );
    final available = region.durationSamples;
    final desired = math.min(wanted, 720000 - start);
    final duration = treatment == SoundTreatment.phrase
        ? math.min(desired, available)
        : desired;
    // Tuned one-shots can hold a note, but always loop inside the selected
    // source range. Long natural phrases are never squeezed into note slots.
    final sourceDuration = math.min(available, duration);
    final fadeIn = math.min(
      treatment == SoundTreatment.phrase ? 240 : 72,
      duration ~/ 4,
    );
    final fadeOut = math.min(
      treatment == SoundTreatment.phrase ? 480 : 240,
      duration ~/ 4,
    );
    final event = SoundEvent(
      assetId: clip.assetId,
      sourceStartSample: region.startSample,
      sourceDurationSamples: sourceDuration,
      destinationStartSample: start,
      durationSamples: duration,
      gain: gain,
      fades: EventFades(fadeInSamples: fadeIn, fadeOutSamples: fadeOut),
      targetMidiNote: note,
      reverse: reverse,
      treatment: treatment,
    );
    events.add(event);
    mirror[event] = flip || (note != null && serial.isOdd);
    serial++;
  }

  final midi = melodyTemplate == MelodyTemplate.midiScore;
  // Acoustic phrase spotlights, not speech recognition. Give EVERY recording
  // an identifiable, natural-speed moment even when it has no measurable F0.
  final slot = 720000 ~/ usable.length;
  for (var i = 0; i < usable.length; i++) {
    add(
      usable[i],
      i * slot,
      math.min(midi ? 60000 : 108000, slot - 2400),
      gain: .68,
      treatment: SoundTreatment.phrase,
    );
  }

  if (midi) {
    final leads = [melody, bass, keys];
    final lanes = <List<AnalyzedClip>>[
      [melody],
      [bass],
      [keys],
    ];
    for (final clip in usable) {
      if (leads.any((c) => c.assetId == clip.assetId)) continue;
      final lane = clip.suggestedRole == SuggestedRole.transient
          ? 2
          : (clip.fundamentalMidiNote ?? 64) < 60
          ? 1
          : 0;
      lanes[lane].add(clip);
    }
    for (var lane = 0; lane < 3; lane++) {
      final notes = midiScoreNotes[lane];
      for (var index = 0; index < notes.length; index++) {
        final note = notes[index];
        final start = (note[0] * 720000 / 15360).round();
        final end = ((note[0] + note[1]) * 720000 / 15360).round();
        add(
          lanes[lane][index % lanes[lane].length],
          start,
          end - start,
          note: note[2].toDouble(),
          gain: lane == 0 ? .55 : .38,
          variation: index ~/ 8,
        );
      }
    }
  } else {
    final root = (melody.fundamentalMidiNote?.round() ?? 60).clamp(60, 72);
    final motif = switch (melodyTemplate) {
      MelodyTemplate.wink => const [0, 7, 4, 9, 7, 2, 4, 0],
      MelodyTemplate.answer => const [0, 0, 4, 7, 2, 2, 7, 4],
      _ => const [0, 2, 4, 7, 9, 7, 4, 2],
    };
    final density = switch (style) {
      ArrangementStyle.sparse => 2,
      ArrangementStyle.swaying => 3,
      ArrangementStyle.lively => 4,
    };
    // A single early pulse makes the transformation apparent immediately.
    add(beat, 22500, 9000, gain: .52, treatment: SoundTreatment.rhythm);
    for (var bar = 1; bar < 8; bar++) {
      final start = bar * 90000;
      for (var hit = 0; hit < density; hit++) {
        final position = hit * 90000 ~/ density;
        final swing = style == ArrangementStyle.swaying && hit.isOdd ? 2812 : 0;
        add(
          beat,
          start + position + swing,
          9600,
          gain: .62,
          treatment: SoundTreatment.rhythm,
          variation: bar ~/ 2,
          flip: hit.isOdd,
        );
      }
      if (bar >= 2) {
        // Real long notes, not a 200 ms cap pretending to be a bass part.
        add(
          bass,
          start,
          bar.isEven ? 72000 : 42000,
          note: (root - 12 + (bar % 4 == 3 ? 5 : 0)).toDouble(),
          gain: .38,
        );
      }
      if (bar >= 3) {
        for (var hit = 0; hit < (density > 2 ? 2 : 1); hit++) {
          add(
            keys,
            start + 22500 + hit * 45000,
            24000,
            note: (root + (hit == 0 ? 7 : 4)).toDouble(),
            gain: .34,
            variation: hit,
          );
        }
        final steps = style == ArrangementStyle.sparse
            ? 4
            : style == ArrangementStyle.lively && bar >= 6
            ? 16
            : 8;
        final stepSamples = 90000 ~/ steps;
        for (var step = 0; step < steps; step++) {
          if (melodyTemplate == MelodyTemplate.wink && step % 4 == 3) continue;
          final lead =
              melodyTemplate == MelodyTemplate.answer && step >= steps ~/ 2
              ? usable[(usable.indexOf(melody) + 1) % usable.length]
              : melody;
          final degree = motif[(step + bar + (seed & 3)) % motif.length];
          final held = step == 0 && bar.isEven;
          add(
            lead,
            start + step * stepSamples,
            held ? 36000 : math.max(2400, stepSamples - 480),
            note: (root + degree).toDouble(),
            gain: .51,
            variation: bar ~/ 2,
          );
        }
      }
    }
    // Genuine echoes: every duplicate picture has its own audible event.
    for (var i = 0; i < 4; i++) {
      final clip = usable[i % usable.length];
      final start = 540000 + i * 33750;
      for (var echo = 0; echo < 3; echo++) {
        add(
          clip,
          start + echo * 5625,
          16875,
          note: (root + [0, 4, 7][i % 3]).toDouble(),
          gain: [.32, .23, .16][echo],
          flip: echo.isOdd,
          variation: i,
        );
      }
    }
    add(
      melody,
      697500,
      22500,
      note: root.toDouble(),
      gain: .4,
      reverse: true,
      flip: true,
    );
  }

  // Keep speech intelligible without deleting musical notes or changing MIDI
  // timing. Duck accompaniment while a natural phrase is actually sounding.
  final phrases = events
      .where((e) => e.treatment == SoundTreatment.phrase)
      .toList();
  final ordered = events.indexed.toList()
    ..sort((a, b) {
      final order = a.$2.destinationStartSample.compareTo(
        b.$2.destinationStartSample,
      );
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
  final audio = <SoundEvent>[];
  final video = <VideoEvent>[];
  for (final indexed in ordered) {
    final e = indexed.$2;
    final duck =
        e.treatment != SoundTreatment.phrase &&
        phrases.any(
          (p) =>
              p.destinationStartSample <
                  e.destinationStartSample + e.durationSamples &&
              e.destinationStartSample <
                  p.destinationStartSample + p.durationSamples,
        );
    audio.add(
      SoundEvent(
        assetId: e.assetId,
        sourceStartSample: e.sourceStartSample,
        sourceDurationSamples: e.sourceDurationSamples,
        destinationStartSample: e.destinationStartSample,
        durationSamples: e.durationSamples,
        gain: e.gain * (duck ? .62 : 1),
        fades: e.fades,
        targetMidiNote: e.targetMidiNote,
        reverse: e.reverse,
        treatment: e.treatment,
      ),
    );
    video.add(
      VideoEvent(
        assetId: e.assetId,
        destinationStartSample: e.destinationStartSample,
        durationSamples: e.durationSamples,
        sourceDurationSamples: e.sourceDurationSamples,
        sourceVideoStartTime: RationalTime(e.sourceStartSample, 48000),
        crop: NormalizedCrop.fullFrame,
        loopMode: e.durationSamples > e.effectiveSourceDurationSamples
            ? VideoLoopMode.loop
            : VideoLoopMode.once,
        reverse: e.reverse,
        mirror: mirror[e] ?? false,
      ),
    );
  }
  return Arrangement(
    templateId: midi
        ? 'score-image-3part-128bpm-8bar'
        : 'everyday-${style.name}-${melodyTemplate.name}-v2',
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: seed,
    style: style,
    melodyTemplate: melodyTemplate,
    songRoles: roles,
    sourceAssetIds: clips.map((c) => c.assetId).toList(),
    unusableAssetIds: clips
        .where((c) => !c.isUsable)
        .map((c) => c.assetId)
        .toList(),
    events: audio,
    videoEvents: video,
  );
}

int _longest(AnalyzedClip clip) => clip.audibleRegions.isEmpty
    ? clip.durationSamples
    : clip.audibleRegions.map((r) => r.durationSamples).reduce(math.max);

AudibleRegion _window(
  AnalyzedClip clip, {
  required bool phrase,
  required int variation,
}) {
  final regions = clip.audibleRegions;
  if (regions.isEmpty)
    return AudibleRegion(
      startSample: clip.sourceStartSample,
      durationSamples: clip.durationSamples,
    );
  if (phrase)
    return regions.reduce(
      (a, b) => a.durationSamples >= b.durationSamples ? a : b,
    );
  // Repeated notes intentionally reuse the same syllable for a recognizable
  // hook; variations change on phrase boundaries rather than on every frame.
  return regions[variation.abs() % regions.length];
}
