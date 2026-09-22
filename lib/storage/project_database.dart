import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

final class ProjectDatabase {
  ProjectDatabase._(
    this._connection, {
    required this.rootDirectory,
    required this.databasePath,
    required this.originalsDirectory,
    required this.stagingDirectory,
    required this.analysisCacheDirectory,
  });

  static Future<ProjectDatabase> open(Directory rootDirectory) async {
    await rootDirectory.create(recursive: true);
    final originals = Directory(p.join(rootDirectory.path, 'originals'));
    final staging = Directory(p.join(rootDirectory.path, 'staging'));
    final analysisCache = Directory(
      p.join(rootDirectory.path, 'analysis-cache'),
    );
    await Future.wait(<Future<Directory>>[
      originals.create(recursive: true),
      staging.create(recursive: true),
      analysisCache.create(recursive: true),
    ]);
    final databasePath = p.join(rootDirectory.path, 'projects.sqlite3');
    final connection = sqlite3.open(databasePath);
    final database = ProjectDatabase._(
      connection,
      rootDirectory: rootDirectory,
      databasePath: databasePath,
      originalsDirectory: originals,
      stagingDirectory: staging,
      analysisCacheDirectory: analysisCache,
    );
    try {
      database._initializeSchema();
      await database._recoverManagedFiles();
      return database;
    } catch (_) {
      connection.close();
      rethrow;
    }
  }

  final Directory rootDirectory;
  final String databasePath;
  final Directory originalsDirectory;
  final Directory stagingDirectory;
  final Directory analysisCacheDirectory;
  final Database _connection;

  Database get connection => _connection;

  void close() => _connection.close();

  T transaction<T>(T Function() action) {
    _connection.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _connection.execute('COMMIT');
      return result;
    } catch (_) {
      _connection.execute('ROLLBACK');
      rethrow;
    }
  }

  void _initializeSchema() {
    _connection
      ..execute('PRAGMA foreign_keys = ON')
      ..execute('PRAGMA busy_timeout = 5000')
      ..execute('PRAGMA journal_mode = WAL')
      ..execute('''
        CREATE TABLE IF NOT EXISTS assets (
          id TEXT NOT NULL PRIMARY KEY,
          relative_path TEXT NOT NULL UNIQUE,
          duration_us INTEGER NOT NULL,
          selection_start_us INTEGER NOT NULL,
          selection_duration_us INTEGER NOT NULL,
          width INTEGER NOT NULL,
          height INTEGER NOT NULL,
          rotation INTEGER NOT NULL,
          sha256 TEXT NOT NULL,
          label TEXT NOT NULL
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT NOT NULL PRIMARY KEY,
          title TEXT NOT NULL,
          revision INTEGER NOT NULL,
          arrangement_json TEXT NOT NULL,
          video_recipe_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS project_assets (
          project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
          asset_id TEXT NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
          position INTEGER NOT NULL,
          PRIMARY KEY (project_id, asset_id),
          UNIQUE (project_id, position)
        ) STRICT
      ''')
      ..execute('''
        CREATE TABLE IF NOT EXISTS completed_exports (
          id TEXT NOT NULL PRIMARY KEY,
          project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
          source_revision INTEGER NOT NULL,
          relative_path TEXT NOT NULL,
          created_at TEXT NOT NULL
        ) STRICT
      ''')
      ..execute('PRAGMA user_version = 1');
  }

  Future<void> _recoverManagedFiles() async {
    await for (final entity in stagingDirectory.list(followLinks: false)) {
      await entity.delete(recursive: entity is Directory);
    }

    final committed = _connection
        .select('SELECT relative_path FROM assets')
        .map((row) => p.normalize(row['relative_path'] as String))
        .toSet();
    final managedName = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.[a-z0-9]+$',
    );
    await for (final entity in originalsDirectory.list(followLinks: false)) {
      if (entity is! File || !managedName.hasMatch(p.basename(entity.path))) {
        continue;
      }
      final relative = p.normalize(
        p.relative(entity.path, from: rootDirectory.path),
      );
      if (!committed.contains(relative)) {
        await entity.delete();
      }
    }
  }
}
