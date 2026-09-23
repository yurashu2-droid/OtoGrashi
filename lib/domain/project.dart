import 'dart:collection';

final class Project {
  Project({
    required this.id,
    required this.title,
    required this.revision,
    required List<String> clipIds,
    required Map<String, Object?> arrangement,
    required Map<String, Object?> videoRecipe,
    required this.createdAt,
    required this.updatedAt,
  }) : clipIds = List<String>.unmodifiable(clipIds),
       arrangement = _freezeMap(arrangement),
       videoRecipe = _freezeMap(videoRecipe) {
    if (id.isEmpty) {
      throw const ProjectValidationException('Project id cannot be empty.');
    }
    if (title.length > 80) {
      throw const ProjectValidationException(
        'Project title cannot exceed 80 characters.',
      );
    }
    if (revision < 0) {
      throw const ProjectValidationException('Revision cannot be negative.');
    }
    if (clipIds.length > 6) {
      throw const ProjectValidationException(
        'A project can contain at most 6 clips.',
      );
    }
    if (clipIds.toSet().length != clipIds.length) {
      throw const ProjectValidationException(
        'A clip can only appear once in a project.',
      );
    }
    _validateVersionedJson(this.arrangement, 'arrangement');
    _validateVersionedJson(this.videoRecipe, 'videoRecipe');
  }

  factory Project.empty({
    required String id,
    required String title,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).toUtc();
    return Project(
      id: id,
      title: title,
      revision: 0,
      clipIds: const <String>[],
      arrangement: const <String, Object?>{'schemaVersion': 1},
      videoRecipe: const <String, Object?>{'schemaVersion': 1},
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  final String id;
  final String title;
  final int revision;
  final List<String> clipIds;
  final Map<String, Object?> arrangement;
  final Map<String, Object?> videoRecipe;
  final DateTime createdAt;
  final DateTime updatedAt;

  Project copyWith({
    String? title,
    int? revision,
    List<String>? clipIds,
    Map<String, Object?>? arrangement,
    Map<String, Object?>? videoRecipe,
    DateTime? updatedAt,
  }) => Project(
    id: id,
    title: title ?? this.title,
    revision: revision ?? this.revision,
    clipIds: clipIds ?? this.clipIds,
    arrangement: arrangement ?? this.arrangement,
    videoRecipe: videoRecipe ?? this.videoRecipe,
    createdAt: createdAt,
    updatedAt: (updatedAt ?? this.updatedAt).toUtc(),
  );
}

final class ProjectValidationException implements Exception {
  const ProjectValidationException(this.message);

  final String message;

  @override
  String toString() => 'ProjectValidationException: $message';
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) {
  return UnmodifiableMapView<String, Object?>(
    source.map((key, value) => MapEntry(key, _freezeJson(value))),
  );
}

Object? _freezeJson(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freezeJson));
  }
  if (value is Map<String, Object?>) {
    return _freezeMap(value);
  }
  throw ProjectValidationException(
    'Unsupported JSON value: ${value.runtimeType}.',
  );
}

void _validateVersionedJson(Map<String, Object?> value, String field) {
  final version = value['schemaVersion'];
  if (version is! int || version < 1) {
    throw ProjectValidationException(
      '$field must have a positive schemaVersion.',
    );
  }
}
