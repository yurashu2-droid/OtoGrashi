import 'arrangement.dart';
import 'melody_template.dart';

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
    final clip = usable[(step + random.nextInt(usable.length)) % usable.length];
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

  final melodicSource =
      usable
          .where(
            (clip) =>
                clip.suggestedRole == SuggestedRole.sustain &&
                clip.durationSamples >= 18000 &&
                clip.rms >= 0.03,
          )
          .toList()
        ..sort((a, b) => b.rms.compareTo(a.rms));
  if (melodyTemplate != MelodyTemplate.none && melodicSource.isNotEmpty) {
    final melodyEvents = <SoundEvent>[];
    for (var step = 0; step < melodyTemplate.notes.length; step++) {
      final note = melodyTemplate.notes[step];
      final pitch = note.pitchSemitones;
      if (pitch == null) continue;
      final clip = melodicSource.first;
      const duration = 18000;
      final maxStart = clip.sourceStartSample + clip.durationSamples - duration;
      final onset = clip.onsetSamples.firstOrNull ?? clip.sourceStartSample;
      final sourceStart = onset.clamp(clip.sourceStartSample, maxStart).toInt();
      melodyEvents.add(
        SoundEvent(
          assetId: clip.assetId,
          sourceStartSample: sourceStart,
          destinationStartSample:
              3 * Arrangement.barSamples +
              step * 45000 +
              (note.delayed ? 11250 : 0),
          durationSamples: duration,
          gain: 0.62,
          fades: const EventFades(fadeInSamples: 800, fadeOutSamples: 1200),
          pitchSemitones: pitch,
        ),
      );
    }
    // The busiest rhythm already uses 57 of the 64 event slots. Give the
    // melody priority over one repeated pickup at the very end when needed.
    while (events.length + melodyEvents.length > 64) {
      events.removeLast();
    }
    events.addAll(melodyEvents);
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
    templateId: template.id,
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: random.initialState,
    style: style,
    melodyTemplate: melodyTemplate,
    sourceAssetIds: clips.map((clip) => clip.assetId).toList(),
    unusableAssetIds: unusable,
    events: events,
    videoEvents: videoEvents,
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
  final region = clip.audibleRegions.firstOrNull;
  final destinationRemaining = 720000 - destinationStart;
  final activeDuration = region == null
      ? clip.durationSamples
      : (region.durationSamples < 4800 ? 4800 : region.durationSamples);
  final duration = _min(
    desiredDuration,
    _min(activeDuration, _min(clip.durationSamples, destinationRemaining)),
  );
  if (duration <= 0) {
    throw const MediaContractException('Event has no bounded duration.');
  }
  final maxSourceStart =
      clip.sourceStartSample + clip.durationSamples - duration;
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
  final sourceStart = candidates.isNotEmpty
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
