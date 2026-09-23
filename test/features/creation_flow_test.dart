import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/design/tokens.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/clip_asset.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/project.dart';
import 'package:otogurashi/features/create/creation_controller.dart';
import 'package:otogurashi/features/create/creation_flow.dart';
import 'package:otogurashi/features/create/beat_building_preview.dart';
import 'package:otogurashi/features/export/media_playback.dart';
import 'package:otogurashi/features/capture/capture_controller.dart';
import 'package:otogurashi/features/capture/capture_screen.dart';
import 'package:otogurashi/media/media_gateway.dart';
import 'package:otogurashi/media/media_delivery_gateway.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_repository.dart';

void main() {
  testWidgets('sound names reach export recipe without reanalyzing on rename', (
    tester,
  ) async {
    final media = _FakeMedia();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _RenamableAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await controller.startDemo();
    await controller.createPreview();
    await tester.pump();
    final originalAnalysisCalls = media.analysisCalls;
    final originalRenderCount = media.renderRequests.length;

    await controller.renameClip('clip-0', '友達のわっ！');
    expect(media.analysisCalls, originalAnalysisCalls);
    expect(media.renderRequests, hasLength(originalRenderCount));
    expect(controller.state.project!.videoRecipe['clipNames'], {
      'clip-0': '友達のわっ！',
    });

    controller.refreshNamedPreview();
    await tester.pump();
    expect(media.analysisCalls, originalAnalysisCalls);
    expect(media.renderRequests.last.video.clipNames, {'clip-0': '友達のわっ！'});

    await controller.createPreview();
    await tester.pump();
    expect(media.renderRequests.last.video.clipNames, {'clip-0': '友達のわっ！'});
  });

  testWidgets('chosen video shows progress until it joins the project', (
    tester,
  ) async {
    final pending = Completer<ClipAsset>();
    final media = _FakeMedia()
      ..pickAction = (operationId) async => CapturedMedia(
        operationId: operationId,
        assetId: 'chosen',
        relativePath: 'staging/chosen.mov',
        durationUs: 3000000,
        audioTrackStartUs: 0,
        width: 1080,
        height: 1920,
        rotation: 0,
      );
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _PendingImportAssets(pending.future),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );

    await tester.tap(find.text('動画を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この音を使う'));
    await tester.pump();
    expect(find.text('音を追加しています'), findsOneWidget);
    expect(controller.state.clips, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('音を追加しています'), findsOneWidget);

    pending.complete(
      (await _FakeDemo(count: 1).install(_UnusedAssets())).single,
    );
    await tester.pumpAndSettle();
    expect(find.text('音を追加しています'), findsNothing);
    expect(find.text('この音を使う'), findsNothing);
    expect(controller.state.clips, hasLength(1));
  });

  testWidgets('failed addition leaves the chosen video available to retake', (
    tester,
  ) async {
    final pending = Completer<ClipAsset>();
    final media = _FakeMedia()
      ..pickAction = (operationId) async => CapturedMedia(
        operationId: operationId,
        assetId: 'chosen',
        relativePath: 'staging/chosen.mov',
        durationUs: 3000000,
        audioTrackStartUs: 0,
        width: 1080,
        height: 1920,
        rotation: 0,
      );
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _PendingImportAssets(pending.future),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );

    await tester.tap(find.text('動画を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この音を使う'));
    await tester.pump();
    pending.completeError(StateError('storage unavailable'));
    await tester.pumpAndSettle();

    expect(find.text('この音を使う'), findsOneWidget);
    expect(find.textContaining('もう一度試すか、撮り直してください'), findsOneWidget);
    expect(media.discardedPaths, isEmpty);
    await tester.tap(find.text('撮り直す'));
    await tester.pumpAndSettle();
    expect(media.discardedPaths, ['staging/chosen.mov']);
    expect(find.textContaining('3秒撮る'), findsOneWidget);
  });

  testWidgets('failed addition can retry the same recorded video', (
    tester,
  ) async {
    final asset = (await _FakeDemo(count: 1).install(_UnusedAssets())).single;
    final assets = _RetryImportAssets(asset);
    final media = _FakeMedia()
      ..pickAction = (operationId) async => CapturedMedia(
        operationId: operationId,
        assetId: 'chosen',
        relativePath: 'staging/chosen.mov',
        durationUs: 3000000,
        audioTrackStartUs: 0,
        width: 1080,
        height: 1920,
        rotation: 0,
      );
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: assets,
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );

    await tester.tap(find.text('動画を選ぶ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この音を使う'));
    await tester.pumpAndSettle();
    expect(assets.attempts, 1);
    expect(media.discardedPaths, isEmpty);

    await tester.tap(find.text('この音を使う'));
    await tester.pumpAndSettle();
    expect(assets.attempts, 2);
    expect(media.discardedPaths, ['staging/chosen.mov']);
    expect(find.text('この音を使う'), findsNothing);
    expect(controller.state.clips, hasLength(1));
  });

  testWidgets('camera and Photos start from separate collect actions', (
    tester,
  ) async {
    final media = _FakeMedia();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(count: 2),
    );
    addTearDown(controller.dispose);
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('今撮る'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('今撮る'));
    await tester.pumpAndSettle();
    expect(media.prepareCalls, 1);
    expect(media.pickCalls, 0);
    expect(find.textContaining('3秒撮る'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('動画を選ぶ'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('動画を選ぶ'));
    await tester.pumpAndSettle();
    expect(media.prepareCalls, 1);
    expect(media.pickCalls, 1);
    expect(find.text('カメラとマイクを準備'), findsOneWidget);
  });

  testWidgets('building preview includes clips beyond the first three', (
    tester,
  ) async {
    final clips = await _FakeDemo(count: 6).install(_UnusedAssets());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 225,
              height: 400,
              child: BeatBuildingPreview(clips: clips, thumbnails: const {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 2550));
    expect(find.text('音 06'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('adding a fourth clip rebuilds a renderable recipe', () async {
    final projects = _MemoryProjects();
    final controller = CreationController(
      projects: projects,
      assets: _UnusedAssets(),
      media: _FakeMedia(),
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);

    await controller.startDemo();
    await controller.createPreview();
    await Future<void>.delayed(Duration.zero);
    final added = (await _FakeDemo(count: 4).install(_UnusedAssets())).last;
    await controller.addExisting(added);
    expect(controller.state.preview, isNull);
    expect(controller.state.phase, CreationPhase.readyToCreate);
    await controller.createPreview();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.error, isNull);
    expect(controller.state.phase, CreationPhase.ready);
    final crops = projects.project!.videoRecipe['clipCrops'] as List<Object?>;
    expect(crops, hasLength(4));
    expect((crops.last as Map)['assetId'], added.id);
  });

  test('failed remix does not leave an outdated preview playable', () async {
    final media = _FakeMedia();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await controller.startDemo();
    await controller.createPreview();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.preview, isNotNull);

    media.failAnalysis = true;
    await controller.createPreview();
    expect(controller.state.phase, CreationPhase.failed);
    expect(controller.state.preview, isNull);
  });

  test(
    'melody choice is saved separately from rhythm style and restored',
    () async {
      final projects = _MemoryProjects();
      final controller = CreationController(
        projects: projects,
        assets: _UnusedAssets(),
        media: _FakeMedia(),
        presentation: _FakePresentation(),
        demo: _FakeDemo(),
      );
      addTearDown(controller.dispose);
      await controller.startDemo();
      controller.selectMelody(MelodyTemplate.wink);
      await controller.createPreview();
      expect(projects.project!.arrangement['melodyTemplate'], 'wink');
      expect(projects.project!.arrangement['style'], 'sparse');

      final saved = Project.empty(id: 'saved', title: 'saved').copyWith(
        arrangement: const {
          'schemaVersion': 1,
          'style': 'lively',
          'melodyTemplate': 'wink',
        },
      );
      await controller.openProject(saved);
      expect(controller.state.style, ArrangementStyle.lively);
      expect(controller.state.melody, MelodyTemplate.wink);
    },
  );

  test(
    'new creation starts empty and removed clips stay out of its recipe',
    () async {
      final projects = _MemoryProjects();
      final controller = CreationController(
        projects: projects,
        assets: _UnusedAssets(),
        media: _FakeMedia(),
        presentation: _FakePresentation(),
        demo: _FakeDemo(),
      );
      addTearDown(controller.dispose);
      await controller.startDemo();
      controller.startNew();
      expect(controller.state.clips, isEmpty);
      expect(controller.state.project, isNull);

      final clips = await _FakeDemo(count: 4).install(_UnusedAssets());
      for (final clip in clips.take(3)) {
        await controller.addExisting(clip);
      }
      expect(controller.state.phase, CreationPhase.readyToCreate);
      await controller.removeClip(clips[1].id);
      expect(controller.state.phase, CreationPhase.collecting);
      expect(projects.project!.clipIds, [clips[0].id, clips[2].id]);
      await controller.addExisting(clips[3]);
      await controller.createPreview();
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.phase, CreationPhase.ready);
      expect(controller.state.error, isNull);
      expect(projects.project!.clipIds, [
        clips[0].id,
        clips[2].id,
        clips[3].id,
      ]);
      final crops = projects.project!.videoRecipe['clipCrops'] as List<Object?>;
      expect(
        crops.map((crop) => (crop as Map)['assetId']),
        projects.project!.clipIds,
      );
    },
  );

  testWidgets('clip list can remove a sample and start empty', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final projects = _MemoryProjects();
    final media = _FakeMedia();
    final controller = CreationController(
      projects: projects,
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.play_circle_fill_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('曲にする前の、元の動画と音'), findsOneWidget);
    await tester.tap(find.byTooltip('閉じる'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('合成素材 1のメニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品から外す').last);
    await tester.pumpAndSettle();
    expect(controller.state.clips, hasLength(2));
    expect(projects.project!.clipIds, ['clip-1', 'clip-2']);
    await tester.tap(find.text('新しくつくる'));
    await tester.pumpAndSettle();
    expect(controller.state.clips, isEmpty);
    expect(find.text('家の中の短い音を、まず3つ。'), findsOneWidget);
  });

  testWidgets('completed video exports once for save and share', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final media = _FakeMedia();
    final delivery = _FakeDelivery();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await controller.startDemo();
    await controller.createPreview();
    await tester.pump();
    expect(controller.state.phase, CreationPhase.ready);
    controller.complete();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(
          controller: controller,
          media: media,
          delivery: delivery,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存する'));
    await tester.pumpAndSettle();
    expect(delivery.saved, hasLength(1));
    expect(find.text('写真に保存しました'), findsOneWidget);
    await tester.tap(find.text('シェアする'));
    await tester.pumpAndSettle();
    expect(delivery.shared, delivery.saved);
    expect(
      media.renderRequests.where(
        (request) => request.quality == RenderQuality.full,
      ),
      hasLength(1),
    );
  });

  testWidgets('full-screen comparison visits every selected clip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final media = _FakeMedia();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(count: 3),
      renderOperationIds: <String>['comparison-preview'].iterator,
    );
    addTearDown(controller.dispose);

    await controller.startDemo();
    await controller.createPreview();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('見くらべる'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('元の音'));
    await tester.pumpAndSettle();
    expect(find.text('いつもの音 → できた曲'), findsOneWidget);
    final movie = tester.widget<NativeMovieView>(find.byType(NativeMovieView));
    expect(
      movie.segments.map((s) => s.relativePath),
      controller.state.clips.map((clip) => clip.relativePath),
    );
    expect(
      movie.segments.map((s) => s.startUs),
      controller.state.clips.map((clip) => clip.selectionStartUs),
    );
    expect(
      movie.segments.map((s) => s.durationUs),
      controller.state.clips.map((clip) => clip.selectionDurationUs),
    );
  });

  test(
    'disposing while demo installation is pending does not write a project',
    () async {
      final installed = Completer<List<ClipAsset>>();
      final projects = _MemoryProjects();
      final controller = CreationController(
        projects: projects,
        assets: _UnusedAssets(),
        media: _FakeMedia(),
        presentation: _FakePresentation(),
        demo: _PendingDemo(installed.future),
      );

      final operation = controller.startDemo();
      controller.dispose();
      installed.complete(await _FakeDemo().install(_UnusedAssets()));
      await operation;

      expect(projects.createCount, 0);
      expect(projects.project, isNull);
    },
  );

  testWidgets('synthetic sample runs through style selection and completion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final media = _FakeMedia();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
      renderOperationIds: <String>[
        'preview-1',
        'preview-2',
        'preview-3',
      ].iterator,
    );
    addTearDown(controller.dispose);

    await controller.startDemo();
    await controller.createPreview();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: CreationFlow(controller: controller, media: media),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('合成素材 1'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('音の名前をつける'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('音の名前をつける'));
    await tester.pumpAndSettle();
    expect(find.text('合成素材 1'), findsWidgets);
    await tester.tap(find.byType(ListTile).last);
    await tester.pumpAndSettle();
    expect(find.text('この音の名前'), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(find.text('ぽつぽつ'), findsOneWidget);
    await tester.tap(find.text('ゆらゆら'));
    await tester.pumpAndSettle();
    expect(controller.state.style, ArrangementStyle.swaying);

    await tester.scrollUntilVisible(
      find.text('これで完成'),
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('これで完成'));
    await tester.pumpAndSettle();
    expect(find.text('できあがり'), findsOneWidget);
    expect(find.textContaining('保存'), findsWidgets);
    expect(find.textContaining('シェア'), findsWidgets);
  });

  testWidgets('large text remains scrollable and controls meet 44 points', (
    tester,
  ) async {
    final media = _FakeMedia();
    final controller = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: media,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    addTearDown(controller.dispose);
    await controller.startDemo();
    await controller.createPreview();
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          textScaler: TextScaler.linear(1.8),
          disableAnimations: true,
        ),
        child: MaterialApp(
          theme: buildOtogurashiTheme(),
          home: CreationFlow(controller: controller, media: media),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Scrollable), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('同じ音でもうひとつ作る'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    final button = find.ancestor(
      of: find.text('同じ音でもうひとつ作る'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
  });

  testWidgets('capture Task 7 visual QA screens', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fontData = await tester.runAsync(
      () => File('C:/Windows/Fonts/NotoSansJP-VF.ttf').readAsBytes(),
    );
    final loader = FontLoader('Task7Japanese')
      ..addFont(Future.value(ByteData.sublistView(fontData!)));
    await tester.runAsync(loader.load);
    final baseTheme = buildOtogurashiTheme();
    final theme = baseTheme.copyWith(
      textTheme: baseTheme.textTheme.apply(fontFamily: 'Task7Japanese'),
      primaryTextTheme: baseTheme.primaryTextTheme.apply(
        fontFamily: 'Task7Japanese',
      ),
    );
    final boundaryKey = GlobalKey();
    final output = Directory(
      '.superpowers/sdd/2026-09-22-otogurashi-ios-implementation/task-7-artifacts',
    );
    await tester.runAsync(() => output.create(recursive: true));

    final captureMedia = _FakeMedia();
    final capture = CaptureController(
      captureMedia,
      operationIdFactory: () => 'visual-capture',
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: CaptureScreen(
            controller: capture,
            testFixture: true,
            onMediaReady: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/capture.png'),
    );
    await capture.prepare();
    await tester.pump(const Duration(milliseconds: 100));
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/capture-ready.png'),
    );
    captureMedia.pickedVideo = CapturedMedia(
      operationId: 'visual-capture',
      assetId: 'visual-clip',
      relativePath: 'staging/visual-clip.mov',
      durationUs: 3000000,
      audioTrackStartUs: 0,
      width: 1080,
      height: 1920,
      rotation: 0,
    );
    await capture.importVideo();
    await tester.pump(const Duration(milliseconds: 100));
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/capture-review.png'),
    );
    await tester.runAsync(capture.releaseCapture);
    capture.dispose();

    final listMedia = _FakeMedia();
    final listController = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: listMedia,
      presentation: _FakePresentation(),
      demo: _FakeDemo(count: 2),
    );
    await listController.startDemo();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: CreationFlow(controller: listController, media: listMedia),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/clip-list.png'),
    );
    listController.dispose();

    final completeMedia = _FakeMedia();
    final completeController = CreationController(
      projects: _MemoryProjects(),
      assets: _UnusedAssets(),
      media: completeMedia,
      presentation: _FakePresentation(),
      demo: _FakeDemo(),
    );
    await completeController.startDemo();
    await tester.pump();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: CreationFlow(
            controller: completeController,
            media: completeMedia,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/clip-list-ready.png'),
    );
    await completeController.createPreview();
    await tester.pumpAndSettle();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/arrange.png'),
    );
    await tester.tap(find.text('見くらべる'));
    await tester.pumpAndSettle();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/comparison-song.png'),
    );
    await tester.tap(find.text('元の音'));
    await tester.pumpAndSettle();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/comparison-original.png'),
    );
    await tester.tap(find.byTooltip('閉じる'));
    await tester.pumpAndSettle();
    completeController.complete();
    await tester.pumpAndSettle();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/completed.png'),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 225,
                height: 400,
                child: BeatBuildingPreview(
                  clips: completeController.state.clips,
                  thumbnails: const {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/building-one.png'),
    );
    await tester.pump(const Duration(milliseconds: 1700));
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/building-duplicate.png'),
    );
    await tester.pump(const Duration(milliseconds: 850));
    await _captureScreen(
      tester,
      boundaryKey,
      File('${output.path}/building-all.png'),
    );
    await tester.pumpWidget(const SizedBox());
    completeController.dispose();
  }, skip: !const bool.fromEnvironment('TASK7_VISUALS'));
}

Future<void> _captureScreen(
  WidgetTester tester,
  GlobalKey key,
  File output,
) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await output.writeAsBytes(data!.buffer.asUint8List(), flush: true);
  });
}

final class _FakeDemo implements DemoAssetSource {
  _FakeDemo({this.count = 3});
  final int count;

  @override
  Future<List<ClipAsset>> install(AssetRepository repository) async =>
      List<ClipAsset>.generate(
        count,
        (index) => ClipAsset(
          id: 'clip-$index',
          relativePath: 'originals/clip-$index.mp4',
          durationUs: 3000000,
          selectionStartUs: 0,
          selectionDurationUs: 3000000,
          width: 1080,
          height: 1920,
          rotation: 0,
          sha256: '${index}hash',
          label: '合成素材 ${index + 1}',
        ),
      );
}

final class _PendingDemo implements DemoAssetSource {
  const _PendingDemo(this.result);
  final Future<List<ClipAsset>> result;

  @override
  Future<List<ClipAsset>> install(AssetRepository repository) => result;
}

final class _MemoryProjects implements ProjectRepository {
  Project? project;
  var createCount = 0;

  @override
  Future<Project> create(String title) async {
    createCount += 1;
    return project = Project.empty(
      id: 'project',
      title: title,
      now: DateTime.utc(2026, 9, 22),
    );
  }

  @override
  Future<void> save(Project project, {required int expectedRevision}) async {
    expect(this.project?.revision, expectedRevision);
    this.project = project;
  }

  @override
  Future<Project?> load(String id) async => project;
  @override
  Future<List<Project>> list() async => [?project];
  @override
  Future<void> deleteProject(String id) async => project = null;
}

final class _UnusedAssets implements AssetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _RenamableAssets implements AssetRepository {
  @override
  Future<ClipAsset> rename(String assetId, String label) async {
    final index = int.parse(assetId.split('-').last);
    return (await _FakeDemo(count: index + 1).install(this)).last
        .withLabel(label);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _PendingImportAssets implements AssetRepository {
  _PendingImportAssets(this.result);
  final Future<ClipAsset> result;

  @override
  Future<ClipAsset> importManagedStaging(String relativePath) => result;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _RetryImportAssets implements AssetRepository {
  _RetryImportAssets(this.asset);
  final ClipAsset asset;
  var attempts = 0;

  @override
  Future<ClipAsset> importManagedStaging(String relativePath) async {
    attempts += 1;
    if (attempts == 1) throw StateError('temporary import failure');
    return asset;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _FakeMedia implements MediaGateway {
  CapturedMedia? pickedVideo;
  Future<CapturedMedia?> Function(String)? pickAction;
  final discardedPaths = <String>[];
  int prepareCalls = 0;
  int pickCalls = 0;
  final renderRequests = <RenderRequest>[];
  bool failAnalysis = false;
  int analysisCalls = 0;
  @override
  Stream<MediaEvent> get events => const Stream.empty();

  @override
  Future<AnalyzedClip> analyze(MediaAnalysisRequest request) async {
    analysisCalls += 1;
    if (failAnalysis) throw StateError('analysis failed');
    return AnalyzedClip(
      assetId: request.assetId,
      durationSamples: 48000,
      sampleRate: 48000,
      onsetSamples: const [0],
      peak: 0.8,
      rms: 0.2,
      suggestedRole: SuggestedRole.transient,
    );
  }

  @override
  Future<RenderedMedia> render(RenderRequest request) async {
    renderRequests.add(request);
    return RenderedMedia(
      operationId: request.operationId,
      projectId: request.projectId,
      revision: request.revision,
      relativePath: 'renders/project/${request.revision}/preview.mp4',
      durationUs: 15000000,
      width: 360,
      height: 640,
    );
  }

  @override
  Future<void> cancel(String operationId) async {}
  @override
  Future<void> disposeCapture() async {}
  @override
  Future<CaptureHandle> prepareCapture() async {
    prepareCalls += 1;
    return const CaptureHandle(previewViewType: 'test-capture-preview');
  }

  @override
  Future<CameraFacing> switchCamera() async => CameraFacing.front;
  @override
  Future<void> suspendCaptureForReview() async {}
  @override
  Future<void> discardStaged(String relativePath) async {
    discardedPaths.add(relativePath);
  }

  @override
  Future<void> startCapture(String operationId, {required int maxDurationUs}) =>
      throw UnimplementedError();
  @override
  Future<CapturedMedia> stopCapture(String operationId) =>
      throw UnimplementedError();
  @override
  Future<CapturedMedia?> pickVideo(String operationId) async {
    pickCalls += 1;
    return pickAction == null ? pickedVideo : await pickAction!(operationId);
  }

  @override
  Future<InspectedMedia> inspectStaged(String path) =>
      throw UnimplementedError();
}

final class _FakeDelivery implements MediaDeliveryGateway {
  final saved = <String>[];
  final shared = <String>[];

  @override
  Future<void> saveToPhotos(String relativePath) async =>
      saved.add(relativePath);

  @override
  Future<bool> share(String relativePath) async {
    shared.add(relativePath);
    return true;
  }
}

final class _FakePresentation implements MediaPresentationGateway {
  @override
  Future<AudioWaveform> waveform(String relativePath) async =>
      AudioWaveform(durationUs: 3000000, levels: List<double>.filled(96, 0.4));
  @override
  String get playbackViewType => 'fake-playback';
  @override
  Future<Uint8List> thumbnail(String relativePath) =>
      throw StateError('fake fixture has no image bytes');
  @override
  Future<void> play(int viewId) async {}
  @override
  Future<void> pause(int viewId) async {}
  @override
  Future<void> seek(int viewId, Duration position) async {}
  @override
  Future<Duration> position(int viewId) async => Duration.zero;
  @override
  Future<PlaybackSnapshot> playbackState(int viewId) async =>
      const PlaybackSnapshot(
        position: Duration.zero,
        duration: Duration(seconds: 15),
        isPlaying: false,
        ended: false,
      );
}
