import 'dart:convert';
import 'dart:math';

import '../domain/project.dart';
import 'project_database.dart';

abstract interface class ProjectRepository {
  Future<Project> create(String title);
  Future<Project?> load(String id);
  Future<void> save(Project project, {required int expectedRevision});
  Future<void> deleteProject(String id);
  Future<List<Project>> list();
}

final class SqliteProjectRepository implements ProjectRepository {
  const SqliteProjectRepository(this._database);

  final ProjectDatabase _database;

  @override
  Future<Project> create(String title) async {
    final project = Project.empty(id: _newUuid(), title: title);
    _database.transaction(() {
      _database.connection.execute(
        '''
        INSERT INTO projects (
          id, title, revision, arrangement_json, video_recipe_json,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          project.id,
          project.title,
          project.revision,
          jsonEncode(project.arrangement),
          jsonEncode(project.videoRecipe),
          project.createdAt.toIso8601String(),
          project.updatedAt.toIso8601String(),
        ],
      );
    });
    return project;
  }

  @override
  Future<Project?> load(String id) async {
    final rows = _database.connection.select(
      'SELECT * FROM projects WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _decode(rows.single);
  }

  @override
  Future<void> save(Project project, {required int expectedRevision}) async {
    if (project.revision != expectedRevision + 1) {
      throw ProjectValidationException(
        'Saved revision must be exactly ${expectedRevision + 1}.',
      );
    }
    _database.transaction(() {
      final rows = _database.connection.select(
        'SELECT revision FROM projects WHERE id = ?',
        <Object?>[project.id],
      );
      if (rows.isEmpty) {
        throw ProjectNotFound(project.id);
      }
      final actualRevision = rows.single['revision'] as int;
      if (actualRevision != expectedRevision) {
        throw RevisionConflict(
          projectId: project.id,
          expectedRevision: expectedRevision,
          actualRevision: actualRevision,
        );
      }
      _database.connection
        ..execute(
          '''
          UPDATE projects SET
            title = ?, revision = ?, arrangement_json = ?,
            video_recipe_json = ?, updated_at = ?
          WHERE id = ? AND revision = ?
          ''',
          <Object?>[
            project.title,
            project.revision,
            jsonEncode(project.arrangement),
            jsonEncode(project.videoRecipe),
            project.updatedAt.toUtc().toIso8601String(),
            project.id,
            expectedRevision,
          ],
        )
        ..execute('DELETE FROM project_assets WHERE project_id = ?', <Object?>[
          project.id,
        ]);
      for (var position = 0; position < project.clipIds.length; position++) {
        _database.connection.execute(
          '''
          INSERT INTO project_assets (project_id, asset_id, position)
          VALUES (?, ?, ?)
          ''',
          <Object?>[project.id, project.clipIds[position], position],
        );
      }
    });
  }

  @override
  Future<void> deleteProject(String id) async {
    _database.transaction(() {
      _database.connection.execute(
        'DELETE FROM projects WHERE id = ?',
        <Object?>[id],
      );
    });
  }

  @override
  Future<List<Project>> list() async {
    final rows = _database.connection.select(
      'SELECT * FROM projects ORDER BY updated_at DESC, id',
    );
    return rows.map(_decode).toList(growable: false);
  }

  Project _decode(Map<String, Object?> row) {
    final clipIds = _database.connection
        .select(
          '''
          SELECT asset_id FROM project_assets
          WHERE project_id = ? ORDER BY position
          ''',
          <Object?>[row['id']],
        )
        .map((clip) => clip['asset_id'] as String)
        .toList(growable: false);
    return Project(
      id: row['id'] as String,
      title: row['title'] as String,
      revision: row['revision'] as int,
      clipIds: clipIds,
      arrangement: _decodeMap(row['arrangement_json'] as String),
      videoRecipe: _decodeMap(row['video_recipe_json'] as String),
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
    );
  }
}

Map<String, Object?> _decodeMap(String source) {
  final decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Expected a JSON object.');
  }
  return decoded;
}

String _newUuid() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

final class RevisionConflict implements Exception {
  const RevisionConflict({
    required this.projectId,
    required this.expectedRevision,
    required this.actualRevision,
  });

  final String projectId;
  final int expectedRevision;
  final int actualRevision;

  @override
  String toString() =>
      'RevisionConflict(projectId: $projectId, expected: '
      '$expectedRevision, actual: $actualRevision)';
}

final class ProjectNotFound implements Exception {
  const ProjectNotFound(this.projectId);
  final String projectId;
}
