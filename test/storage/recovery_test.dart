import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/project_reducer.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';
import 'package:otogurashi/storage/project_repository.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late ProjectDatabase database;
  late SqliteProjectRepository projects;
  late SqliteAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('otogurashi-recovery-');
    database = await ProjectDatabase.open(root);
    projects = SqliteProjectRepository(database);
    assets = SqliteAssetRepository(
      database,
      inspector: const _RecoveryInspector(),
    );
  });

  tearDown(() async {
    database.close();
    await root.delete(recursive: true);
  });

  test('soft delete can be undone without deleting a shared original', () async {
    final source = File(p.join(root.path, 'source.mp4'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final asset = await assets.importFile(source.path);
    final first = await _projectWith(projects, asset.id, 'first');
    final second = await _projectWith(projects, asset.id, 'second');
    final originalPath = await assets.resolvePath(asset.id);

    await projects.deleteProject(first.id);

    expect(await projects.load(first.id), isNull);
    expect((await projects.list()).map((value) => value.id), <String>[second.id]);
    expect(await assets.referencingProjectIds(asset.id), <String>[second.id]);
    expect(await File(originalPath).exists(), isTrue);

    await projects.restoreProject(first.id);

    expect((await projects.load(first.id))!.title, 'first');
    expect(await File(originalPath).exists(), isTrue);
  });

  test('editing a project keeps the previous completed export immutable', () async {
    final project = await projects.create('draft');
    final renamed = ProjectReducer.reduce(
      project,
      const RenameProject('edited'),
      now: DateTime.utc(2026, 9, 22),
    );
    await projects.save(renamed, expectedRevision: project.revision);
    final export = await projects.recordCompletedExport(
      projectId: project.id,
      sourceRevision: renamed.revision,
      relativePath: 'renders/${project.id}/${renamed.revision}/old.mp4',
    );

    final next = ProjectReducer.reduce(
      renamed,
      const RenameProject('edited again'),
      now: DateTime.utc(2026, 9, 23),
    );
    await projects.save(next, expectedRevision: renamed.revision);

    final retained = await projects.listCompletedExports(project.id);
    expect(retained.single.id, export.id);
    expect(retained.single.sourceRevision, renamed.revision);
    expect(retained.single.relativePath, contains('old.mp4'));
  });

  test('restart recovers unfinished export jobs and removes only temporary output',
      () async {
    final project = await projects.create('draft');
    final temporary = File(p.join(database.rootDirectory.path, 'staging', 'job.tmp'))
      ..writeAsBytesSync(<int>[4, 5]);
    await projects.startExportJob(
      projectId: project.id,
      sourceRevision: project.revision,
      temporaryRelativePath: 'staging/job.tmp',
    );
    expect(await temporary.exists(), isTrue);

    database.close();
    database = await ProjectDatabase.open(root);
    projects = SqliteProjectRepository(database);

    expect(await temporary.exists(), isFalse);
    expect(await projects.listIncompleteExportJobs(), isEmpty);
    expect(await projects.listCompletedExports(project.id), isEmpty);
  });

  test('cache capacity cleanup leaves originals and completed exports intact',
      () async {
    final project = await projects.create('draft');
    final original = File(p.join(database.rootDirectory.path, 'originals', 'keep.mp4'))
      ..writeAsBytesSync(List<int>.filled(3, 1));
    final completed = File(p.join(database.rootDirectory.path, 'renders', 'done.mp4'))
      ..writeAsBytesSync(List<int>.filled(4, 1));
    final cache = File(p.join(database.rootDirectory.path, 'renders', 'orphan.tmp'))
      ..writeAsBytesSync(List<int>.filled(5, 1));
    await projects.recordCompletedExport(
      projectId: project.id,
      sourceRevision: project.revision,
      relativePath: 'renders/done.mp4',
    );

    final before = await projects.storageUsage();
    expect(before.originalsBytes, 3);
    expect(before.completedBytes, 4);
    expect(before.cacheBytes, 5);

    await projects.clearRegenerableCache();

    expect(await original.exists(), isTrue);
    expect(await completed.exists(), isTrue);
    expect(await cache.exists(), isFalse);
  });
}

Future<dynamic> _projectWith(
  SqliteProjectRepository projects,
  String assetId,
  String title,
) async {
  final created = await projects.create(title);
  final edited = ProjectReducer.reduce(created, AddClip(assetId));
  await projects.save(edited, expectedRevision: created.revision);
  return edited;
}

final class _RecoveryInspector implements AssetInspector {
  const _RecoveryInspector();

  @override
  Future<InspectedAsset> inspect(String path) async => const InspectedAsset(
    durationUs: 3_000_000,
    width: 1080,
    height: 1920,
    rotation: 0,
  );
}
