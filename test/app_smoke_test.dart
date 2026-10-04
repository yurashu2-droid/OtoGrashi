import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/app/app_dependencies.dart';
import 'package:otogurashi/app/otogurashi_app.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';
import 'package:otogurashi/media/platform_media_gateway.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';
import 'package:otogurashi/storage/project_repository.dart';
import 'package:otogurashi/sharing/shared_folder_service.dart';

void main() {
  testWidgets(
    'a cold-start invitation waits for onboarding and never auto joins',
    (tester) async {
      final setup = await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'otogurashi-invite-',
        );
        final base = await _testDependencies(root);
        final transport = _NoJoinTransport();
        final sharing = SharedFolderService(
          database: base.database,
          assets: base.assets,
          secureStore: _InvitationStore(),
          client: transport,
        );
        return (
          root,
          AppDependencies(
            database: base.database,
            media: base.media,
            presentation: base.presentation,
            projects: base.projects,
            assets: base.assets,
            sharedFolders: sharing,
          ),
          transport,
        );
      });
      final (root, dependencies, transport) = setup!;
      final links = StreamController<Uri>.broadcast();
      addTearDown(() async {
        await links.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        OtogurashiApp(
          dependenciesLoader: () async => dependencies,
          invitationLinks: links.stream,
        ),
      );
      await tester.pumpAndSettle();
      final invitation =
          'https://share.example/invite/11111111-1111-4111-8111-111111111111#${'a' * 64}';
      links.add(
        Uri(
          scheme: 'otograshi',
          host: 'invite',
          queryParameters: {'url': invitation},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.ensureVisible(find.text('自分の音でつくる'));
      await tester.tap(find.text('自分の音でつくる'));
      await tester.pumpAndSettle();
      expect(find.text('友だちのフォルダに参加'), findsOneWidget);
      expect(find.text('接続先：https://share.example'), findsOneWidget);
      expect(transport.requests, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('first launch starts with personal recording', (tester) async {
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('otogurashi-first-');
      return (root, await _testDependencies(root));
    });
    final (root, dependencies) = setup!;
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      OtogurashiApp(dependenciesLoader: () async => dependencies),
    );
    await tester.pumpAndSettle();

    expect(find.text('聴いてみる'), findsNothing);
    expect(find.text('自分の音でつくる'), findsOneWidget);
    final semantics = tester.getSemantics(find.bySemanticsLabel('自分の音でつくる'));
    final data = semantics.getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(
      find.descendant(
        of: find.bySemanticsLabel('自分の音でつくる'),
        matching: find.byType(FilledButton),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('launch resumes the most recent project with collected sounds', (
    tester,
  ) async {
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('otogurashi-resume-');
      final dependencies = await _testDependencies(root);
      final assets = dependencies.assets;
      final projects = dependencies.projects;
      final cupFile = File('${root.path}/cup.mov');
      final typingFile = File('${root.path}/typing.mov');
      await cupFile.writeAsBytes([1, 2, 3]);
      await typingFile.writeAsBytes([4, 5, 6]);
      final cup = await assets.importFile(cupFile.path);
      final typing = await assets.importFile(typingFile.path);
      final older = await projects.create('古い作品');
      await projects.save(
        older.copyWith(
          revision: 1,
          clipIds: [cup.id],
          updatedAt: DateTime.utc(2026, 9, 22),
        ),
        expectedRevision: 0,
      );
      final recent = await projects.create('続きの作品');
      await projects.save(
        recent.copyWith(
          revision: 1,
          clipIds: [typing.id],
          updatedAt: DateTime.utc(2026, 9, 24),
        ),
        expectedRevision: 0,
      );
      return (root, dependencies);
    });
    final (root, dependencies) = setup!;
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      OtogurashiApp(dependenciesLoader: () async => dependencies),
    );
    await tester.pumpAndSettle();

    // launch lands on Home; the song in progress is one tap away
    expect(find.text('つくりかけの曲'), findsOneWidget);
    await tester.tap(find.text('つくりかけの曲'));
    await tester.pumpAndSettle();

    expect(find.text('1/6'), findsOneWidget);
    expect(find.text('typing'), findsOneWidget);
    expect(find.text('cup'), findsNothing);
    expect(find.text('自分の音でつくる'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('launch opens the library when only completed work remains', (
    tester,
  ) async {
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('otogurashi-done-');
      final dependencies = await _testDependencies(root);
      final source = File('${root.path}/friend.mov');
      await source.writeAsBytes([7, 8, 9]);
      final asset = await dependencies.assets.importFile(source.path);
      final projects = dependencies.projects as SqliteProjectRepository;
      final empty = await projects.create('友達との曲');
      await projects.save(
        empty.copyWith(revision: 1, clipIds: [asset.id]),
        expectedRevision: 0,
      );
      await projects.recordCompletedExport(
        projectId: empty.id,
        sourceRevision: 1,
        relativePath: 'renders/friend/full.mp4',
      );
      return (root, dependencies);
    });
    final (root, dependencies) = setup!;
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      OtogurashiApp(dependenciesLoader: () async => dependencies),
    );
    await tester.pumpAndSettle();

    expect(find.text('じぶん'), findsOneWidget);
    expect(find.text('友達との曲'), findsOneWidget);
    expect(find.text('自分の音でつくる'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<AppDependencies> _testDependencies(Directory root) async {
  final database = await ProjectDatabase.open(root);
  return AppDependencies(
    database: database,
    media: PlatformMediaGateway(),
    presentation: _NoThumbnailPresentation(),
    projects: SqliteProjectRepository(database),
    assets: SqliteAssetRepository(database, inspector: const _FakeInspector()),
  );
}

final class _NoThumbnailPresentation implements MediaPresentationGateway {
  @override
  Future<Uint8List> thumbnail(String relativePath) async =>
      throw StateError('No thumbnail in the startup fixture.');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _FakeInspector implements AssetInspector {
  const _FakeInspector();

  @override
  Future<InspectedAsset> inspect(String path) async => const InspectedAsset(
    durationUs: 3000000,
    width: 1080,
    height: 1920,
    rotation: 0,
  );
}

final class _InvitationStore implements SharedSecureStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

final class _NoJoinTransport implements SharedHttpTransport {
  var requests = 0;
  @override
  Future<SharedHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
  }) async {
    requests++;
    throw StateError('An invitation must wait for an explicit join action.');
  }

  @override
  void close() {}
}
