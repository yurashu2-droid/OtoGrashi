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
  final measured = usable.where((c) => _register(c) != null).toList()
    ..sort((a, b) => _register(a)!.compareTo(_register(b)!));
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
  final sourceCursors = <String, int>{};

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
    bool flow = false,
    List<PitchStep> pitchSteps = const <PitchStep>[],
  }) {
    if (start >= 720000 || wanted <= 0) return;
    final region = _window(
      clip,
      phrase: treatment == SoundTreatment.phrase || flow,
      variation: variation,
    );
    final desired = math.min(wanted, 720000 - start);
    final cursorKey = '${clip.assetId}:${region.startSample}';
    var offset = flow ? (sourceCursors[cursorKey] ?? 0) : 0;
    // Continue the sentence at phrase boundaries. Rewind only when the next
    // phrase no longer fits, rather than looping a tiny leftover tail.
    if (offset + math.min(desired, region.durationSamples) >
        region.durationSamples) {
      offset = 0;
    }
    final available = region.durationSamples - offset;
    final duration = treatment == SoundTreatment.phrase
        ? math.min(desired, available)
        : desired;
    // Tuned one-shots can hold a note, but always loop inside the selected
    // source range. Long natural phrases are never squeezed into note slots.
    final sourceDuration = math.min(available, duration);
    if (flow) sourceCursors[cursorKey] = offset + sourceDuration;
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
      sourceStartSample: region.startSample + offset,
      sourceDurationSamples: sourceDuration,
      destinationStartSample: start,
      durationSamples: duration,
      gain: gain,
      fades: EventFades(fadeInSamples: fadeIn, fadeOutSamples: fadeOut),
      targetMidiNote: note,
      pitchSteps: List<PitchStep>.unmodifiable(pitchSteps),
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
          : (_register(clip) ?? 64) < 60
          ? 1
          : 0;
      lanes[lane].add(clip);
    }
    for (var lane = 0; lane < 3; lane++) {
      final notes = midiScoreNotes[lane];
      final pitches = notes.map((n) => n[2]).toList()..sort();
      final nativeNote = _register(leads[lane]) ?? (lane == 1 ? 50 : 57);
      // ONE octave for a whole part, never independently wrap each note. This
      // preserves the score's melody direction while avoiding chipmunk voices.
      final octave = _registerOctave(
        pitches[pitches.length ~/ 2].toDouble(),
        nativeNote,
        minimum: pitches.first,
        maximum: pitches.last,
      );
      if (lane == 0) {
        final group = <List<int>>[];
        void flush() {
          if (group.isEmpty) return;
          final start = (group.first[0] * 720000 / 15360).round();
          final steps = group.map((n) {
            final onset = (n[0] * 720000 / 15360).round();
            final end = ((n[0] + n[1]) * 720000 / 15360).round();
            return PitchStep(
              offsetSamples: onset - start,
              durationSamples: end - onset,
              midiNote: (n[2] + octave).toDouble(),
            );
          }).toList();
          add(
            melody,
            start,
            steps.last.offsetSamples + steps.last.durationSamples,
            note: steps.first.midiNote,
            gain: .55,
            flow: true,
            pitchSteps: steps,
          );
          group.clear();
        }

        for (final n in notes) {
          if (group.isNotEmpty) {
            final end = ((n[0] + n[1]) * 720000 / 15360).round();
            final start = (group.first[0] * 720000 / 15360).round();
            final gap =
                ((n[0] - group.last[0] - group.last[1]) * 720000 / 15360)
                    .round();
            if (gap > 1920 || end - start > 45000) flush();
          }
          group.add(n);
        }
        flush();
      } else {
        for (var index = 0; index < notes.length; index++) {
          final n = notes[index];
          final start = (n[0] * 720000 / 15360).round();
          final end = ((n[0] + n[1]) * 720000 / 15360).round();
          add(
            lanes[lane][index % lanes[lane].length],
            start,
            end - start,
            note: (n[2] + octave).toDouble(),
            gain: .32,
            variation: index ~/ 8,
          );
        }
      }
    }
  } else {
    // Center the nine-semitone motif around the speaker's register. The old
    // minimum MIDI 60 forced low voices more than an octave upward.
    final root = ((_register(melody)?.round() ?? 57) - 4).clamp(40, 76);
    final bassOctave = _registerOctave(
      (root - 12).toDouble(),
      _register(bass) ?? root.toDouble(),
      minimum: root - 12,
      maximum: root - 7,
    );
    final keysOctave = _registerOctave(
      (root + 5).toDouble(),
      _register(keys) ?? root.toDouble(),
      minimum: root + 4,
      maximum: root + 7,
    );
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
          note: (root - 12 + bassOctave + (bar % 4 == 3 ? 5 : 0)).toDouble(),
          gain: .38,
        );
      }
      if (bar >= 3) {
        for (var hit = 0; hit < (density > 2 ? 2 : 1); hit++) {
          add(
            keys,
            start + 22500 + hit * 45000,
            24000,
            note: (root + keysOctave + (hit == 0 ? 7 : 4)).toDouble(),
            gain: .34,
            variation: hit,
          );
        }
        // Half-bar phrases keep syllables readable. Notes are pitch automation
        // over ONE advancing waveform; only the explicit echoes below retrigger.
        for (var part = 0; part < 2; part++) {
          final lead = melodyTemplate == MelodyTemplate.answer && part == 1
              ? usable[(usable.indexOf(melody) + 1) % usable.length]
              : melody;
          final leadOctave = _registerOctave(
            (root + 4).toDouble(),
            _register(lead) ?? (root + 4).toDouble(),
            minimum: root,
            maximum: root + 9,
          );
          final stepsPerPhrase = style == ArrangementStyle.sparse ? 1 : 2;
          final stepSamples = 45000 ~/ stepsPerPhrase;
          final steps = <PitchStep>[];
          for (var step = 0; step < stepsPerPhrase; step++) {
            if (melodyTemplate == MelodyTemplate.wink &&
                part == 1 &&
                step == 1) {
              continue;
            }
            final degree =
                motif[(part * stepsPerPhrase + step + bar + (seed & 3)) %
                    motif.length];
            steps.add(
              PitchStep(
                offsetSamples: step * stepSamples,
                durationSamples: stepSamples,
                midiNote: (root + leadOctave + degree).toDouble(),
              ),
            );
          }
          if (steps.isNotEmpty) {
            add(
              lead,
              start + part * 45000,
              steps.last.offsetSamples + steps.last.durationSamples,
              note: steps.first.midiNote,
              gain: .51,
              flow: true,
              pitchSteps: steps,
            );
          }
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
        pitchSteps: e.pitchSteps,
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
        : 'everyday-${style.name}-${melodyTemplate.name}-v3',
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
  if (regions.isEmpty) {
    return AudibleRegion(
      startSample: clip.sourceStartSample,
      durationSamples: clip.durationSamples,
    );
  }
  if (phrase) {
    // Audible regions are energy-ranked, not chronological. Short pauses are
    // part of a sentence: retaining them is better than looping a lone vowel.
    // The source still advances at 1x, including the actual recorded silence.
    final ordered = regions.toList()
      ..sort((a, b) => a.startSample.compareTo(b.startSample));
    var start = ordered.first.startSample;
    var end = start + ordered.first.durationSamples;
    var audible = ordered.first.durationSamples;
    var bestStart = start;
    var bestEnd = end;
    var bestAudible = audible;
    for (final region in ordered.skip(1)) {
      final regionEnd = region.startSample + region.durationSamples;
      if (region.startSample - end <= 16800) {
        audible += math.max(0, regionEnd - math.max(end, region.startSample));
        end = math.max(end, regionEnd);
      } else {
        start = region.startSample;
        end = regionEnd;
        audible = region.durationSamples;
      }
      if (audible > bestAudible) {
        bestStart = start;
        bestEnd = end;
        bestAudible = audible;
      }
    }
    return AudibleRegion(
      startSample: bestStart,
      durationSamples: bestEnd - bestStart,
    );
  }
  // Repeated notes intentionally reuse the same syllable for a recognizable
  // hook; variations change on phrase boundaries rather than on every frame.
  return regions[variation.abs() % regions.length];
}

/// A register hint is not a stable source F0; rendering always remeasures PCM.
double? _register(AnalyzedClip clip) =>
    clip.registerMidiNote ?? clip.fundamentalMidiNote;

// Select one legal octave for a complete phrase/part; never fold its notes
// independently, which could turn an ascending melody into a descending one.
int _registerOctave(
  double center,
  double nativeNote, {
  required num minimum,
  required num maximum,
}) {
  var best = 0;
  var distance = double.infinity;
  for (var octave = -48; octave <= 48; octave += 12) {
    if (minimum + octave < 24 || maximum + octave > 100) continue;
    final candidate = (center + octave - nativeNote).abs();
    if (candidate < distance ||
        (candidate == distance && octave.abs() < best.abs())) {
      distance = candidate;
      best = octave;
    }
  }
  return best;
}
