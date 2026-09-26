import 'arrangement.dart';
import 'melody_template.dart';

enum VideoLayout { buildUp, stacked, sequentialFocus, photoDump }

final class VideoEffects {
  const VideoEffects._(this.enabled);

  static const none = VideoEffects._(<String>[]);
  static const mad = VideoEffects._(['mirrorCuts', 'beatPunch', 'echoTiles']);
  static const supported = {'mirrorCuts', 'beatPunch', 'echoTiles'};

  final List<String> enabled;

  factory VideoEffects.fromJson(Map<String, Object?> json) {
    final values = json['enabled'];
    if (values is! List<Object?> ||
        values.length > supported.length ||
        values.any((value) => !supported.contains(value)) ||
        values.toSet().length != values.length) {
      throw const MediaContractException('Unknown or duplicate video effect.');
    }
    return values.isEmpty
        ? none
        : VideoEffects._(List<String>.unmodifiable(values.cast<String>()));
  }

  Map<String, Object?> toJson() => <String, Object?>{'enabled': enabled};
}

final class ClipCrop {
  const ClipCrop({required this.assetId, required this.crop});

  final String assetId;
  final NormalizedCrop crop;

  factory ClipCrop.fromJson(Map<String, Object?> json) => ClipCrop(
    assetId: json['assetId'] as String,
    crop: NormalizedCrop.fromJson(
      (json['crop'] as Map<Object?, Object?>).cast(),
    ),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'assetId': assetId,
    'crop': crop.toJson(),
  };
}

final class VideoCaption {
  const VideoCaption({
    required this.text,
    required this.x,
    required this.y,
    required this.destinationStartSample,
    required this.durationSamples,
  });

  final String text;
  final double x;
  final double y;
  final int destinationStartSample;
  final int durationSamples;

  int get destinationEndSample => destinationStartSample + durationSamples;

  factory VideoCaption.fromJson(Map<String, Object?> json) => VideoCaption(
    text: json['text'] as String,
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    destinationStartSample: json['destinationStartSample'] as int,
    durationSamples: json['durationSamples'] as int,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'text': text,
    'x': x,
    'y': y,
    'destinationStartSample': destinationStartSample,
    'durationSamples': durationSamples,
  };
}

final class VideoSceneEvent {
  VideoSceneEvent({
    required this.destinationStartSample,
    required this.durationSamples,
    required List<String> assetIds,
    this.primaryAssetId,
  }) : assetIds = List<String>.unmodifiable(assetIds);

  final int destinationStartSample;
  final int durationSamples;
  final List<String> assetIds;
  final String? primaryAssetId;

  int get destinationEndSample => destinationStartSample + durationSamples;

  factory VideoSceneEvent.fromJson(Map<String, Object?> json) =>
      VideoSceneEvent(
        destinationStartSample: json['destinationStartSample'] as int,
        durationSamples: json['durationSamples'] as int,
        assetIds: (json['assetIds'] as List<Object?>).cast<String>(),
        primaryAssetId: json['primaryAssetId'] as String?,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'destinationStartSample': destinationStartSample,
    'durationSamples': durationSamples,
    'assetIds': assetIds,
    'primaryAssetId': primaryAssetId,
  };
}

final class VideoRecipe {
  VideoRecipe({
    required this.layout,
    required List<ClipCrop> clipCrops,
    required List<VideoCaption> captions,
    required List<VideoSceneEvent> events,
    Map<String, String> clipNames = const <String, String>{},
    this.effects = VideoEffects.none,
    this.totalSamples = 720000,
    this.ownerName,
  }) : clipCrops = List<ClipCrop>.unmodifiable(clipCrops),
       captions = List<VideoCaption>.unmodifiable(captions),
       events = List<VideoSceneEvent>.unmodifiable(events),
       clipNames = Map<String, String>.unmodifiable(clipNames) {
    if (!const [720000, 1440000].contains(totalSamples) ||
        clipCrops.length > 6 ||
        captions.length > 12 ||
        events.length > maxScenes) {
      throw const MediaContractException('Video recipe exceeds schema limits.');
    }
    final cropIds = clipCrops.map((value) => value.assetId).toList();
    if (cropIds.isEmpty || cropIds.toSet().length != cropIds.length) {
      throw const MediaContractException('Video recipe crops are invalid.');
    }
    if (clipNames.length > 6 ||
        clipNames.entries.any(
          (entry) =>
              !cropIds.contains(entry.key) ||
              entry.value.trim().isEmpty ||
              entry.value.runes.length > 40,
        )) {
      throw const MediaContractException(
        'Video recipe sound names are invalid.',
      );
    }
    if (ownerName != null &&
        (ownerName!.trim().isEmpty || ownerName!.runes.length > 20)) {
      throw const MediaContractException('Video recipe owner name is invalid.');
    }
    if (clipCrops.any((value) => !_validCrop(value.crop)) ||
        captions.any(
          (value) =>
              value.text.length > 80 ||
              !value.x.isFinite ||
              !value.y.isFinite ||
              value.x < 0 ||
              value.x > 1 ||
              value.y < 0 ||
              value.y > 1 ||
              value.destinationStartSample < 0 ||
              value.durationSamples <= 0 ||
              value.destinationEndSample > totalSamples,
        ) ||
        events.isEmpty ||
        events.first.destinationStartSample != 0 ||
        events.last.destinationEndSample != totalSamples ||
        events.any(
          (value) =>
              value.destinationStartSample < 0 ||
              value.durationSamples <= 0 ||
              value.destinationEndSample > totalSamples ||
              value.assetIds.isEmpty ||
              value.assetIds.length > 6 ||
              value.assetIds.toSet().length != value.assetIds.length ||
              value.assetIds.any((id) => !cropIds.contains(id)) ||
              (value.primaryAssetId != null &&
                  !value.assetIds.contains(value.primaryAssetId)),
        )) {
      throw const MediaContractException('Video recipe is out of range.');
    }
    for (var index = 1; index < events.length; index++) {
      if (events[index - 1].destinationEndSample !=
          events[index].destinationStartSample) {
        throw const MediaContractException('Video scenes must be contiguous.');
      }
    }
  }

  factory VideoRecipe.fromArrangement({
    required Arrangement arrangement,
    required VideoLayout layout,
  }) {
    final ids = arrangement.sourceAssetIds;
    if (ids.isEmpty || ids.length > 6) {
      throw const MediaContractException(
        'Video recipes require 1 to 6 sources.',
      );
    }
    final usableIds = ids
        .where((id) => !arrangement.unusableAssetIds.contains(id))
        .toList(growable: false);
    if (usableIds.isEmpty) {
      throw const MediaContractException(
        'Video recipes require an audible source.',
      );
    }
    final roles = arrangement.songRoles;
    final visibleIds = <String>{
      if (roles?.beat != null) roles!.beat!,
      if (roles?.bass != null) roles!.bass!,
      if (roles?.keys != null) roles!.keys!,
      ...usableIds,
    }.toList(growable: false);
    return VideoRecipe(
      layout: layout,
      totalSamples: arrangement.totalSamples,
      clipCrops: ids
          .map((id) => ClipCrop(assetId: id, crop: NormalizedCrop.fullFrame))
          .toList(),
      captions: const <VideoCaption>[],
      events: arrangement.events.isEmpty
          ? _buildScenes(visibleIds, layout, arrangement.events, roles)
          : _audioScenes(
              arrangement.events,
              visibleIds,
              arrangement.totalSamples,
            ),
      effects: arrangement.events.isEmpty
          ? VideoEffects.none
          : VideoEffects.mad,
    );
  }

  factory VideoRecipe.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw MediaContractException(
        'Unsupported video recipe schema: ${json['schemaVersion']}.',
      );
    }
    try {
      final cropValues = json['clipCrops'] as List<Object?>;
      final captionValues = json['captions'] as List<Object?>;
      final eventValues = json['events'] as List<Object?>;
      if (cropValues.length > 6 ||
          captionValues.length > 12 ||
          eventValues.length > maxScenes) {
        throw const MediaContractException(
          'Video recipe exceeds schema limits.',
        );
      }
      final effectsJson = json['effects'];
      return VideoRecipe(
        layout: VideoLayout.values.byName(json['layout'] as String),
        totalSamples: json['totalSamples'] as int? ?? 720000,
        clipCrops: cropValues
            .map(
              (value) =>
                  ClipCrop.fromJson((value as Map<Object?, Object?>).cast()),
            )
            .toList(),
        captions: captionValues
            .map(
              (value) => VideoCaption.fromJson(
                (value as Map<Object?, Object?>).cast(),
              ),
            )
            .toList(),
        events: eventValues
            .map(
              (value) => VideoSceneEvent.fromJson(
                (value as Map<Object?, Object?>).cast(),
              ),
            )
            .toList(),
        clipNames:
            (json['clipNames'] as Map<Object?, Object?>? ??
                    const <Object?, Object?>{})
                .cast<String, String>(),
        effects: effectsJson == null
            ? VideoEffects.none
            : VideoEffects.fromJson(
                (effectsJson as Map<Object?, Object?>).cast(),
              ),
        ownerName: json['ownerName'] as String?,
      );
    } on TypeError {
      throw const MediaContractException('Malformed video recipe JSON.');
    } on ArgumentError {
      throw const MediaContractException('Unsupported video layout.');
    }
  }

  static const int maxScenes = Arrangement.maxEvents * 2 + 1;
  static const int schemaVersion = 1;
  static const int framesPerSecond = 30;
  final VideoLayout layout;
  final int totalSamples;
  final List<ClipCrop> clipCrops;
  final List<VideoCaption> captions;
  final List<VideoSceneEvent> events;
  final Map<String, String> clipNames;
  final VideoEffects effects;

  /// Whose everyday this is: the cover of a MAD reads "〇〇の日常".
  final String? ownerName;

  static int nearestFrameForSample(int sample) {
    if (sample < 0 || sample > 1440000) {
      throw const MediaContractException('Video sample is out of range.');
    }
    return (sample * framesPerSecond + 24000) ~/ 48000;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    if (totalSamples != 720000) 'totalSamples': totalSamples,
    'layout': layout.name,
    'clipCrops': clipCrops.map((value) => value.toJson()).toList(),
    'captions': captions.map((value) => value.toJson()).toList(),
    'events': events.map((value) => value.toJson()).toList(),
    'clipNames': clipNames,
    'effects': effects.toJson(),
    if (ownerName != null) 'ownerName': ownerName,
  };
}

abstract final class ArrangementPayloadClock {
  static const int totalSamples = 720000;
}

List<VideoSceneEvent> _buildScenes(
  List<String> ids,
  VideoLayout layout,
  List<SoundEvent> sounds,
  SongRoles? roles,
) {
  switch (layout) {
    case VideoLayout.buildUp:
      final introduced = ids.take(3).toSet();
      return List<VideoSceneEvent>.generate(8, (bar) {
        final start = bar * Arrangement.barSamples;
        final end = start + Arrangement.barSamples;
        final visible = <String>[];
        if (bar < 3) {
          final roleId = switch (bar) {
            0 => roles?.beat,
            1 => roles?.bass,
            _ => roles?.keys,
          };
          final sounding = sounds
              .where(
                (event) =>
                    event.destinationStartSample < end &&
                    event.destinationStartSample + event.durationSamples >
                        start,
              )
              .map((event) => event.assetId)
              .firstOrNull;
          visible.add(roleId ?? sounding ?? ids[bar % ids.length]);
        } else {
          visible.add(ids.first);
          final sounding = sounds
              .where(
                (event) =>
                    event.destinationStartSample < end &&
                    event.destinationStartSample + event.durationSamples >
                        start,
              )
              .map((event) => event.assetId)
              .where((id) => id != ids.first)
              .toSet()
              .toList(growable: false);
          final candidates = <String>[
            ...sounding.where((id) => !introduced.contains(id)),
            ...sounding,
            ...ids.skip(1).where((id) => !introduced.contains(id)),
            ...ids.skip(1),
          ];
          final count = bar < 5 ? 2 : 3;
          for (final id in candidates) {
            if (visible.length >= count) break;
            if (!visible.contains(id)) visible.add(id);
          }
          introduced.addAll(visible);
        }
        return VideoSceneEvent(
          destinationStartSample: start,
          durationSamples: Arrangement.barSamples,
          assetIds: visible,
          primaryAssetId: visible.first,
        );
      });
    case VideoLayout.stacked:
      if (ids.length <= 3) {
        return <VideoSceneEvent>[
          VideoSceneEvent(
            destinationStartSample: 0,
            durationSamples: ArrangementPayloadClock.totalSamples,
            assetIds: ids,
          ),
        ];
      }
      return <VideoSceneEvent>[
        VideoSceneEvent(
          destinationStartSample: 0,
          durationSamples: 360000,
          assetIds: ids.take(3).toList(),
        ),
        VideoSceneEvent(
          destinationStartSample: 360000,
          durationSamples: 360000,
          assetIds: ids.skip(3).toList(),
        ),
      ];
    case VideoLayout.sequentialFocus:
      return List<VideoSceneEvent>.generate(8, (index) {
        final id = ids[index * ids.length ~/ 8];
        return VideoSceneEvent(
          destinationStartSample: index * Arrangement.barSamples,
          durationSamples: Arrangement.barSamples,
          assetIds: <String>[id],
          primaryAssetId: id,
        );
      });
    case VideoLayout.photoDump:
      return List<VideoSceneEvent>.generate(4, (index) {
        final visible = <String>[
          for (var offset = 0; offset < 3; offset++)
            ids[(index * 2 + offset) % ids.length],
        ];
        return VideoSceneEvent(
          destinationStartSample: index * Arrangement.barSamples * 2,
          durationSamples: Arrangement.barSamples * 2,
          assetIds: visible.toSet().toList(),
          primaryAssetId: visible.first,
        );
      });
  }
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

// Scene boundaries are audio boundaries, not bars. A rest holds the last
// picture; the renderer freezes it instead of inventing an unrelated sound.
List<VideoSceneEvent> _audioScenes(
  List<SoundEvent> sounds,
  List<String> ids,
  int totalSamples,
) {
  final boundaries = <int>{0, totalSamples};
  for (final event in sounds) {
    boundaries.add(event.destinationStartSample);
    boundaries.add(event.destinationStartSample + event.durationSamples);
  }
  final times = boundaries.toList()..sort();
  final scenes = <VideoSceneEvent>[];
  var held = <String>[ids.first];
  for (var i = 0; i + 1 < times.length; i++) {
    final start = times[i];
    final active = sounds
        .where(
          (e) =>
              e.destinationStartSample <= start &&
              start < e.destinationStartSample + e.durationSamples,
        )
        .toList();
    active.sort((a, b) {
      final phraseA = a.treatment == SoundTreatment.phrase;
      final phraseB = b.treatment == SoundTreatment.phrase;
      if (phraseA != phraseB) return phraseA ? -1 : 1;
      final order = b.destinationStartSample.compareTo(
        a.destinationStartSample,
      );
      return order != 0 ? order : a.assetId.compareTo(b.assetId);
    });
    if (active.isNotEmpty) held = active.map((e) => e.assetId).toSet().toList();
    scenes.add(
      VideoSceneEvent(
        destinationStartSample: start,
        durationSamples: times[i + 1] - start,
        assetIds: held,
        primaryAssetId: held.first,
      ),
    );
  }
  return scenes;
}
