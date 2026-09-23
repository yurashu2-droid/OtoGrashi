import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/clip_asset.dart';
import 'package:otogurashi/domain/project_reducer.dart';
import 'package:otogurashi/domain/project.dart';
import 'package:otogurashi/features/library/library_screen.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_repository.dart';

void main() {
  test('project edits validate gains, captions, crops, and source windows in the domain', () {
    final project = Project(
      id: 'project',
      title: '朝の音',
      revision: 1,
      clipIds: const <String>['asset'],
      arrangement: <String, Object?>{
        'schemaVersion': 1,
        'style': 'sparse',
        'events': <Object?>[
          <String, Object?>{
            'assetId': 'asset',
            'sourceStartSample': 0,
            'destinationStartSample': 0,
            'durationSamples': 48000,
            'gain': .5,
            'fades': <String, Object?>{
              'fadeInSamples': 0,
              'fadeOutSamples': 0,
            },
          },
        ],
        'videoEvents': <Object?>[
          <String, Object?>{
            'assetId': 'asset',
            'destinationStartSample': 0,
            'durationSamples': 48000,
            'sourceVideoStartTime': <String, Object?>{
              'numerator': 0,
              'denominator': 48000,
            },
          },
        ],
      },
      videoRecipe: <String, Object?>{
        'schemaVersion': 1,
        'captions': <Object?>[],
        'clipCrops': <Object?>[],
      },
      createdAt: DateTime.utc(2026, 9, 22),
      updatedAt: DateTime.utc(2026, 9, 22),
    );

    final gained = ProjectReducer.reduce(project, const SetGain('asset', .75));
    expect(
      (gained.arrangement['events']! as List<Object?>).single
          as Map<String, Object?>,
      containsPair('gain', .75),
    );
    final captioned = ProjectReducer.reduce(
      gained,
      const SetCaption('コツン'),
    );
    expect((captioned.videoRecipe['captions']! as List<Object?>).length, 1);
    final cropped = ProjectReducer.reduce(
      captioned,
      const SetCrop('asset', NormalizedCrop(x: 0, y: 0, width: .5, height: 1)),
    );
    expect((cropped.videoRecipe['clipCrops']! as List<Object?>).length, 1);
    final trimmed = ProjectReducer.reduce(cropped, const SetTrim('asset', 1_000_000, 2_000_000));
    final windows = ((trimmed.arrangement['edits']! as Map<Object?, Object?>)['sourceWindows']!
        as Map<Object?, Object?>)['asset']! as Map<Object?, Object?>;
    expect(windows['startUs'], 1_000_000);
    expect(windows['durationUs'], 2_000_000);

    expect(
      () => ProjectReducer.reduce(project, const SetGain('asset', 1.1)),
      throwsA(isA<ProjectValidationException>()),
    );
    expect(
      () => ProjectReducer.reduce(project, SetCaption('x' * 81)),
      throwsA(isA<ProjectValidationException>()),
    );
  });

  testWidgets('library has projects and assets tabs and returns to capture when empty',
      (tester) async {
    final projects = _LibraryProjects();
    final assets = _LibraryAssets();
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          projects: projects,
          assets: assets,
          onCreate: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('作品'), findsOneWidget);
    expect(find.text('音の引き出し'), findsOneWidget);
    expect(find.text('まだ作品がありません'), findsOneWidget);
    expect(find.text('撮影・取り込みへ'), findsOneWidget);

    await tester.tap(find.text('音の引き出し'));
    await tester.pumpAndSettle();
    expect(find.text('素材はまだありません'), findsOneWidget);
  });

  testWidgets('library does not auto play a project preview', (tester) async {
    final projects = _LibraryProjects()..project = _project();
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          projects: projects,
          assets: _LibraryAssets(),
          onCreate: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('再生'), findsOneWidget);
    expect(find.text('一時停止'), findsNothing);
  });
}

Project _project() => Project(
  id: 'project',
  title: '朝の音',
  revision: 1,
  clipIds: const <String>['asset'],
  arrangement: const <String, Object?>{'schemaVersion': 1},
  videoRecipe: const <String, Object?>{'schemaVersion': 1},
  createdAt: DateTime.utc(2026, 9, 22),
  updatedAt: DateTime.utc(2026, 9, 22),
);

final class _LibraryProjects implements ProjectRepository {
  Project? project;

  @override
  Future<Project> create(String title) async => project = Project.empty(
    id: 'new-project',
    title: title,
    now: DateTime.utc(2026, 9, 22),
  );

  @override
  Future<Project?> load(String id) async => project?.id == id ? project : null;

  @override
  Future<List<Project>> list() async => project == null ? const [] : [project!];

  @override
  Future<void> save(Project value, {required int expectedRevision}) async {
    project = value;
  }

  @override
  Future<void> deleteProject(String id) async => project = null;
}

final class _LibraryAssets implements AssetRepository {
  @override
  Future<ClipAsset> importFile(String sourcePath) => throw UnimplementedError();

  @override
  Future<ClipAsset> importManagedStaging(String relativePath) =>
      throw UnimplementedError();

  @override
  Future<ClipAsset?> load(String id) async => null;

  @override
  Future<List<ClipAsset>> list() async => const [];

  @override
  Future<void> deleteUnreferenced(String assetId) async {}

  @override
  Future<List<String>> referencingProjectIds(String assetId) async => const [];

  @override
  Future<String> resolvePath(String assetId) => throw UnimplementedError();
}
