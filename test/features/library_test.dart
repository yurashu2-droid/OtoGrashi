import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/clip_asset.dart';
import 'package:otogurashi/domain/project_reducer.dart';
import 'package:otogurashi/domain/project.dart';
import 'package:otogurashi/features/export/completed_video_screen.dart';
import 'package:otogurashi/features/library/library_screen.dart';
import 'package:otogurashi/media/media_delivery_gateway.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';
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
            'fades': <String, Object?>{'fadeInSamples': 0, 'fadeOutSamples': 0},
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
    final captioned = ProjectReducer.reduce(gained, const SetCaption('コツン'));
    expect((captioned.videoRecipe['captions']! as List<Object?>).length, 1);
    final cropped = ProjectReducer.reduce(
      captioned,
      const SetCrop('asset', NormalizedCrop(x: 0, y: 0, width: .5, height: 1)),
    );
    expect((cropped.videoRecipe['clipCrops']! as List<Object?>).length, 1);
    final trimmed = ProjectReducer.reduce(
      cropped,
      const SetTrim('asset', 1_000_000, 2_000_000),
    );
    final windows =
        ((trimmed.arrangement['edits']!
                    as Map<Object?, Object?>)['sourceWindows']!
                as Map<Object?, Object?>)['asset']!
            as Map<Object?, Object?>;
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

  testWidgets(
    'library has projects and assets tabs and returns to capture when empty',
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

      expect(find.text('つくった曲'), findsOneWidget);
      expect(find.text('音のストック'), findsOneWidget);
      expect(find.text('まだ作品がありません'), findsOneWidget);
      expect(find.text('撮影・取り込みへ'), findsOneWidget);

      await tester.tap(find.text('音のストック'));
      await tester.pumpAndSettle();
      expect(find.text('素材はまだありません'), findsOneWidget);
    },
  );

  testWidgets('library shows an honest project action', (tester) async {
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

    expect(find.text('再生'), findsNothing);
    expect(find.text('続きをつくる'), findsOneWidget);
  });

  testWidgets('stocked sound can be previewed, renamed, and reused', (
    tester,
  ) async {
    final assets = _LibraryAssets()..asset = _asset();
    final projects = _LibraryProjects();
    final presentation = _PreviewPresentation();
    ClipAsset? reused;
    Widget screen() => MaterialApp(
      home: LibraryScreen(
        projects: projects,
        assets: assets,
        presentation: presentation,
        initialTabIndex: 1,
        onCreate: () {},
        onAssetSelected: (asset) => reused = asset,
      ),
    );
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();

    expect(find.text('カタカタ'), findsOneWidget);
    expect(find.text('3.0秒 · 0作品で使用'), findsOneWidget);
    final referenceLoads = assets.referenceLoads;
    await tester.pumpWidget(screen());
    expect(assets.referenceLoads, referenceLoads);
    await tester.tap(find.text('聴く'));
    await tester.pumpAndSettle();
    expect(find.text('ストックした元の動画と音'), findsOneWidget);
    await tester.tap(find.byTooltip('閉じる'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('音の名前を変更'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '雨の音');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('雨の音'), findsOneWidget);

    await tester.tap(find.text('曲に使う'));
    expect(reused?.label, '雨の音');
  });

  testWidgets('small stock cards open preview with rename and reuse actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final assets = _LibraryAssets()..asset = _asset();
    ClipAsset? reused;
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryScreen(
          projects: _LibraryProjects(),
          assets: assets,
          presentation: _PreviewPresentation(),
          initialTabIndex: 1,
          onCreate: () {},
          onAssetSelected: (asset) => reused = asset,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('聴く'), findsOneWidget);
    await tester.tap(find.byTooltip('小さく表示'));
    await tester.pumpAndSettle();
    expect(find.text('聴く'), findsNothing);
    expect(find.text('カタカタ'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('カタカタ'));
    await tester.pumpAndSettle();
    expect(find.text('ストックした元の動画と音'), findsOneWidget);
    expect(find.text('名前を変更'), findsOneWidget);
    expect(find.text('曲に使う'), findsOneWidget);

    await tester.tap(find.text('名前を変更'));
    await tester.pumpAndSettle();
    expect(find.text('この音に名前をつける'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '雨の音');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('雨の音'), findsOneWidget);

    await tester.tap(find.text('雨の音'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('曲に使う'));
    expect(reused?.label, '雨の音');
  });

  testWidgets('stock and video layouts fit a narrow screen with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final assets = _LibraryAssets()
      ..asset = _asset().withLabel('長い録音の名前 カタカタカタカタ');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LibraryScreen(
          projects: _LibraryProjects(),
          assets: assets,
          presentation: _PreviewPresentation(),
          initialTabIndex: 1,
          onCreate: () {},
          onAssetSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final version = CompletedExport(
      id: 'export',
      projectId: 'project',
      sourceRevision: 1,
      relativePath: 'renders/project/1/full.mp4',
      createdAt: DateTime.utc(2026, 9, 24),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CompletedVideoScreen(
          project: _project(),
          export: version,
          versions: [version],
          presentation: _UnusedPresentation(),
          delivery: _RecordingDelivery(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed project opens the saved video from its poster', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('otogurashi-library-');
      final database = await ProjectDatabase.open(root);
      final projects = SqliteProjectRepository(database);
      final project = await projects.create('雨の日の曲');
      await projects.recordCompletedExport(
        projectId: project.id,
        sourceRevision: project.revision,
        relativePath: 'renders/finished.mp4',
      );
      return (root, database, projects);
    });
    final (root, database, projects) = setup!;
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      database.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LibraryScreen(
          projects: projects,
          assets: _LibraryAssets(),
          presentation: _PreviewPresentation(),
          delivery: _RecordingDelivery(),
          onCreate: () {},
          onProjectSelected: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('完成版 1本を保存中'), findsOneWidget);
    await tester.tap(find.text('動画を見る'));
    await tester.pumpAndSettle();
    expect(find.byType(CompletedVideoScreen), findsOneWidget);
    expect(find.text('雨の日の曲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a completed video can be saved and shared again', (
    tester,
  ) async {
    final delivery = _RecordingDelivery();
    const path = 'renders/project/1/full.mp4';
    const oldPath = 'renders/project/0/full.mp4';
    final latest = CompletedExport(
      id: 'export-new',
      projectId: 'project',
      sourceRevision: 1,
      relativePath: path,
      createdAt: DateTime.utc(2026, 9, 24),
    );
    final previous = CompletedExport(
      id: 'export-old',
      projectId: 'project',
      sourceRevision: 0,
      relativePath: oldPath,
      createdAt: DateTime.utc(2026, 9, 23),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CompletedVideoScreen(
          project: _project(),
          export: latest,
          versions: [latest, previous],
          presentation: _UnusedPresentation(),
          delivery: delivery,
        ),
      ),
    );
    await tester.tap(find.text('保存する'));
    await tester.pump();
    expect(delivery.saved, path);
    await tester.tap(find.text('シェアする'));
    await tester.pump();
    expect(delivery.shared, path);
    await tester.tap(find.text('完成版 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('シェアする'));
    await tester.pump();
    expect(delivery.shared, oldPath);
  });
}

class _UnusedPresentation implements MediaPresentationGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _PreviewPresentation extends _UnusedPresentation {
  @override
  Future<Uint8List> thumbnail(String relativePath) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO2ZcXcAAAAASUVORK5CYII=',
  );

  @override
  Future<AudioWaveform> waveform(String relativePath) async => AudioWaveform(
    durationUs: 3_000_000,
    levels: const [.1, .3, .8, .4, .1, .6, .9, .5, .2],
  );
}

final class _RecordingDelivery implements MediaDeliveryGateway {
  String? saved;
  String? shared;

  @override
  Future<void> saveToPhotos(String relativePath) async {
    saved = relativePath;
  }

  @override
  Future<bool> share(String relativePath) async {
    shared = relativePath;
    return true;
  }
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

ClipAsset _asset() => const ClipAsset(
  id: 'asset',
  relativePath: 'assets/keyboard.mov',
  durationUs: 3_000_000,
  selectionStartUs: 0,
  selectionDurationUs: 3_000_000,
  width: 1080,
  height: 1920,
  rotation: 0,
  sha256: 'abc',
  label: 'カタカタ',
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
  ClipAsset? asset;
  int referenceLoads = 0;

  @override
  Future<ClipAsset> rename(String assetId, String label) async =>
      asset = asset!.withLabel(label);

  @override
  Future<ClipAsset> importFile(String sourcePath) => throw UnimplementedError();

  @override
  Future<ClipAsset> importManagedStaging(String relativePath) =>
      throw UnimplementedError();

  @override
  Future<ClipAsset?> load(String id) async => null;

  @override
  Future<List<ClipAsset>> list() async => asset == null ? const [] : [asset!];

  @override
  Future<void> deleteUnreferenced(String assetId) async {}

  @override
  Future<List<String>> referencingProjectIds(String assetId) async {
    referenceLoads++;
    return const [];
  }

  @override
  Future<String> resolvePath(String assetId) => throw UnimplementedError();
}
