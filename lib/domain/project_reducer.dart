import 'project.dart';
import 'arrangement.dart';

sealed class ProjectEditCommand {
  const ProjectEditCommand();
}

final class RenameProject extends ProjectEditCommand {
  const RenameProject(this.title);
  final String title;
}

final class AddClip extends ProjectEditCommand {
  const AddClip(this.assetId);
  final String assetId;
}

final class RemoveClip extends ProjectEditCommand {
  const RemoveClip(this.assetId);
  final String assetId;
}

final class ReplaceClip extends ProjectEditCommand {
  const ReplaceClip(this.oldAssetId, this.newAssetId);
  final String oldAssetId;
  final String newAssetId;
}

final class ReorderClips extends ProjectEditCommand {
  const ReorderClips(this.assetIds);
  final List<String> assetIds;
}

final class SetArrangementJson extends ProjectEditCommand {
  const SetArrangementJson(this.value);
  final Map<String, Object?> value;
}

final class SetVideoRecipeJson extends ProjectEditCommand {
  const SetVideoRecipeJson(this.value);
  final Map<String, Object?> value;
}

final class SetGain extends ProjectEditCommand {
  const SetGain(this.assetId, this.gain);

  final String assetId;
  final double gain;
}

final class SetAccompanimentGain extends ProjectEditCommand {
  const SetAccompanimentGain(this.gain);

  final double gain;
}

final class SetCaption extends ProjectEditCommand {
  const SetCaption(
    this.text, {
    this.index = 0,
    this.x = .5,
    this.y = .9,
    this.destinationStartSample = 0,
    this.durationSamples = 720000,
  });

  final String text;
  final int index;
  final double x;
  final double y;
  final int destinationStartSample;
  final int durationSamples;
}

final class RemoveCaption extends ProjectEditCommand {
  const RemoveCaption(this.index);

  final int index;
}

final class SetCrop extends ProjectEditCommand {
  const SetCrop(this.assetId, this.crop);

  final String assetId;
  final NormalizedCrop crop;
}

final class SetTrim extends ProjectEditCommand {
  const SetTrim(this.assetId, this.startUs, this.durationUs);

  final String assetId;
  final int startUs;
  final int durationUs;
}

final class SelectStyle extends ProjectEditCommand {
  const SelectStyle(this.style);

  final ArrangementStyle style;
}

abstract final class ProjectReducer {
  static Project reduce(
    Project project,
    ProjectEditCommand command, {
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return switch (command) {
      RenameProject(:final title) => project.copyWith(
        title: title,
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      AddClip(:final assetId) => project.copyWith(
        clipIds: <String>[...project.clipIds, assetId],
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      RemoveClip(:final assetId) => project.copyWith(
        clipIds: project.clipIds.where((id) => id != assetId).toList(),
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      ReplaceClip(:final oldAssetId, :final newAssetId) => project.copyWith(
        clipIds: project.clipIds
            .map((id) => id == oldAssetId ? newAssetId : id)
            .toList(),
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      ReorderClips(:final assetIds) => _reorder(project, assetIds, timestamp),
      SetArrangementJson(:final value) => project.copyWith(
        arrangement: value,
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      SetVideoRecipeJson(:final value) => project.copyWith(
        videoRecipe: value,
        revision: project.revision + 1,
        updatedAt: timestamp,
      ),
      SetGain(:final assetId, :final gain) => _setGain(
        project,
        assetId,
        gain,
        timestamp,
      ),
      SetAccompanimentGain(:final gain) => _setAccompanimentGain(
        project,
        gain,
        timestamp,
      ),
      SetCaption(
        :final text,
        :final index,
        :final x,
        :final y,
        :final destinationStartSample,
        :final durationSamples,
      ) =>
        _setCaption(
          project,
          text: text,
          index: index,
          x: x,
          y: y,
          destinationStartSample: destinationStartSample,
          durationSamples: durationSamples,
          timestamp: timestamp,
        ),
      RemoveCaption(:final index) => _removeCaption(project, index, timestamp),
      SetCrop(:final assetId, :final crop) => _setCrop(
        project,
        assetId,
        crop,
        timestamp,
      ),
      SetTrim(:final assetId, :final startUs, :final durationUs) => _setTrim(
        project,
        assetId,
        startUs,
        durationUs,
        timestamp,
      ),
      SelectStyle(:final style) => _selectStyle(project, style, timestamp),
    };
  }

  static Project _reorder(
    Project project,
    List<String> assetIds,
    DateTime timestamp,
  ) {
    if (assetIds.length != project.clipIds.length ||
        !assetIds.toSet().containsAll(project.clipIds)) {
      throw const ProjectValidationException(
        'Reordering must retain exactly the current clips.',
      );
    }
    return project.copyWith(
      clipIds: assetIds,
      revision: project.revision + 1,
      updatedAt: timestamp,
    );
  }

  static Project _setGain(
    Project project,
    String assetId,
    double gain,
    DateTime timestamp,
  ) {
    _validateAssetId(assetId);
    _validateGain(gain);
    final arrangement = _mutableMap(project.arrangement);
    final edits = _mutableMap(arrangement['edits']);
    final gains = _mutableMap(edits['gains']);
    gains[assetId] = gain;
    edits['gains'] = gains;
    arrangement['edits'] = edits;
    final events = _mutableListOfMaps(arrangement['events']);
    for (final event in events) {
      if (event['assetId'] == assetId) event['gain'] = gain;
    }
    if (events.isNotEmpty) arrangement['events'] = events;
    return _edited(project, arrangement: arrangement, timestamp: timestamp);
  }

  static Project _setAccompanimentGain(
    Project project,
    double gain,
    DateTime timestamp,
  ) {
    _validateGain(gain);
    final arrangement = _mutableMap(project.arrangement);
    arrangement['accompanimentGain'] = gain;
    return _edited(project, arrangement: arrangement, timestamp: timestamp);
  }

  static Project _setCaption(
    Project project, {
    required String text,
    required int index,
    required double x,
    required double y,
    required int destinationStartSample,
    required int durationSamples,
    required DateTime timestamp,
  }) {
    _validateCaption(
      text,
      x: x,
      y: y,
      destinationStartSample: destinationStartSample,
      durationSamples: durationSamples,
      totalSamples: project.arrangement['totalSamples'] as int? ?? 720000,
    );
    final recipe = _mutableMap(project.videoRecipe);
    final captions = _mutableListOfMaps(recipe['captions']);
    if (index < 0 || index > captions.length) {
      throw const ProjectValidationException('Caption index is out of range.');
    }
    final caption = <String, Object?>{
      'text': text,
      'x': x,
      'y': y,
      'destinationStartSample': destinationStartSample,
      'durationSamples': durationSamples,
    };
    if (index == captions.length) {
      captions.add(caption);
    } else {
      captions[index] = caption;
    }
    if (captions.length > 12) {
      throw const ProjectValidationException(
        'A project can contain at most 12 captions.',
      );
    }
    recipe['captions'] = captions;
    return _edited(project, videoRecipe: recipe, timestamp: timestamp);
  }

  static Project _removeCaption(
    Project project,
    int index,
    DateTime timestamp,
  ) {
    final recipe = _mutableMap(project.videoRecipe);
    final captions = _mutableListOfMaps(recipe['captions']);
    if (index < 0 || index >= captions.length) {
      throw const ProjectValidationException('Caption index is out of range.');
    }
    captions.removeAt(index);
    recipe['captions'] = captions;
    return _edited(project, videoRecipe: recipe, timestamp: timestamp);
  }

  static Project _setCrop(
    Project project,
    String assetId,
    NormalizedCrop crop,
    DateTime timestamp,
  ) {
    _validateAssetId(assetId);
    if (!_validCrop(crop)) {
      throw const ProjectValidationException('Crop is out of range.');
    }
    final recipe = _mutableMap(project.videoRecipe);
    final crops = _mutableListOfMaps(recipe['clipCrops']);
    final cropJson = <String, Object?>{
      'assetId': assetId,
      'crop': crop.toJson(),
    };
    final index = crops.indexWhere((entry) => entry['assetId'] == assetId);
    if (index < 0) {
      if (crops.length >= 6) {
        throw const ProjectValidationException(
          'A project can contain at most 6 crops.',
        );
      }
      crops.add(cropJson);
    } else {
      crops[index] = cropJson;
    }
    recipe['clipCrops'] = crops;
    return _edited(project, videoRecipe: recipe, timestamp: timestamp);
  }

  static Project _setTrim(
    Project project,
    String assetId,
    int startUs,
    int durationUs,
    DateTime timestamp,
  ) {
    _validateAssetId(assetId);
    if (startUs < 0 || durationUs <= 0 || durationUs > 6000000) {
      throw const ProjectValidationException('Trim range is out of range.');
    }
    final arrangement = _mutableMap(project.arrangement);
    final edits = _mutableMap(arrangement['edits']);
    final windows = _mutableMap(edits['sourceWindows']);
    windows[assetId] = <String, Object?>{
      'startUs': startUs,
      'durationUs': durationUs,
    };
    edits['sourceWindows'] = windows;
    arrangement['edits'] = edits;
    final startSample = _microsecondsToSamples(startUs);
    final events = _mutableListOfMaps(arrangement['events']);
    for (final event in events) {
      if (event['assetId'] == assetId) event['sourceStartSample'] = startSample;
    }
    if (events.isNotEmpty) arrangement['events'] = events;
    final videoEvents = _mutableListOfMaps(arrangement['videoEvents']);
    for (final event in videoEvents) {
      if (event['assetId'] == assetId) {
        final source = _mutableMap(event['sourceVideoStartTime']);
        source['numerator'] = startSample;
        source['denominator'] = 48000;
        event['sourceVideoStartTime'] = source;
      }
    }
    if (videoEvents.isNotEmpty) arrangement['videoEvents'] = videoEvents;
    return _edited(project, arrangement: arrangement, timestamp: timestamp);
  }

  static Project _selectStyle(
    Project project,
    ArrangementStyle style,
    DateTime timestamp,
  ) {
    final arrangement = _mutableMap(project.arrangement);
    arrangement['style'] = style.name;
    return _edited(project, arrangement: arrangement, timestamp: timestamp);
  }

  static Project _edited(
    Project project, {
    Map<String, Object?>? arrangement,
    Map<String, Object?>? videoRecipe,
    required DateTime timestamp,
  }) => project.copyWith(
    arrangement: arrangement,
    videoRecipe: videoRecipe,
    revision: project.revision + 1,
    updatedAt: timestamp,
  );
}

Map<String, Object?> _mutableMap(Object? value) => value is Map
    ? value.map<String, Object?>(
        (key, value) => MapEntry('$key', _copyJson(value)),
      )
    : <String, Object?>{};

List<Map<String, Object?>> _mutableListOfMaps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => _mutableMap(item))
          .toList(growable: true)
    : <Map<String, Object?>>[];

Object? _copyJson(Object? value) {
  if (value is Map) return _mutableMap(value);
  if (value is List) return value.map(_copyJson).toList(growable: true);
  return value;
}

void _validateAssetId(String assetId) {
  if (assetId.isEmpty) {
    throw const ProjectValidationException('Asset id cannot be empty.');
  }
}

void _validateGain(double gain) {
  if (!gain.isFinite || gain < 0 || gain > 1) {
    throw const ProjectValidationException('Gain must be between 0 and 1.');
  }
}

void _validateCaption(
  String text, {
  required double x,
  required double y,
  required int destinationStartSample,
  required int durationSamples,
  int totalSamples = 720000,
}) {
  if (text.runes.length > 80 ||
      !x.isFinite ||
      !y.isFinite ||
      x < 0 ||
      x > 1 ||
      y < 0 ||
      y > 1 ||
      destinationStartSample < 0 ||
      durationSamples <= 0 ||
      destinationStartSample + durationSamples > totalSamples) {
    throw const ProjectValidationException('Caption is out of range.');
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

int _microsecondsToSamples(int value) => (value * 48000 / 1000000).round();
