import 'arrangement.dart';

Arrangement arrange({
  required List<AnalyzedClip> clips,
  required ArrangementStyle style,
  required int seed,
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

  // Bars 1–3 introduce one primary source each, without layering.
  for (var bar = 0; bar < 3; bar++) {
    final clip = usable[bar % usable.length];
    events.add(
      _event(clip, bar * Arrangement.barSamples, template, random, intro: true),
    );
  }

  final secondary = usable.length > 3
      ? usable.sublist(3)
      : const <AnalyzedClip>[];
  var mixIndex = 0;
  // Bars 4–7 combine sources using the style's explicit density and swing.
  for (var bar = 3; bar < 7; bar++) {
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
  final destinationRemaining = 720000 - destinationStart;
  final duration = _min(
    desiredDuration,
    _min(clip.durationSamples, destinationRemaining),
  );
  if (duration <= 0) {
    throw const MediaContractException('Event has no bounded duration.');
  }
  final maxSourceStart =
      clip.sourceStartSample + clip.durationSamples - duration;
  final candidates = clip.onsetSamples
      .where(
        (sample) =>
            sample >= clip.sourceStartSample && sample <= maxSourceStart,
      )
      .toList();
  final sourceStart = candidates.isNotEmpty
      ? candidates[random.nextInt(candidates.length)]
      : (maxSourceStart == clip.sourceStartSample
            ? clip.sourceStartSample
            : clip.sourceStartSample +
                  random.nextInt(maxSourceStart - clip.sourceStartSample + 1));
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
    : initialState = seed == 0 ? 0x6d2b79f5 : seed & 0xffffffff,
      _state = seed == 0 ? 0x6d2b79f5 : seed & 0xffffffff;

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
