import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../design/playback_chrome.dart';
import '../../design/tokens.dart';
import '../../domain/arrangement.dart';
import '../../domain/clip_asset.dart';
import '../../domain/project.dart';
import '../../domain/video_recipe.dart';
import '../arrange/adjustments_sheet.dart';
import '../library/library_screen.dart';
import '../settings/settings_screen.dart';
import '../../storage/project_repository.dart';
import '../../features/capture/capture_controller.dart';
import '../../features/capture/capture_screen.dart';
import '../../media/media_gateway.dart';
import '../../media/media_delivery_gateway.dart';
import '../export/media_playback.dart';
import 'creation_controller.dart';

class CreationFlow extends StatefulWidget {
  const CreationFlow({
    required this.controller,
    required this.media,
    this.delivery,
    this.startWithCapture = false,
    super.key,
  });

  final CreationController controller;
  final MediaGateway media;
  final MediaDeliveryGateway? delivery;
  final bool startWithCapture;

  @override
  State<CreationFlow> createState() => _CreationFlowState();
}

class _CreationFlowState extends State<CreationFlow> {
  var _captureOpened = false;
  var _tabIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.startWithCapture && !_captureOpened) {
      _captureOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openCapture());
    }
  }

  Future<void> _openCapture() async {
    final captured = await Navigator.of(context).push<CapturedMedia>(
      MaterialPageRoute(
        builder: (_) => _CaptureRoute(media: widget.media),
        fullscreenDialog: true,
      ),
    );
    if (captured != null) await widget.controller.addCaptured(captured);
  }

  Future<void> _openProject(Project project) async {
    await widget.controller.openProject(project);
    if (mounted) setState(() => _tabIndex = 0);
  }

  Future<void> _startCaptureFromLibrary() async {
    if (mounted) setState(() => _tabIndex = 0);
    if (widget.controller.state.phase == CreationPhase.completed) {
      widget.controller.startNew();
    }
    await _openCapture();
  }

  Future<void> _reuseAsset(ClipAsset asset) async {
    await widget.controller.addExisting(asset);
    if (mounted) setState(() => _tabIndex = 0);
  }

  Widget _settings() {
    final projects = widget.controller.projects;
    if (projects is! SqliteProjectRepository) {
      return const Scaffold(body: Center(child: Text('設定を読み込めません')));
    }
    return SettingsScreen(
      usageLoader: projects.storageUsage,
      clearCache: projects.clearRegenerableCache,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final state = widget.controller.state;
      final content = switch (_tabIndex) {
        1 => LibraryScreen(
          projects: widget.controller.projects,
          assets: widget.controller.assets,
          initialTabIndex: 0,
          onCreate: _startCaptureFromLibrary,
          onProjectSelected: _openProject,
          onAssetSelected: _reuseAsset,
          onSettings: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => _settings())),
        ),
        _ => _creationContent(state),
      };
      return Scaffold(
        body: content,
        bottomNavigationBar: content is _CollectScreen || _tabIndex == 1
            ? NavigationBar(
                selectedIndex: _tabIndex,
                onDestinationSelected: (value) =>
                    setState(() => _tabIndex = value),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.add_circle_outline),
                    label: 'つくる',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.video_library_outlined),
                    label: 'ライブラリ',
                  ),
                ],
              )
            : null,
      );
    },
  );

  Widget _creationContent(CreationState state) {
    if (state.phase == CreationPhase.completed) {
      return _CompletedScreen(
        controller: widget.controller,
        delivery: widget.delivery,
        onOpenLibrary: () => setState(() => _tabIndex = 1),
      );
    }
    if (state.preview != null ||
        state.phase == CreationPhase.rendering ||
        (state.phase == CreationPhase.failed && state.project != null)) {
      return _ArrangeScreen(controller: widget.controller);
    }
    return _CollectScreen(
      controller: widget.controller,
      onCapture: _openCapture,
    );
  }
}

class _CollectScreen extends StatelessWidget {
  const _CollectScreen({required this.controller, required this.onCapture});
  final CreationController controller;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'オトグラシ',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (state.clips.isNotEmpty)
            TextButton(
              onPressed: controller.startNew,
              child: const Text('新しくつくる'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Transform.rotate(
                angle: -0.035,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: AppTokens.paper,
                  child: const Text(
                    'STEP 1  /  音の採集ノート',
                    style: TextStyle(
                      color: AppTokens.ink,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              state.clips.isEmpty
                  ? 'いつもの音を、\n3つ集めよう。'
                  : '${state.clips.length}つの音が\n集まりました。',
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(height: 10),
            const Text(
              'コップ、蛇口、キーボード。身のまわりの音が15秒の動画になります。',
              style: TextStyle(color: AppTokens.mutedInk, height: 1.5),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                for (var index = 0; index < 3; index++) ...[
                  Expanded(
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: index < state.clips.length
                            ? AppTokens.coral
                            : const Color(0xFFE9E1DA),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  if (index < 2) const SizedBox(width: 7),
                ],
                const SizedBox(width: 12),
                Text(
                  '${state.clips.length}/3',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            const SizedBox(height: 22),
            if (state.clips.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 38,
                  horizontal: 22,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFE9E1DA)),
                ),
                child: const Column(
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      color: AppTokens.coral,
                      size: 42,
                    ),
                    SizedBox(height: 12),
                    Text(
                      '家の中の短い音を、まず3つ。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    SizedBox(height: 5),
                    Text('同じ場所の音でも大丈夫。', textAlign: TextAlign.center),
                  ],
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: state.clips.length,
                onReorderItem: controller.reorder,
                itemBuilder: (context, index) => _ClipCard(
                  key: ValueKey(state.clips[index].id),
                  clip: state.clips[index],
                  index: index,
                  thumbnail: state.thumbnails[state.clips[index].id],
                  onRemove: () =>
                      unawaited(controller.removeClip(state.clips[index].id)),
                  onMove: (offset) {
                    final target = (index + offset).clamp(
                      0,
                      state.clips.length - 1,
                    );
                    if (target != index) {
                      unawaited(controller.reorder(index, target));
                    }
                  },
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: state.clips.length >= 6 ? null : onCapture,
              icon: const Icon(Icons.add_rounded),
              label: const Text('音を録る・動画を選ぶ'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.coral,
                foregroundColor: AppTokens.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.clips.length < 3
                  ? 'あと${3 - state.clips.length}つで音楽にできます'
                  : '${state.clips.length}つの音で音楽をつくれます',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTokens.mutedInk),
            ),
            if (state.phase == CreationPhase.preparing) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('音を確かめています', textAlign: TextAlign.center),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(
                '準備できませんでした。素材を確認して、もう一度お試しください。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: state.phase == CreationPhase.readyToCreate
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: FilledButton(
                  onPressed: controller.createPreview,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTokens.ink,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('この音で15秒をつくる  ↗'),
                ),
              ),
            )
          : null,
    );
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({
    required this.clip,
    required this.index,
    required this.thumbnail,
    required this.onMove,
    required this.onRemove,
    super.key,
  });
  final ClipAsset clip;
  final int index;
  final dynamic thumbnail;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    final title = generatedName ? '録った音 ${index + 1}' : clip.label;
    return Semantics(
      sortKey: OrdinalSortKey(index.toDouble()),
      label:
          '$title、${(clip.selectionDurationUs / 1000000).toStringAsFixed(1)}秒、${index + 1}番目',
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFFEAE3DD)),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 112,
          child: Row(
            children: [
              SizedBox(
                width: 102,
                height: 112,
                child: thumbnail != null
                    ? Image.memory(thumbnail, fit: BoxFit.cover)
                    : _ThumbnailFallback(
                        index: index,
                        synthetic:
                            clip.label.startsWith('synthetic-') ||
                            clip.label.startsWith('合成素材'),
                      ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'SOUND ${(index + 1).toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          color: AppTokens.coral,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${(clip.selectionDurationUs / 1000000).toStringAsFixed(1)}秒の動画',
                        style: const TextStyle(
                          color: AppTokens.mutedInk,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<int>(
                tooltip: '順番を変更',
                onSelected: onMove,
                itemBuilder: (_) => [
                  if (index > 0)
                    const PopupMenuItem(value: -1, child: Text('ひとつ上へ')),
                  const PopupMenuItem(value: 1, child: Text('ひとつ下へ')),
                ],
                icon: const Icon(Icons.swap_vert_rounded, size: 21),
              ),
              IconButton(
                onPressed: onRemove,
                tooltip: '$titleを作品から外す',
                icon: const Icon(Icons.close_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailFallback extends StatelessWidget {
  const _ThumbnailFallback({required this.index, required this.synthetic});
  final int index;
  final bool synthetic;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: index.isEven
            ? const [Color(0xFF9A83C4), Color(0xFF6E5A94)]
            : const [Color(0xFFE89586), Color(0xFFB86562)],
      ),
    ),
    child: Center(
      child: Text(
        synthetic ? '合成\nサンプル映像' : 'サムネイルを\n表示できません',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

class _ArrangeScreen extends StatefulWidget {
  const _ArrangeScreen({required this.controller});
  final CreationController controller;

  @override
  State<_ArrangeScreen> createState() => _ArrangeScreenState();
}

class _ArrangeScreenState extends State<_ArrangeScreen> {
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.controller.presentation,
  );

  @override
  void dispose() {
    _scrollController.dispose();
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final segments = widget.controller.comparisonSegments;
    final path = state.compareOriginal
        ? state.clips.firstOrNull?.relativePath
        : state.preview?.relativePath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('音づくり'),
        centerTitle: true,
        leading: IconButton(
          onPressed: widget.controller.editClips,
          tooltip: '素材に戻る',
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: SafeArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          children: [
            const Text(
              'STEP 2  /  音の変化を聴く',
              style: TextStyle(
                color: AppTokens.coral,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              'いつもの音が、\n15秒の曲に。',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 18),
            PlaybackChrome(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: path == null
                      ? const _PreviewPlaceholder()
                      : NativeMovieView(
                          key: ValueKey(
                            '$path:${state.compareOriginal}:${state.project?.revision}',
                          ),
                          relativePath: path,
                          segments: state.compareOriginal ? segments : const [],
                          gateway: widget.controller.presentation,
                          controller: playback,
                          fallback: _SyntheticPreview(clips: state.clips),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (state.phase == CreationPhase.rendering ||
                state.phase == CreationPhase.preparing)
              const Column(
                children: [
                  LinearProgressIndicator(),
                  SizedBox(height: 8),
                  Text('15秒のプレビューをつくっています'),
                ],
              )
            else if (state.phase == CreationPhase.failed)
              Text(
                'プレビューを作れませんでした。別のアレンジでもう一度お試しください。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              )
            else
              _PlaybackControls(
                playback: playback,
                label: state.compareOriginal
                    ? '素材のまま・${state.clips.length}素材を続けて再生'
                    : '曲になった音',
              ),
            const SizedBox(height: 20),
            const Text(
              '聴き比べる',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('元の音')),
                ButtonSegment(value: false, label: Text('できた曲')),
              ],
              selected: {state.compareOriginal},
              onSelectionChanged: state.preview == null
                  ? null
                  : (value) async {
                      await playback.pause();
                      widget.controller.setCompareOriginal(value.single);
                    },
            ),
            const SizedBox(height: 20),
            const Text(
              '曲の雰囲気',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ArrangementStyle>(
              segments: const [
                ButtonSegment(
                  value: ArrangementStyle.sparse,
                  label: Text('ぽつぽつ'),
                ),
                ButtonSegment(
                  value: ArrangementStyle.swaying,
                  label: Text('ゆらゆら'),
                ),
                ButtonSegment(
                  value: ArrangementStyle.lively,
                  label: Text('にぎやか'),
                ),
              ],
              selected: {state.style},
              onSelectionChanged: (value) =>
                  widget.controller.selectStyle(value.single),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: widget.controller.another,
              child: const Text('同じ音でもうひとつ作る'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => _showAdjustments(context),
              child: const Text('かんたん調整'),
            ),
            if (state.phase == CreationPhase.failed) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: widget.controller.createPreview,
                child: const Text('プレビューを作り直す'),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: FilledButton(
            onPressed: state.phase == CreationPhase.ready
                ? widget.controller.complete
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.coral,
              foregroundColor: AppTokens.ink,
            ),
            child: const Text('これで完成'),
          ),
        ),
      ),
    );
  }

  Future<void> _showAdjustments(BuildContext context) =>
      showAdjustmentsSheet(context, widget.controller);
}

class _CompletedScreen extends StatefulWidget {
  const _CompletedScreen({
    required this.controller,
    required this.delivery,
    required this.onOpenLibrary,
  });
  final CreationController controller;
  final MediaDeliveryGateway? delivery;
  final VoidCallback onOpenLibrary;

  @override
  State<_CompletedScreen> createState() => _CompletedScreenState();
}

class _CompletedScreenState extends State<_CompletedScreen> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.controller.presentation,
  );
  late final MediaDeliveryGateway delivery =
      widget.delivery ?? PlatformMediaDeliveryGateway();
  RenderedMedia? _fullVideo;
  String? _exportOperationId;
  bool _exportRecorded = false;
  bool _busy = false;
  bool _saved = false;
  String? _message;

  Future<RenderedMedia> _ensureFullVideo() async {
    final project = widget.controller.state.project!;
    var video = _fullVideo;
    if (video == null || video.revision != project.revision) {
      final operationId = 'export-${DateTime.now().microsecondsSinceEpoch}';
      _exportOperationId = operationId;
      try {
        video = await widget.controller.media.render(
          RenderRequest(
            operationId: operationId,
            projectId: project.id,
            revision: project.revision,
            arrangement: Arrangement.fromJson(project.arrangement),
            video: VideoRecipe.fromJson(project.videoRecipe),
            quality: RenderQuality.full,
          ),
        );
      } finally {
        if (_exportOperationId == operationId) _exportOperationId = null;
      }
      _fullVideo = video;
      _exportRecorded = false;
    }
    final projects = widget.controller.projects;
    if (!_exportRecorded && projects is SqliteProjectRepository) {
      await projects.recordCompletedExport(
        projectId: project.id,
        sourceRevision: project.revision,
        relativePath: video.relativePath,
      );
      _exportRecorded = true;
    }
    return video;
  }

  Future<void> _save() async {
    if (_busy || _saved) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final video = await _ensureFullVideo();
      await delivery.saveToPhotos(video.relativePath);
      if (mounted) {
        setState(() {
          _saved = true;
          _message = '写真に保存しました';
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _message = error.code == 'photos_permission_denied'
              ? '写真への追加を許可してください。iPhoneの設定から変更できます。'
              : '保存できませんでした。もう一度お試しください。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _message = '保存できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final video = await _ensureFullVideo();
      await delivery.share(video.relativePath);
    } catch (_) {
      if (mounted) setState(() => _message = '共有できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    final exportId = _exportOperationId;
    if (exportId != null) unawaited(widget.controller.media.cancel(exportId));
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return Scaffold(
      backgroundColor: AppTokens.surfaceColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppTokens.ink,
        title: const Text('できあがり'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            const Text(
              'STEP 3  /  今日の音、完成！',
              style: TextStyle(
                color: AppTokens.coral,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              'いつもの音が、\nちょっと特別に。',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 7),
            Text(
              state.project?.title ?? '今日の音',
              style: const TextStyle(color: AppTokens.mutedInk),
            ),
            const SizedBox(height: 16),
            Center(
              child: SizedBox(
                width: 300,
                child: PlaybackChrome(
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: NativeMovieView(
                      relativePath: state.preview!.relativePath,
                      gateway: widget.controller.presentation,
                      controller: playback,
                      fallback: _SyntheticPreview(clips: state.clips),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _PlaybackControls(playback: playback, label: '完成した15秒'),
            const SizedBox(height: 8),
            const Text(
              '映り込みや会話がないか、最後に確認してください。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTokens.mutedInk),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: widget.controller.startNew,
              child: const Text('新しくつくる'),
            ),
            TextButton(
              onPressed: widget.onOpenLibrary,
              child: const Text('作品を見る'),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 7),
                const Text('動画を準備しています'),
              ],
              if (_message != null) ...[
                Text(_message!, textAlign: TextAlign.center),
                const SizedBox(height: 7),
              ],
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy || _saved ? null : _save,
                      icon: Icon(
                        _saved ? Icons.check_rounded : Icons.download_rounded,
                      ),
                      label: Text(_saved ? '保存済み' : '保存する'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _share,
                      icon: const Icon(Icons.ios_share_rounded),
                      label: const Text('シェアする'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.coral,
                        foregroundColor: AppTokens.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.playback, required this.label});

  final MediaPlaybackController playback;
  final String label;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      final durationUs = playback.duration.inMicroseconds.clamp(1, 1 << 53);
      final positionUs = playback.position.inMicroseconds.clamp(0, durationUs);
      return Column(
        children: [
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: playback.toggle,
                tooltip: playback.isPlaying ? '一時停止' : '再生',
                icon: Text(
                  playback.isPlaying ? 'Ⅱ' : '▶',
                  style: const TextStyle(fontSize: 19),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(label)),
              Text(
                '${_seconds(playback.position)} / ${_seconds(playback.duration)}',
              ),
            ],
          ),
          Semantics(
            label: '再生位置',
            value: '${playback.position.inSeconds}秒',
            child: Slider(
              value: positionUs.toDouble(),
              max: durationUs.toDouble(),
              onChanged: (value) => unawaited(
                playback.seek(Duration(microseconds: value.round())),
              ),
            ),
          ),
          if (playback.error != null)
            Text(
              '再生できませんでした。もう一度お試しください。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );

  static String _seconds(Duration value) =>
      '${value.inSeconds.toString().padLeft(2, '0')}秒';
}

class _PreviewPlaceholder extends StatelessWidget {
  const _PreviewPlaceholder();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF302D36),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _SyntheticPreview extends StatelessWidget {
  const _SyntheticPreview({required this.clips});
  final List<ClipAsset> clips;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF302D36),
    child: Column(
      children: [
        for (var index = 0; index < 3; index++)
          Expanded(
            child: Container(
              width: double.infinity,
              color: [
                const Color(0xFF8069B2),
                const Color(0xFFCB766D),
                const Color(0xFF63958B),
              ][index],
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(12),
              child: Text(
                clips.elementAtOrNull(index)?.label ?? '合成素材',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _CaptureRoute extends StatefulWidget {
  const _CaptureRoute({required this.media});
  final MediaGateway media;

  @override
  State<_CaptureRoute> createState() => _CaptureRouteState();
}

class _CaptureRouteState extends State<_CaptureRoute> {
  late final CaptureController controller = CaptureController(
    widget.media,
    operationIdFactory: () =>
        'capture-${DateTime.now().microsecondsSinceEpoch}',
  );

  @override
  void dispose() {
    unawaited(controller.releaseCapture());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CaptureScreen(
    controller: controller,
    onMediaReady: () {
      final media = controller.state.capturedMedia;
      if (media != null) Navigator.pop(context, media);
    },
  );
}
