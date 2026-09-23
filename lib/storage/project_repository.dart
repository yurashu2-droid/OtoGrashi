import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../domain/project.dart';
import 'project_database.dart';

abstract interface class ProjectRepository {
  Future<Project> create(String title);
  Future<Project?> load(String id);
  Future<void> save(Project project, {required int expectedRevision});
  Future<void> deleteProject(String id);
  Future<List<Project>> list();
}

final class CompletedExport {
  const CompletedExport({
    required this.id,
    required this.projectId,
    required this.sourceRevision,
    required this.relativePath,
    required this.createdAt,
  });

  final String id;
  final String projectId;
  final int sourceRevision;
  final String relativePath;
  final DateTime createdAt;
}

enum ExportJobStatus { queued, rendering, completed, recovered, failed }

final class ExportJob {
  const ExportJob({
    required this.id,
    required this.projectId,
    required this.sourceRevision,
    required this.status,
    required this.temporaryRelativePath,
    required this.updatedAt,
  });

  final String id;
  final String projectId;
  final int sourceRevision;
  final ExportJobStatus status;
  final String? temporaryRelativePath;
  final DateTime updatedAt;
}

final class StorageUsage {
  const StorageUsage({
    required this.originalsBytes,
    required this.completedBytes,
    required this.cacheBytes,
  });

  final int originalsBytes;
  final int completedBytes;
  final int cacheBytes;
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
          created_at, updated_at, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
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
      'SELECT * FROM projects WHERE id = ? AND deleted_at IS NULL',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
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
        'SELECT revision, deleted_at FROM projects WHERE id = ?',
        <Object?>[project.id],
      );
      if (rows.isEmpty || rows.single['deleted_at'] != null) {
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
            video_recipe_json = ?, updated_at = ?, deleted_at = NULL
          WHERE id = ? AND revision = ? AND deleted_at IS NULL
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

  /// Moves a project to recoverable trash. Its assets and exports stay intact.
  @override
  Future<void> deleteProject(String id) async {
    _database.transaction(() {
      final rows = _database.connection.select(
        'SELECT * FROM projects WHERE id = ?',
        <Object?>[id],
      );
      if (rows.isEmpty) return;
      final row = rows.single;
      _database.connection.execute(
        '''
        INSERT OR REPLACE INTO deleted_projects (
          id, title, revision, arrangement_json, video_recipe_json,
          created_at, updated_at, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          row['id'],
          row['title'],
          row['revision'],
          row['arrangement_json'],
          row['video_recipe_json'],
          row['created_at'],
          row['updated_at'],
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      _database.connection.execute(
        'DELETE FROM deleted_project_assets WHERE project_id = ?',
        <Object?>[id],
      );
      _database.connection.execute(
        '''
        INSERT INTO deleted_project_assets (project_id, asset_id, position)
        SELECT project_id, asset_id, position FROM project_assets
        WHERE project_id = ?
        ''',
        <Object?>[id],
      );
      _database.connection.execute(
        'DELETE FROM deleted_project_exports WHERE project_id = ?',
        <Object?>[id],
      );
      _database.connection.execute(
        '''
        INSERT INTO deleted_project_exports (
          id, project_id, source_revision, relative_path, created_at
        )
        SELECT id, project_id, source_revision, relative_path, created_at
        FROM completed_exports WHERE project_id = ?
        ''',
        <Object?>[id],
      );
      _database.connection.execute(
        'DELETE FROM projects WHERE id = ?',
        <Object?>[id],
      );
    });
  }

  Future<void> restoreProject(String id) async {
    _database.transaction(() {
      final rows = _database.connection.select(
        'SELECT * FROM deleted_projects WHERE id = ?',
        <Object?>[id],
      );
      if (rows.isEmpty) throw ProjectNotFound(id);
      final row = rows.single;
      _database.connection.execute(
        '''
        INSERT INTO projects (
          id, title, revision, arrangement_json, video_recipe_json,
          created_at, updated_at, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
        ''',
        <Object?>[
          row['id'],
          row['title'],
          row['revision'],
          row['arrangement_json'],
          row['video_recipe_json'],
          row['created_at'],
          row['updated_at'],
        ],
      );
      _database.connection.execute(
        '''
        INSERT INTO project_assets (project_id, asset_id, position)
        SELECT project_id, asset_id, position FROM deleted_project_assets
        WHERE project_id = ?
        ''',
        <Object?>[id],
      );
      _database.connection.execute(
        '''
        INSERT INTO completed_exports (
          id, project_id, source_revision, relative_path, created_at
        )
        SELECT id, project_id, source_revision, relative_path, created_at
        FROM deleted_project_exports WHERE project_id = ?
        ''',
        <Object?>[id],
      );
      _database.connection.execute(
        'DELETE FROM deleted_project_assets WHERE project_id = ?',
        <Object?>[id],
      );
      _database.connection.execute(
        'DELETE FROM deleted_project_exports WHERE project_id = ?',
        <Object?>[id],
      );
      _database.connection.execute(
        'DELETE FROM deleted_projects WHERE id = ?',
        <Object?>[id],
      );
    });
  }

  Future<List<Project>> listDeleted() async {
    final rows = _database.connection.select(
      'SELECT * FROM deleted_projects ORDER BY deleted_at DESC, id',
    );
    return rows.map(_decodeDeleted).toList(growable: false);
  }

  @override
  Future<List<Project>> list() async {
    final rows = _database.connection.select(
      'SELECT * FROM projects WHERE deleted_at IS NULL '
      'ORDER BY updated_at DESC, id',
    );
    return rows.map(_decode).toList(growable: false);
  }

  Future<Project> duplicateProject(String projectId, {String? title}) async {
    final source = await load(projectId);
    if (source == null) throw ProjectNotFound(projectId);
    final copy = Project(
      id: _newUuid(),
      title: title ?? '${source.title} のコピー',
      revision: 0,
      clipIds: source.clipIds,
      arrangement: source.arrangement,
      videoRecipe: source.videoRecipe,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    _database.transaction(() {
      _database.connection.execute(
        '''
        INSERT INTO projects (
          id, title, revision, arrangement_json, video_recipe_json,
          created_at, updated_at, deleted_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
        ''',
        <Object?>[
          copy.id,
          copy.title,
          copy.revision,
          jsonEncode(copy.arrangement),
          jsonEncode(copy.videoRecipe),
          copy.createdAt.toIso8601String(),
          copy.updatedAt.toIso8601String(),
        ],
      );
      for (var position = 0; position < copy.clipIds.length; position++) {
        _database.connection.execute(
          'INSERT INTO project_assets (project_id, asset_id, position) VALUES (?, ?, ?)',
          <Object?>[copy.id, copy.clipIds[position], position],
        );
      }
    });
    return copy;
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

  Project _decodeDeleted(Map<String, Object?> row) {
    final clipIds = _database.connection
        .select(
          'SELECT asset_id FROM deleted_project_assets '
          'WHERE project_id = ? ORDER BY position',
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

  Future<CompletedExport> recordCompletedExport({
    required String projectId,
    required int sourceRevision,
    required String relativePath,
    String? id,
    DateTime? createdAt,
  }) async {
    _validateRenderPath(relativePath);
    final export = CompletedExport(
      id: id ?? _newUuid(),
      projectId: projectId,
      sourceRevision: sourceRevision,
      relativePath: relativePath,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
    );
    _database.transaction(() {
      final project = _database.connection.select(
        'SELECT id FROM projects WHERE id = ?',
        <Object?>[projectId],
      );
      if (project.isEmpty) throw ProjectNotFound(projectId);
      _database.connection.execute(
        '''
        INSERT INTO completed_exports (
          id, project_id, source_revision, relative_path, created_at
        ) VALUES (?, ?, ?, ?, ?)
        ''',
        <Object?>[
          export.id,
          export.projectId,
          export.sourceRevision,
          export.relativePath,
          export.createdAt.toIso8601String(),
        ],
      );
    });
    return export;
  }

  Future<List<CompletedExport>> listCompletedExports([String? projectId]) async {
    final rows = projectId == null
        ? _database.connection.select(
            'SELECT * FROM completed_exports ORDER BY created_at DESC, id',
          )
        : _database.connection.select(
            'SELECT * FROM completed_exports WHERE project_id = ? '
            'ORDER BY created_at DESC, id',
            <Object?>[projectId],
          );
    return rows
        .map(
          (row) => CompletedExport(
            id: row['id'] as String,
            projectId: row['project_id'] as String,
            sourceRevision: row['source_revision'] as int,
            relativePath: row['relative_path'] as String,
            createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
          ),
        )
        .toList(growable: false);
  }

  Future<ExportJob> startExportJob({
    required String projectId,
    required int sourceRevision,
    required String temporaryRelativePath,
    String? id,
    ExportJobStatus status = ExportJobStatus.queued,
  }) async {
    if (!temporaryRelativePath.startsWith('staging/') ||
        temporaryRelativePath.contains('\\') ||
        temporaryRelativePath.split('/').contains('..')) {
      throw const ProjectValidationException(
        'Temporary export paths must stay inside staging.',
      );
    }
    final job = ExportJob(
      id: id ?? _newUuid(),
      projectId: projectId,
      sourceRevision: sourceRevision,
      status: status,
      temporaryRelativePath: temporaryRelativePath,
      updatedAt: DateTime.now().toUtc(),
    );
    _database.transaction(() {
      _database.connection.execute(
        '''
        INSERT INTO export_jobs (
          id, project_id, source_revision, status, temporary_relative_path, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
        ''',
        <Object?>[
          job.id,
          job.projectId,
          job.sourceRevision,
          job.status.name,
          job.temporaryRelativePath,
          job.updatedAt.toIso8601String(),
        ],
      );
    });
    return job;
  }

  Future<void> finishExportJob(String id, {required bool success}) async {
    _database.transaction(() {
      _database.connection.execute(
        'UPDATE export_jobs SET status = ?, temporary_relative_path = NULL, '
        'updated_at = ? WHERE id = ?',
        <Object?>[
          success ? ExportJobStatus.completed.name : ExportJobStatus.failed.name,
          DateTime.now().toUtc().toIso8601String(),
          id,
        ],
      );
    });
  }

  Future<List<ExportJob>> listIncompleteExportJobs() async {
    final rows = _database.connection.select(
      "SELECT * FROM export_jobs WHERE status IN ('queued', 'rendering') "
      'ORDER BY updated_at DESC, id',
    );
    return rows.map(_decodeExportJob).toList(growable: false);
  }

  Future<StorageUsage> storageUsage() async {
    final originals = await _directoryBytes(_database.originalsDirectory);
    final analysisCache = await _directoryBytes(_database.analysisCacheDirectory);
    final completed = await listCompletedExports();
    final protectedPaths = completed.map((item) => item.relativePath).toSet();
    final renders = Directory(p.join(_database.rootDirectory.path, 'renders'));
    var completedBytes = 0;
    var renderBytes = 0;
    if (await renders.exists()) {
      await for (final entity in renders.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p
            .relative(entity.path, from: _database.rootDirectory.path)
            .replaceAll('\\', '/');
        final size = await entity.length();
        if (protectedPaths.contains(relative)) {
          completedBytes += size;
        } else {
          renderBytes += size;
        }
      }
    }
    return StorageUsage(
      originalsBytes: originals,
      completedBytes: completedBytes,
      cacheBytes: analysisCache + renderBytes,
    );
  }

  Future<void> clearRegenerableCache() async {
    if (await _database.analysisCacheDirectory.exists()) {
      await for (final entity in _database.analysisCacheDirectory.list(
        followLinks: false,
      )) {
        await entity.delete(recursive: true);
      }
    }
    final protectedPaths = (await listCompletedExports())
        .map((item) => item.relativePath)
        .toSet();
    final renders = Directory(p.join(_database.rootDirectory.path, 'renders'));
    if (!await renders.exists()) return;
    await for (final entity in renders.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: _database.rootDirectory.path)
          .replaceAll('\\', '/');
      if (!protectedPaths.contains(relative)) await entity.delete();
    }
  }

  ExportJob _decodeExportJob(Map<String, Object?> row) => ExportJob(
    id: row['id'] as String,
    projectId: row['project_id'] as String,
    sourceRevision: row['source_revision'] as int,
    status: ExportJobStatus.values.byName(row['status'] as String),
    temporaryRelativePath: row['temporary_relative_path'] as String?,
    updatedAt: DateTime.parse(row['updated_at'] as String).toUtc(),
  );
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

void _validateRenderPath(String relativePath) {
  if (!relativePath.startsWith('renders/') ||
      relativePath.contains('\\') ||
      relativePath.split('/').contains('..') ||
      relativePath.split('/').any((part) => part.isEmpty)) {
    throw const ProjectValidationException(
      'Completed export paths must stay inside renders.',
    );
  }
}

Future<int> _directoryBytes(Directory directory) async {
  if (!await directory.exists()) return 0;
  var total = 0;
  await for (final entity in directory.list(recursive: true, followLinks: false)) {
    if (entity is File) total += await entity.length();
  }
  return total;
}
