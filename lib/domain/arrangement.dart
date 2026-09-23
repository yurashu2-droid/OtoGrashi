import '../media/media_messages.dart';
import 'melody_template.dart';

export '../media/media_messages.dart';

enum ArrangementStyle { sparse, swaying, lively }

enum VideoLoopMode { loop, hold, once }

enum ArrangementRejectionReason {
  noSources,
  allSilent,
  insufficientUsableSources,
}

final class ArrangementRejected implements Exception {
  const ArrangementRejected({
    required this.reason,
    required this.assetIds,
    this.recoverable = true,
  });

  final ArrangementRejectionReason reason;
  final List<String> assetIds;
  final bool recoverable;
}

final class EventFades {
  const EventFades({required this.fadeInSamples, required this.fadeOutSamples});

  final int fadeInSamples;
  final int fadeOutSamples;

  Map<String, Object?> toJson() => {
    'fadeInSamples': fadeInSamples,
    'fadeOutSamples': fadeOutSamples,
  };

  factory EventFades.fromJson(Map<String, Object?> json) => EventFades(
    fadeInSamples: json['fadeInSamples'] as int,
    fadeOutSamples: json['fadeOutSamples'] as int,
  );
}

final class SoundEvent {
  const SoundEvent({
    required this.assetId,
    required this.sourceStartSample,
    required this.destinationStartSample,
    required this.durationSamples,
    required this.gain,
    required this.fades,
    this.pitchSemitones = 0,
  });

  final String assetId;
  final int sourceStartSample;
  final int destinationStartSample;
  final int durationSamples;
  final double gain;
  final EventFades fades;
  final int pitchSemitones;

  Map<String, Object?> toJson() => {
    'assetId': assetId,
    'sourceStartSample': sourceStartSample,
    'destinationStartSample': destinationStartSample,
    'durationSamples': durationSamples,
    'gain': gain,
    'fades': fades.toJson(),
    if (pitchSemitones != 0) 'pitchSemitones': pitchSemitones,
  };

  factory SoundEvent.fromJson(Map<String, Object?> json) => SoundEvent(
    assetId: json['assetId'] as String,
    sourceStartSample: json['sourceStartSample'] as int,
    destinationStartSample: json['destinationStartSample'] as int,
    durationSamples: json['durationSamples'] as int,
    gain: (json['gain'] as num).toDouble(),
    fades: EventFades.fromJson((json['fades'] as Map<Object?, Object?>).cast()),
    pitchSemitones: json['pitchSemitones'] as int? ?? 0,
  );
}

final class RationalTime {
  const RationalTime(this.numerator, this.denominator);

  final int numerator;
  final int denominator;

  Map<String, Object?> toJson() => {
    'numerator': numerator,
    'denominator': denominator,
  };

  factory RationalTime.fromJson(Map<String, Object?> json) =>
      RationalTime(json['numerator'] as int, json['denominator'] as int);

  @override
  bool operator ==(Object other) =>
      other is RationalTime &&
      numerator == other.numerator &&
      denominator == other.denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);
}

final class NormalizedCrop {
  const NormalizedCrop({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  static const fullFrame = NormalizedCrop(x: 0, y: 0, width: 1, height: 1);
  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  factory NormalizedCrop.fromJson(Map<String, Object?> json) => NormalizedCrop(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
  );
}

final class VideoEvent {
  const VideoEvent({
    required this.assetId,
    required this.destinationStartSample,
    required this.durationSamples,
    required this.sourceVideoStartTime,
    required this.crop,
    required this.loopMode,
  });

  final String assetId;
  final int destinationStartSample;
  final int durationSamples;
  final RationalTime sourceVideoStartTime;
  final NormalizedCrop crop;
  final VideoLoopMode loopMode;

  Map<String, Object?> toJson() => {
    'assetId': assetId,
    'destinationStartSample': destinationStartSample,
    'durationSamples': durationSamples,
    'sourceVideoStartTime': sourceVideoStartTime.toJson(),
    'crop': crop.toJson(),
    'loopMode': loopMode.name,
  };

  factory VideoEvent.fromJson(Map<String, Object?> json) => VideoEvent(
    assetId: json['assetId'] as String,
    destinationStartSample: json['destinationStartSample'] as int,
    durationSamples: json['durationSamples'] as int,
    sourceVideoStartTime: RationalTime.fromJson(
      (json['sourceVideoStartTime'] as Map<Object?, Object?>).cast(),
    ),
    crop: NormalizedCrop.fromJson(
      (json['crop'] as Map<Object?, Object?>).cast(),
    ),
    loopMode: VideoLoopMode.values.byName(json['loopMode'] as String),
  );
}

final class Arrangement {
  Arrangement({
    required this.templateId,
    required this.templateVersion,
    required this.analysisVersion,
    required this.rendererVersion,
    required this.seed,
    required this.style,
    this.melodyTemplate = MelodyTemplate.none,
    this.songRoles,
    required List<String> sourceAssetIds,
    required List<String> unusableAssetIds,
    required List<SoundEvent> events,
    required List<VideoEvent> videoEvents,
    this.sampleRate = 48000,
    this.totalSamples = 720000,
  }) : sourceAssetIds = List.unmodifiable(sourceAssetIds),
       unusableAssetIds = List.unmodifiable(unusableAssetIds),
       events = List.unmodifiable(events),
       videoEvents = List.unmodifiable(videoEvents) {
    if (sourceAssetIds.length > 6 ||
        unusableAssetIds.length > 6 ||
        events.length > 64 ||
        videoEvents.length > 64) {
      throw const MediaContractException('Arrangement exceeds schema limits.');
    }
    if (songRoles != null &&
        [
          songRoles!.beat,
          songRoles!.bass,
          songRoles!.keys,
          songRoles!.melody,
        ].whereType<String>().any((id) => !sourceAssetIds.contains(id))) {
      throw const MediaContractException('Song role source is not in project.');
    }
    if (sampleRate != 48000 || totalSamples != 720000) {
      throw const MediaContractException('Unsupported arrangement clock.');
    }
    if (templateVersion != 1 || analysisVersion != 1 || rendererVersion != 1) {
      throw const MediaContractException('Unsupported arrangement version.');
    }
    if (events.any(
          (event) =>
              event.sourceStartSample < 0 ||
              event.destinationStartSample < 0 ||
              event.durationSamples <= 0 ||
              event.destinationStartSample + event.durationSamples >
                  totalSamples ||
              !event.gain.isFinite ||
              event.gain < 0 ||
              event.gain > 1 ||
              event.pitchSemitones < -3 ||
              event.pitchSemitones > 3 ||
              event.fades.fadeInSamples < 0 ||
              event.fades.fadeOutSamples < 0 ||
              event.fades.fadeInSamples + event.fades.fadeOutSamples >
                  event.durationSamples,
        ) ||
        videoEvents.any(
          (event) =>
              event.destinationStartSample < 0 ||
              event.durationSamples <= 0 ||
              event.destinationStartSample + event.durationSamples >
                  totalSamples ||
              event.sourceVideoStartTime.numerator < 0 ||
              event.sourceVideoStartTime.denominator <= 0 ||
              !_validCrop(event.crop),
        )) {
      throw const MediaContractException('Arrangement event is out of range.');
    }
    if (events.length != videoEvents.length) {
      throw const MediaContractException(
        'Audio and video events must correspond.',
      );
    }
    for (var index = 0; index < events.length; index++) {
      final audio = events[index];
      final video = videoEvents[index];
      if (audio.assetId != video.assetId ||
          audio.destinationStartSample != video.destinationStartSample ||
          audio.durationSamples != video.durationSamples ||
          video.sourceVideoStartTime.numerator != audio.sourceStartSample ||
          video.sourceVideoStartTime.denominator != sampleRate) {
        throw const MediaContractException(
          'Audio and video event timing must correspond.',
        );
      }
    }
  }

  factory Arrangement.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw MediaContractException(
        'Unsupported arrangement schema: ${json['schemaVersion']}.',
      );
    }
    final sourceValues = json['sourceAssetIds'];
    final unusableValues = json['unusableAssetIds'];
    final eventValues = json['events'];
    final videoEventValues = json['videoEvents'];
    if (sourceValues is! List<Object?> ||
        unusableValues is! List<Object?> ||
        eventValues is! List<Object?> ||
        videoEventValues is! List<Object?>) {
      throw const MediaContractException('Malformed arrangement JSON.');
    }
    if (sourceValues.length > 6 ||
        unusableValues.length > 6 ||
        eventValues.length > 64 ||
        videoEventValues.length > 64) {
      throw const MediaContractException('Arrangement exceeds schema limits.');
    }
    try {
      return Arrangement(
        templateId: json['templateId'] as String,
        templateVersion: json['templateVersion'] as int,
        analysisVersion: json['analysisVersion'] as int,
        rendererVersion: json['rendererVersion'] as int,
        seed: json['seed'] as int,
        style: ArrangementStyle.values.byName(json['style'] as String),
        melodyTemplate: MelodyTemplate.values.byName(
          json['melodyTemplate'] as String? ?? MelodyTemplate.none.name,
        ),
        songRoles: json['songRoles'] is Map<Object?, Object?>
            ? SongRoles.fromJson(
                (json['songRoles'] as Map<Object?, Object?>).cast(),
              )
            : null,
        sourceAssetIds: sourceValues.cast<String>(),
        unusableAssetIds: unusableValues.cast<String>(),
        events: eventValues
            .map(
              (value) =>
                  SoundEvent.fromJson((value as Map<Object?, Object?>).cast()),
            )
            .toList(),
        videoEvents: videoEventValues
            .map(
              (value) =>
                  VideoEvent.fromJson((value as Map<Object?, Object?>).cast()),
            )
            .toList(),
        sampleRate: json['sampleRate'] as int,
        totalSamples: json['totalSamples'] as int,
      );
    } on TypeError {
      throw const MediaContractException('Malformed arrangement JSON.');
    }
  }

  static const int schemaVersion = 1;
  static const int barSamples = 90000;
  static const int beatSamples = 22500;
  final int sampleRate;
  final int totalSamples;
  final String templateId;
  final int templateVersion;
  final int analysisVersion;
  final int rendererVersion;
  final int seed;
  final ArrangementStyle style;
  final MelodyTemplate melodyTemplate;
  final SongRoles? songRoles;
  final List<String> sourceAssetIds;
  final List<String> unusableAssetIds;
  final List<SoundEvent> events;
  final List<VideoEvent> videoEvents;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'sampleRate': sampleRate,
    'totalSamples': totalSamples,
    'templateId': templateId,
    'templateVersion': templateVersion,
    'analysisVersion': analysisVersion,
    'rendererVersion': rendererVersion,
    'seed': seed,
    'style': style.name,
    if (melodyTemplate != MelodyTemplate.none)
      'melodyTemplate': melodyTemplate.name,
    if (songRoles != null) 'songRoles': songRoles!.toJson(),
    'sourceAssetIds': sourceAssetIds,
    'unusableAssetIds': unusableAssetIds,
    'events': events.map((event) => event.toJson()).toList(),
    'videoEvents': videoEvents.map((event) => event.toJson()).toList(),
  };
}

bool _validCrop(NormalizedCrop crop) =>
    crop.x.isFinite &&
    crop.y.isFinite &&
    crop.width.isFinite &&
    crop.height.isFinite &&
    crop.x >= 0 &&
    crop.y >= 0 &&
    crop.width > 0 &&
    crop.height > 0 &&
    crop.x + crop.width <= 1 &&
    crop.y + crop.height <= 1;
