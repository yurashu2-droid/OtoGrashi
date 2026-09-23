import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/project.dart';
import 'package:otogurashi/domain/project_reducer.dart';
import 'package:otogurashi/media/media_messages.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';
import 'package:otogurashi/storage/project_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  group('project storage', () {
    late Directory root;
    late File fixture;
    late ProjectDatabase database;
    late SqliteAssetRepository assets;
    late SqliteProjectRepository projects;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('otogurashi-storage-');
      fixture = File(p.join(root.path, 'fixture.mov'));
      await fixture.writeAsBytes(<int>[0, 1, 2, 3, 4, 5]);
      database = await ProjectDatabase.open(root);
      assets = SqliteAssetRepository(
        database,
        inspector: const _FixtureInspector(),
      );
      projects = SqliteProjectRepository(database);
    });

    tearDown(() async {
      database.close();
      await root.delete(recursive: true);
    });

    test('renamed sound stays named after reopening storage', () async {
      final asset = await assets.importFile(fixture.path);
      await assets.rename(asset.id, 'コップを置く音');
      database.close();
      database = await ProjectDatabase.open(root);
      assets = SqliteAssetRepository(
        database,
        inspector: const _FixtureInspector(),
      );
      expect((await assets.load(asset.id))?.label, 'コップを置く音');
      expect((await assets.list()).single.label, 'コップを置く音');
    });

    test('deleting one project keeps a shared original', () async {
      final asset = await assets.importFile(fixture.path);
      final first = await _createProjectWith(projects, asset.id, 'first');
      final second = await _createProjectWith(projects, asset.id, 'second');

      await projects.deleteProject(first.id);

      expect((await projects.load(second.id))!.clipIds, contains(asset.id));
      expect(await File(await assets.resolvePath(asset.id)).exists(), isTrue);
      expect(await assets.referencingProjectIds(asset.id), <String>[second.id]);
    });

    test('saving with an old expected revision reports a conflict', () async {
      final original = await projects.create('draft');
      final firstEdit = ProjectReducer.reduce(
        original,
        const RenameProject('first edit'),
      );
      await projects.save(firstEdit, expectedRevision: 0);
      final staleEdit = ProjectReducer.reduce(
        original,
        const RenameProject('stale edit'),
      );

      await expectLater(
        projects.save(staleEdit, expectedRevision: 0),
        throwsA(
          isA<RevisionConflict>()
              .having((error) => error.projectId, 'projectId', original.id)
              .having((error) => error.expectedRevision, 'revision', 0),
        ),
      );
      expect((await projects.load(original.id))!.title, 'first edit');
    });

    test(
      'empty project title survives create rename save and restart',
      () async {
        final created = await projects.create('');
        expect((await projects.load(created.id))!.title, isEmpty);
        final named = ProjectReducer.reduce(
          created,
          const RenameProject('temporary'),
        );
        await projects.save(named, expectedRevision: 0);
        final blankAgain = ProjectReducer.reduce(
          named,
          const RenameProject(''),
        );
        await projects.save(blankAgain, expectedRevision: 1);
        database.close();

        database = await ProjectDatabase.open(root);
        assets = SqliteAssetRepository(
          database,
          inspector: const _FixtureInspector(),
        );
        projects = SqliteProjectRepository(database);

        expect((await projects.load(created.id))!.title, isEmpty);
      },
    );

    test('restart removes copies that were never committed', () async {
      final pending = File(
        p.join(database.stagingDirectory.path, 'crash.partial'),
      );
      final orphan = File(
        p.join(
          database.originalsDirectory.path,
          '00000000-0000-4000-8000-000000000000.mov',
        ),
      );
      await pending.writeAsBytes(<int>[1, 2, 3]);
      await orphan.writeAsBytes(<int>[4, 5, 6]);
      database.close();

      database = await ProjectDatabase.open(root);
      assets = SqliteAssetRepository(
        database,
        inspector: const _FixtureInspector(),
      );
      projects = SqliteProjectRepository(database);

      expect(await pending.exists(), isFalse);
      expect(await orphan.exists(), isFalse);
    });

    test(
      'committed originals and project references survive restart',
      () async {
        final asset = await assets.importFile(fixture.path);
        final project = await _createProjectWith(projects, asset.id, 'kept');
        final managedPath = await assets.resolvePath(asset.id);
        database.close();

        database = await ProjectDatabase.open(root);
        assets = SqliteAssetRepository(
          database,
          inspector: const _FixtureInspector(),
        );
        projects = SqliteProjectRepository(database);

        expect((await projects.load(project.id))!.clipIds, <String>[asset.id]);
        expect(await File(managedPath).exists(), isTrue);
      },
    );

    test('asset metadata can be loaded and listed after restart', () async {
      final longAssets = SqliteAssetRepository(
        database,
        inspector: const _FixtureInspector(durationUs: 8000000),
      );
      final imported = await longAssets.importFile(fixture.path);
      database.close();

      database = await ProjectDatabase.open(root);
      assets = SqliteAssetRepository(database);
      projects = SqliteProjectRepository(database);

      final loaded = await assets.load(imported.id);
      final listed = await assets.list();
      expect(await assets.load('missing'), isNull);
      expect(loaded, isNotNull);
      expect(loaded!.id, imported.id);
      expect(loaded.relativePath, imported.relativePath);
      expect(loaded.durationUs, 8000000);
      expect(loaded.selectionStartUs, 0);
      expect(loaded.selectionDurationUs, 6000000);
      expect(loaded.width, 1080);
      expect(loaded.height, 1920);
      expect(loaded.rotation, 90);
      expect(loaded.audioTrackStartUs, 125000);
      expect(
        loaded.sha256,
        '17e88db187afd62c16e5debf3e6527cd006bc012bc90b51a810cd80c2d511f43',
      );
      expect(loaded.label, 'fixture');
      expect(listed.map((asset) => asset.id), <String>[imported.id]);
      expect(listed.single.selectionDurationUs, 6000000);
      expect(listed.single.sha256, loaded.sha256);
      final analysisRequest = MediaAnalysisRequest.forAsset(loaded);
      expect(analysisRequest.audioTrackStartUs, 125000);
      expect(analysisRequest.relativePath, loaded.relativePath);
    });

    test(
      'version-one asset rows migrate with a zero audio track origin',
      () async {
        database.close();
        final legacy = sqlite3.open(p.join(root.path, 'projects.sqlite3'));
        legacy.execute('DROP TABLE assets');
        legacy.execute('''
        CREATE TABLE assets (
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
      ''');
        legacy.execute('PRAGMA user_version = 1');
        legacy.close();

        database = await ProjectDatabase.open(root);
        final columns = database.connection
            .select("PRAGMA table_info('assets')")
            .map((row) => row['name'])
            .toSet();

        expect(columns, contains('audio_track_start_us'));
        expect(database.connection.userVersion, 2);
      },
    );

    test('asset rows store portable relative paths', () async {
      final asset = await assets.importFile(fixture.path);
      final databasePath = database.databasePath;
      database.close();
      final raw = sqlite3.open(databasePath);
      addTearDown(raw.close);

      final stored =
          raw.select('SELECT relative_path FROM assets WHERE id = ?', <Object?>[
                asset.id,
              ]).single['relative_path']
              as String;

      expect(p.isAbsolute(stored), isFalse);
      expect(stored.replaceAll('\\', '/'), 'originals/${asset.id}.mov');
      expect(asset.relativePath, stored);
    });

    test('managed capture staging promotes to an immutable original', () async {
      final capture = File(
        p.join(database.stagingDirectory.path, 'capture.mov'),
      );
      await capture.writeAsBytes(<int>[6, 5, 4, 3]);

      final asset = await assets.importManagedStaging('staging/capture.mov');

      expect(await capture.exists(), isFalse);
      expect(
        await File(await assets.resolvePath(asset.id)).readAsBytes(),
        <int>[6, 5, 4, 3],
      );
      expect(asset.audioTrackStartUs, 125000);
      await expectLater(
        assets.importManagedStaging('../outside.mov'),
        throwsA(isA<InvalidAsset>()),
      );
    });

    test(
      'import keeps source duration separate from editable selection',
      () async {
        final longAssets = SqliteAssetRepository(
          database,
          inspector: const _FixtureInspector(durationUs: 8000000),
        );

        final asset = await longAssets.importFile(fixture.path);

        expect(asset.durationUs, 8000000);
        expect(asset.selectionStartUs, 0);
        expect(asset.selectionDurationUs, 6000000);
      },
    );

    test(
      'deleteUnreferenced rechecks references before deleting media',
      () async {
        final asset = await assets.importFile(fixture.path);
        final project = await _createProjectWith(
          projects,
          asset.id,
          'using it',
        );

        await assets.deleteUnreferenced(asset.id);
        expect(await File(await assets.resolvePath(asset.id)).exists(), isTrue);

        await projects.deleteProject(project.id);
        await assets.deleteUnreferenced(asset.id);
        await expectLater(
          assets.resolvePath(asset.id),
          throwsA(isA<AssetNotFound>()),
        );
      },
    );

    test('default importer rejects media without a native inspector', () async {
      final productionAssets = SqliteAssetRepository(database);

      await expectLater(
        productionAssets.importFile(fixture.path),
        throwsA(isA<AssetInspectionUnavailable>()),
      );
      expect(database.stagingDirectory.listSync(), isEmpty);
      expect(database.originalsDirectory.listSync(), isEmpty);
    });
  });

  group('project reducer', () {
    test('edit creates a new revision without mutating the original', () {
      final original = Project(
        id: 'project',
        title: 'Original',
        revision: 4,
        clipIds: const <String>[],
        arrangement: const <String, Object?>{
          'schemaVersion': 1,
          'events': <Object?>[],
        },
        videoRecipe: const <String, Object?>{'schemaVersion': 1},
        createdAt: DateTime.utc(2026, 9, 22),
        updatedAt: DateTime.utc(2026, 9, 22),
      );

      final edited = ProjectReducer.reduce(
        original,
        const AddClip('asset'),
        now: DateTime.utc(2026, 9, 23),
      );

      expect(original.clipIds, isEmpty);
      expect(original.revision, 4);
      expect(edited.clipIds, <String>['asset']);
      expect(edited.revision, 5);
      expect(edited.arrangement['schemaVersion'], 1);
      expect(edited.videoRecipe['schemaVersion'], 1);
    });

    test('draft permits zero clips but rejects a seventh clip', () {
      var project = Project.empty(id: 'project', title: 'Draft');
      expect(project.clipIds, isEmpty);
      for (var index = 0; index < 6; index++) {
        project = ProjectReducer.reduce(project, AddClip('asset-$index'));
      }

      expect(
        () => ProjectReducer.reduce(project, const AddClip('asset-6')),
        throwsA(isA<ProjectValidationException>()),
      );
    });
  });
}

Future<Project> _createProjectWith(
  ProjectRepository projects,
  String assetId,
  String title,
) async {
  final project = await projects.create(title);
  final edited = ProjectReducer.reduce(project, AddClip(assetId));
  await projects.save(edited, expectedRevision: project.revision);
  return edited;
}

final class _FixtureInspector implements AssetInspector {
  const _FixtureInspector({this.durationUs = 6000000});

  final int durationUs;

  @override
  Future<InspectedAsset> inspect(String path) async {
    if (!await File(path).exists()) {
      throw const InvalidAsset('fixture is missing');
    }
    return InspectedAsset(
      durationUs: durationUs,
      audioTrackStartUs: 125000,
      width: 1080,
      height: 1920,
      rotation: 90,
    );
  }
}
