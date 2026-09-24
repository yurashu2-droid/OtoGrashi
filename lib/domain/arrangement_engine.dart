import 'arrangement.dart';
import 'melody_template.dart';
import 'midi_score_data.dart';

Arrangement arrange({
  required List<AnalyzedClip> clips,
  required ArrangementStyle style,
  required int seed,
  MelodyTemplate melodyTemplate = MelodyTemplate.none,
}) {
  if (clips.isEmpty) {
    throw const ArrangementRejected(
      reason: ArrangementRejectionReason.noSources,
      assetIds: <String>[],
    );
  }
  if (clips.length > 6 ||
      clips.map((clip) => clip.assetId).toSet().length != clips.length) {
    throw const MediaContractException(
      'Arrangement requires 1 to 6 unique assets.',
    );
  }

  final usable = clips.where((clip) => clip.isUsable).toList(growable: false);
  final unusable = clips
      .where((clip) => !clip.isUsable)
      .map((clip) => clip.assetId)
      .toList();
  if (usable.isEmpty) {
    throw ArrangementRejected(
      reason: ArrangementRejectionReason.allSilent,
      assetIds: List.unmodifiable(unusable),
    );
  }
  if (usable.length < 3) {
    throw ArrangementRejected(
      reason: ArrangementRejectionReason.insufficientUsableSources,
      assetIds: List.unmodifiable(unusable),
    );
  }

  final template = _templates[style]!;
  final random = _XorShift32(seed);
  final events = <SoundEvent>[];
  SongRoles? songRoles;

  if (melodyTemplate == MelodyTemplate.midiScore) {
    final score = _buildMidiScoreEvents(usable);
    events.addAll(score.events);
    songRoles = score.roles;
  } else if (melodyTemplate != MelodyTemplate.none) {
    final song = _buildSongEvents(
      usable,
      style,
      melodyTemplate,
      template,
      random,
    );
    events.addAll(song.events);
    songRoles = song.roles;
  } else {
    // Introduce each sound alone, then let its own rhythm build within the bar.
    for (var bar = 0; bar < 3; bar++) {
      final clip = usable[bar % usable.length];
      for (var beat = 0; beat < bar + 2; beat++) {
        events.add(
          _event(
            clip,
            bar * Arrangement.barSamples + beat * Arrangement.beatSamples,
            template,
            random,
            intro: true,
          ),
        );
      }
    }

    final secondary = usable.length > 3
        ? usable.sublist(3)
        : const <AnalyzedClip>[];
    var mixIndex = 0;
    // Bars 4–7 combine sources using the style's explicit density and swing.
    for (var bar = 3; bar < 7; bar++) {
      // The bottom lane is a real repeating sound, rather than silent motion.
      for (final beat in const [0, 2]) {
        events.add(
          _event(
            usable.first,
            bar * Arrangement.barSamples + beat * Arrangement.beatSamples,
            template,
            random,
          ),
        );
      }
      for (var step = 0; step < template.mixOffsets.length; step++) {
        final clip = mixIndex < secondary.length
            ? secondary[mixIndex]
            : usable[random.nextInt(usable.length)];
        final swing = step.isOdd ? template.swingSamples : 0;
        events.add(
          _event(
            clip,
            bar * Arrangement.barSamples + template.mixOffsets[step] + swing,
            template,
            random,
          ),
        );
        mixIndex++;
      }
    }

    // Bar 8 creates a recognizable pickup into the next 15-second loop.
    for (var step = 0; step < template.outroOffsets.length; step++) {
      final clip =
          usable[(step + random.nextInt(usable.length)) % usable.length];
      events.add(
        _event(
          clip,
          7 * Arrangement.barSamples + template.outroOffsets[step],
          template,
          random,
          outro: true,
        ),
      );
    }
  }

  final videoEvents = events
      .map(
        (event) => VideoEvent(
          assetId: event.assetId,
          destinationStartSample: event.destinationStartSample,
          durationSamples: event.durationSamples,
          sourceVideoStartTime: RationalTime(event.sourceStartSample, 48000),
          crop: NormalizedCrop.fullFrame,
          loopMode: _loopMode(
            usable.singleWhere((clip) => clip.assetId == event.assetId),
          ),
        ),
      )
      .toList(growable: false);

  return Arrangement(
    templateId: melodyTemplate == MelodyTemplate.midiScore
        ? 'score-image-3part-128bpm-8bar'
        : template.id,
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: random.initialState,
    style: style,
    melodyTemplate: melodyTemplate,
    songRoles: songRoles,
    sourceAssetIds: clips.map((clip) => clip.assetId).toList(),
    unusableAssetIds: unusable,
    events: events,
    videoEvents: videoEvents,
  );
}

final class _SongEvents {
  const _SongEvents(this.events, this.roles);
  final List<SoundEvent> events;
  final SongRoles roles;
}

_SongEvents _buildMidiScoreEvents(List<AnalyzedClip> usable) {
  // The MIDI has three pitched parts. Prefer measured sustained sounds for
  // melody and bass, while allowing any audible recording to play a part.
  final measured = usable
      .where((clip) => clip.fundamentalMidiNote != null)
      .toList();
  final tonal = measured
      .where((clip) => clip.suggestedRole != SuggestedRole.transient)
      .toList();
  final pitched = (tonal.isNotEmpty ? tonal : measured)
    ..sort((a, b) => a.fundamentalMidiNote!.compareTo(b.fundamentalMidiNote!));
  final byLength = usable.toList()
    ..sort((a, b) => _longestAudible(b).compareTo(_longestAudible(a)));
  final bass = pitched.firstOrNull ?? byLength.first;
  final melody = pitched.length > 1
      ? pitched.last
      : pitched.firstOrNull ?? byLength.first;
  final pianoCandidates =
      usable
          .where(
            (clip) =>
                clip.assetId != bass.assetId && clip.assetId != melody.assetId,
          )
          .toList()
        ..sort((a, b) {
          int suitability(AnalyzedClip clip) =>
              (clip.suggestedRole == SuggestedRole.transient ? 100 : 0) +
              (clip.fundamentalMidiNote == null
                  ? 30
                  : (clip.fundamentalMidiNote! - 58).abs().round());
          return suitability(a).compareTo(suitability(b));
        });
  final piano =
      pianoCandidates.firstOrNull ??
      (byLength.where((clip) => clip.assetId != melody.assetId).firstOrNull ??
          melody);
  final leads = [melody, bass, piano];
  final roles = SongRoles(
    melody: melody.assetId,
    bass: bass.assetId,
    keys: piano.assetId,
  );

  // Extra user recordings share the closest suitable part, replacing a lead
  // on some notes. This keeps the original 148 note onsets and all 3–6 videos.
  final lanes = <List<AnalyzedClip>>[
    [melody],
    [bass],
    [piano],
  ];
  for (final clip in usable) {
    if (leads.any((lead) => lead.assetId == clip.assetId)) continue;
    final lane = clip.suggestedRole == SuggestedRole.transient
        ? 2
        : clip.fundamentalMidiNote == null
        ? 2
        : clip.fundamentalMidiNote! < 60
        ? 1
        : 0;
    lanes[lane].add(clip);
  }

  // Choose one song-wide key shift and one octave for each part. Optimize
  // against the measured lead sounds so all notes fit within ±12 when possible.
  var bestKey = 0;
  var bestOctaves = <int>[0, 0, 0];
  var bestCost = double.infinity;
  for (var key = -12; key <= 12; key++) {
    final octaves = <int>[];
    var cost = 0.0;
    for (var lane = 0; lane < 3; lane++) {
      final fundamental = leads[lane].fundamentalMidiNote;
      if (fundamental == null) {
        octaves.add(0);
        continue;
      }
      var laneCost = double.infinity;
      var laneOctave = 0;
      for (final octave in const [-24, -12, 0, 12, 24]) {
        var candidate = 0.0;
        for (final note in midiScoreNotes[lane]) {
          final shift = note[2] + key + octave - fundamental;
          final over = shift.abs() > 12 ? shift.abs() - 12 : 0.0;
          candidate += over * 1000 + shift.abs() * 0.01;
        }
        candidate += octave.abs() * 0.02;
        if (candidate < laneCost) {
          laneCost = candidate;
          laneOctave = octave;
        }
      }
      octaves.add(laneOctave);
      cost += laneCost;
    }
    cost += key.abs() * 0.05;
    if (cost < bestCost) {
      bestCost = cost;
      bestKey = key;
      bestOctaves = octaves;
    }
  }

  final events = <SoundEvent>[];
  for (var lane = 0; lane < 3; lane++) {
    final notes = midiScoreNotes[lane];
    for (var index = 0; index < notes.length; index++) {
      final note = notes[index];
      final clip = lanes[lane][index % lanes[lane].length];
      // 32 beats * 480 ticks map exactly to 720,000 samples. Round each
      // boundary independently to preserve starts, rests and overlaps.
      final destinationStart = (note[0] * 720000 / 15360).round();
      final noteEnd = ((note[0] + note[1]) * 720000 / 15360).round();
      final region = _bestScoreRegion(clip, noteEnd - destinationStart);
      final sourceStart = region?.startSample ?? clip.sourceStartSample;
      final available = region?.durationSamples ?? clip.durationSamples;
      final duration = _min(noteEnd - destinationStart, available);
      final fundamental = clip.fundamentalMidiNote;
      var pitch = 0.0;
      if (fundamental != null) {
        pitch = note[2] + bestKey + bestOctaves[lane] - fundamental;
        // For an extra sound with a different register, keep the MIDI pitch
        // class while choosing its closest audible octave.
        while (pitch > 12) {
          pitch -= 12;
        }
        while (pitch < -12) {
          pitch += 12;
        }
      }
      final fade = _min(240, duration ~/ 4);
      events.add(
        SoundEvent(
          assetId: clip.assetId,
          sourceStartSample: sourceStart,
          destinationStartSample: destinationStart,
          durationSamples: duration,
          gain: lane == 0
              ? 0.55
              : lane == 1
              ? 0.48
              : 0.43,
          fades: EventFades(fadeInSamples: fade, fadeOutSamples: fade),
          pitchSemitones: pitch,
        ),
      );
    }
  }
  events.sort(
    (a, b) => a.destinationStartSample.compareTo(b.destinationStartSample),
  );
  return _SongEvents(events, roles);
}

int _longestAudible(AnalyzedClip clip) => clip.audibleRegions.isEmpty
    ? clip.durationSamples
    : clip.audibleRegions
          .map((region) => region.durationSamples)
          .reduce((a, b) => a > b ? a : b);

AudibleRegion? _bestScoreRegion(AnalyzedClip clip, int desired) {
  if (clip.audibleRegions.isEmpty) return null;
  // The first fitting region preserves the analyzed ordering; otherwise use
  // the longest region and shorten only that note's sounding duration.
  return clip.audibleRegions
          .where((region) => region.durationSamples >= desired)
          .firstOrNull ??
      clip.audibleRegions.reduce(
        (a, b) => a.durationSamples >= b.durationSamples ? a : b,
      );
}

_SongEvents _buildSongEvents(
  List<AnalyzedClip> usable,
  ArrangementStyle style,
  MelodyTemplate song,
  _ArrangementTemplate rhythm,
  _XorShift32 random,
) {
  List<AnalyzedClip> ranked(Iterable<AnalyzedClip> clips) =>
      clips.toList()..sort((a, b) => b.rms.compareTo(a.rms));

  final beats = ranked(
    usable.where((clip) => clip.suggestedRole == SuggestedRole.transient),
  );
  final beat =
      beats.firstOrNull ??
      ranked(
        usable.where(
          (clip) =>
              clip.suggestedRole == SuggestedRole.texture &&
              clip.onsetSamples.length >= 2,
        ),
      ).firstOrNull;
  final sustained = ranked(
    usable.where(
      (clip) =>
          clip.suggestedRole == SuggestedRole.sustain &&
          _hasAudibleSpan(clip, 18000) &&
          clip.rms >= 0.03,
    ),
  );
  // Prefer a measured, stable tone for the song's melody. A louder spoken
  // phrase with no stable fundamental can still be used as a rhythm layer.
  final bass =
      sustained.where((clip) => clip.fundamentalMidiNote != null).firstOrNull ??
      sustained.firstOrNull;
  final otherLongSounds = ranked(
    usable.where(
      (clip) =>
          clip.assetId != beat?.assetId &&
          clip.assetId != bass?.assetId &&
          clip.suggestedRole != SuggestedRole.transient &&
          _hasAudibleSpan(clip, 14000) &&
          clip.rms >= 0.03,
    ),
  );
  final otherHits = ranked(
    usable.where(
      (clip) =>
          clip.suggestedRole == SuggestedRole.transient &&
          clip.assetId != beat?.assetId,
    ),
  );
  final keys =
      otherLongSounds.firstOrNull ??
      otherHits.firstOrNull ??
      sustained.skip(1).firstOrNull ??
      bass;
  final melody = bass?.fundamentalMidiNote == null ? null : bass;
  final roles = SongRoles(
    beat: beat?.assetId,
    bass: bass?.assetId,
    keys: keys?.assetId,
    melody: melody?.assetId,
  );
  final melodyRoot = melody?.fundamentalMidiNote?.roundToDouble();

  final events = <SoundEvent>[];
  for (var bar = 0; bar < 8; bar++) {
    final start = bar * Arrangement.barSamples;
    if (bar == 0 && beat == null) {
      events.add(
        _songEvent(
          usable.first,
          start,
          rhythm,
          random,
          durationCap: 18000,
          gain: 0.48,
          fadeIn: 300,
          fadeOut: 1200,
        ),
      );
    }
    if (beat != null) {
      final count = style == ArrangementStyle.lively ? 3 : 2;
      for (final offset in song.beatOffsets.take(count)) {
        events.add(
          _songEvent(
            beat,
            start + offset,
            rhythm,
            random,
            durationCap: 11000,
            gain: 0.72,
            fadeIn: 120,
            fadeOut: 480,
          ),
        );
      }
    }
    if (bar >= 1 && bass != null) {
      final count = style == ArrangementStyle.sparse ? 1 : 2;
      for (final offset in song.bassOffsets.take(count)) {
        events.add(
          _songEvent(
            bass,
            start + offset,
            rhythm,
            random,
            durationCap: 22500,
            gain: 0.53,
            fadeIn: 900,
            fadeOut: 2400,
            pitch: _pitchForNote(bass, bar.isEven ? -3 : -2, melodyRoot),
          ),
        );
      }
    }
    if (bar >= 2 && keys != null) {
      final count = style == ArrangementStyle.sparse ? 1 : 2;
      for (var index = 0; index < count; index++) {
        events.add(
          _songEvent(
            keys,
            start + song.keysOffsets[index],
            rhythm,
            random,
            durationCap: 14000,
            gain: 0.46,
            fadeIn: 300,
            fadeOut: 6800,
            pitch: _pitchForNote(keys, index.isEven ? 2 : 0, melodyRoot),
          ),
        );
      }
    }
    if (bar >= 3 && bar < 7 && melody != null) {
      for (var half = 0; half < 2; half++) {
        final note = song.notes[(bar - 3) * 2 + half];
        final pitch = note.pitchSemitones;
        if (pitch == null) continue;
        events.add(
          _songEvent(
            melody,
            start + half * 45000 + (note.delayed ? 11250 : 0),
            rhythm,
            random,
            durationCap: 18000,
            gain: 0.58,
            fadeIn: 700,
            fadeOut: 1500,
            pitch: _pitchForNote(melody, pitch, melodyRoot),
          ),
        );
      }
    }
  }

  // Give every usable video a brief audible moment even if it has no
  // suitable musical role. It remains its own recorded sound and image.
  final used = events.map((event) => event.assetId).toSet();
  var fill = 0;
  for (final clip in usable) {
    if (used.contains(clip.assetId)) continue;
    events.add(
      _songEvent(
        clip,
        2 * Arrangement.barSamples + fill * 11250,
        rhythm,
        random,
        durationCap: 12000,
        gain: 0.48,
        fadeIn: 300,
        fadeOut: 1200,
      ),
    );
    fill++;
  }
  return _SongEvents(events, roles);
}

double _pitchForNote(AnalyzedClip clip, int relativeNote, double? root) {
  final fundamental = clip.fundamentalMidiNote;
  if (root == null || fundamental == null) return 0;
  final shift = root + relativeNote - fundamental;
  // Beyond the renderer's quality range, keep the recorded tone intact rather
  // than substitute an unrelated relative shift or an inaccurate clamped note.
  return shift >= -3 && shift <= 3 ? shift : 0;
}

bool _hasAudibleSpan(AnalyzedClip clip, int minimumSamples) =>
    clip.audibleRegions.isEmpty
    // Older analyses have no region data; retain their duration behavior.
    ? clip.durationSamples >= minimumSamples
    : clip.audibleRegions.any(
        (region) => region.durationSamples >= minimumSamples,
      );

SoundEvent _songEvent(
  AnalyzedClip clip,
  int destinationStart,
  _ArrangementTemplate rhythm,
  _XorShift32 random, {
  required int durationCap,
  required double gain,
  required int fadeIn,
  required int fadeOut,
  double pitch = 0,
}) {
  // Reuse the regular source-window choice so audible-region analysis can
  // select both rhythm and song clips using the same source timing.
  final selected = _event(clip, destinationStart, rhythm, random);
  final duration = _min(selected.durationSamples, durationCap);
  return SoundEvent(
    assetId: clip.assetId,
    sourceStartSample: selected.sourceStartSample,
    destinationStartSample: destinationStart,
    durationSamples: duration,
    gain: gain,
    fades: EventFades(
      fadeInSamples: _min(fadeIn, duration ~/ 4),
      fadeOutSamples: _min(fadeOut, duration ~/ 2),
    ),
    pitchSemitones: pitch,
  );
}

SoundEvent _event(
  AnalyzedClip clip,
  int destinationStart,
  _ArrangementTemplate template,
  _XorShift32 random, {
  bool intro = false,
  bool outro = false,
}) {
  final desiredDuration = switch (clip.suggestedRole) {
    SuggestedRole.transient => template.transientDuration,
    SuggestedRole.sustain => template.sustainDuration,
    SuggestedRole.texture => template.textureDuration,
  };
  final regions = clip.audibleRegions;
  // Prefer a loud region that holds a complete event. If none does, use the
  // longest audible region and shorten the event to fit it.
  final region =
      regions
          .where((value) => value.durationSamples >= desiredDuration)
          .firstOrNull ??
      (regions.isEmpty
          ? null
          : regions.reduce(
              (a, b) => a.durationSamples >= b.durationSamples ? a : b,
            ));
  final destinationRemaining = 720000 - destinationStart;
  final activeDuration = region == null
      ? clip.durationSamples
      : region.durationSamples;
  final duration = _min(
    desiredDuration,
    _min(activeDuration, _min(clip.durationSamples, destinationRemaining)),
  );
  if (duration <= 0) {
    throw const MediaContractException('Event has no bounded duration.');
  }
  final maxSourceStart =
      _min(
        clip.sourceStartSample + clip.durationSamples,
        region == null
            ? clip.sourceStartSample + clip.durationSamples
            : region.startSample + region.durationSamples,
      ) -
      duration;
  final candidates = clip.onsetSamples
      .where(
        (sample) =>
            sample >= clip.sourceStartSample &&
            sample < clip.sourceStartSample + clip.durationSamples &&
            (region == null ||
                (sample >= region.startSample &&
                    sample < region.startSample + region.durationSamples)),
      )
      .map((sample) => _min(sample, maxSourceStart))
      .toSet()
      .toList();
  // Analysis supplies a loud-window fallback when it finds no sharp onset.
  // Older analyses may lack that anchor; the selection start is safer than a
  // random point that can land in a quiet tail.
  // For a voice-like sustained sound, begin with the audible phrase instead
  // of the strongest onset, which may be in the middle of a short word.
  final sourceStart =
      clip.suggestedRole == SuggestedRole.sustain && region != null
      ? _min(region.startSample, maxSourceStart)
      : candidates.isNotEmpty
      ? candidates[random.nextInt(candidates.length)]
      : region == null
      ? clip.sourceStartSample
      : _min(region.startSample, maxSourceStart);
  final fade = switch (clip.suggestedRole) {
    SuggestedRole.transient => 240,
    SuggestedRole.sustain => 1200,
    SuggestedRole.texture => 2400,
  };
  final boundedFade = _min(fade, duration ~/ 4);
  final roleGain = switch (clip.suggestedRole) {
    SuggestedRole.transient => 0.08,
    SuggestedRole.sustain => 0.0,
    SuggestedRole.texture => -0.08,
  };
  final sectionGain = intro ? 0.03 : (outro ? -0.03 : 0.0);
  final gain = _fixed(template.gain + roleGain + sectionGain);
  return SoundEvent(
    assetId: clip.assetId,
    sourceStartSample: sourceStart,
    destinationStartSample: destinationStart,
    durationSamples: duration,
    gain: gain,
    fades: EventFades(fadeInSamples: boundedFade, fadeOutSamples: boundedFade),
    pitchSemitones: 0,
  );
}

VideoLoopMode _loopMode(AnalyzedClip clip) => switch (clip.suggestedRole) {
  SuggestedRole.transient => VideoLoopMode.once,
  SuggestedRole.sustain => VideoLoopMode.hold,
  SuggestedRole.texture => VideoLoopMode.loop,
};

double _fixed(double value) => (value * 100).round() / 100;
int _min(int a, int b) => a < b ? a : b;

final class _ArrangementTemplate {
  const _ArrangementTemplate({
    required this.id,
    required this.mixOffsets,
    required this.outroOffsets,
    required this.swingSamples,
    required this.gain,
    required this.transientDuration,
    required this.sustainDuration,
    required this.textureDuration,
  });

  final String id;
  final List<int> mixOffsets;
  final List<int> outroOffsets;
  final int swingSamples;
  final double gain;
  final int transientDuration;
  final int sustainDuration;
  final int textureDuration;
}

const _templates = <ArrangementStyle, _ArrangementTemplate>{
  ArrangementStyle.sparse: _ArrangementTemplate(
    id: 'sparse-128bpm-8bar',
    mixOffsets: [0, 45000],
    outroOffsets: [0, 67500],
    swingSamples: 0,
    gain: 0.68,
    transientDuration: 9000,
    sustainDuration: 22500,
    textureDuration: 45000,
  ),
  ArrangementStyle.swaying: _ArrangementTemplate(
    id: 'swaying-128bpm-8bar',
    mixOffsets: [0, 22500, 45000, 67500],
    outroOffsets: [0, 22500, 46500, 67500],
    swingSamples: 1500,
    gain: 0.74,
    transientDuration: 11250,
    sustainDuration: 22500,
    textureDuration: 45000,
  ),
  ArrangementStyle.lively: _ArrangementTemplate(
    id: 'lively-128bpm-8bar',
    mixOffsets: [0, 11250, 22500, 33750, 45000, 56250, 67500, 78750],
    outroOffsets: [0, 11250, 22500, 33750, 45000, 56250, 67500, 78750],
    swingSamples: 2250,
    gain: 0.82,
    transientDuration: 9000,
    sustainDuration: 16875,
    textureDuration: 22500,
  ),
};

final class _XorShift32 {
  _XorShift32(int seed)
    : initialState = _normalizeSeed(seed),
      _state = _normalizeSeed(seed);

  static int _normalizeSeed(int seed) {
    final normalized = seed & 0xffffffff;
    return normalized == 0 ? 0x6d2b79f5 : normalized;
  }

  final int initialState;
  int _state;

  int nextUint32() {
    var value = _state & 0xffffffff;
    value = (value ^ ((value << 13) & 0xffffffff)) & 0xffffffff;
    value = (value ^ (value >> 17)) & 0xffffffff;
    value = (value ^ ((value << 5) & 0xffffffff)) & 0xffffffff;
    _state = value;
    return value;
  }

  int nextInt(int upperBound) {
    if (upperBound <= 0) {
      throw ArgumentError.value(upperBound, 'upperBound');
    }
    return nextUint32() % upperBound;
  }
}
