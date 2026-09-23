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
import '../../media/media_presentation_gateway.dart';
import '../../media/media_delivery_gateway.dart';
import '../export/comparison_player.dart';
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
        builder: (_) => _CaptureRoute(
          media: widget.media,
          presentation: widget.controller.presentation,
        ),
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
          presentation: widget.controller.presentation,
          delivery: widget.delivery ?? PlatformMediaDeliveryGateway(),
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

  Future<void> _previewClip(BuildContext context, ClipAsset clip, int index) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _ClipPreviewSheet(
          clip: clip,
          segment: controller.comparisonSegments[index],
          presentation: controller.presentation,
        ),
      );

  Future<void> _renameClip(
    BuildContext context,
    ClipAsset clip,
    int index,
  ) async {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    var name = generatedName ? '録った音 ${index + 1}' : clip.label;
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音に名前をつける'),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: '例：コップを置く音'),
          onChanged: (value) => name = value,
          onFieldSubmitted: (_) => Navigator.pop(dialogContext, name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, name),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (chosen == null || chosen.trim().isEmpty || !context.mounted) return;
    try {
      await controller.renameClip(clip.id, chosen);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('名前を保存できませんでした')));
      }
    }
  }

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
                  onPreview: () =>
                      _previewClip(context, state.clips[index], index),
                  onRename: () =>
                      _renameClip(context, state.clips[index], index),
                  onRemove: () =>
                      unawaited(controller.removeClip(state.clips[index].id)),
                  canMoveDown: index < state.clips.length - 1,
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

enum _ClipAction { rename, moveUp, moveDown, remove }

class _ClipCard extends StatelessWidget {
  const _ClipCard({
    required this.clip,
    required this.index,
    required this.thumbnail,
    required this.onPreview,
    required this.onRename,
    required this.onMove,
    required this.onRemove,
    required this.canMoveDown,
    super.key,
  });
  final ClipAsset clip;
  final int index;
  final Uint8List? thumbnail;
  final VoidCallback onPreview;
  final VoidCallback onRename;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;
  final bool canMoveDown;

  @override
  Widget build(BuildContext context) {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    final title = generatedName ? '録った音 ${index + 1}' : clip.label;
    final duration =
        '${(clip.selectionDurationUs / 1000000).toStringAsFixed(1)}秒';
    return Semantics(
      sortKey: OrdinalSortKey(index.toDouble()),
      label: '$title、$duration、${index + 1}番目。タップして音を確認',
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 2,
        shadowColor: const Color(0x334F332B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE9DDD4)),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 112,
          child: Stack(
            fit: StackFit.expand,
            children: [
              thumbnail != null
                  ? Image.memory(thumbnail!, fit: BoxFit.cover)
                  : _ThumbnailFallback(
                      index: index,
                      synthetic:
                          clip.label.startsWith('synthetic-') ||
                          clip.label.startsWith('合成素材'),
                    ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x44000000),
                      Color(0x11000000),
                      Color(0xCC1C171B),
                    ],
                  ),
                ),
              ),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onPreview,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                left: 14,
                top: 12,
                child: Transform.rotate(
                  angle: -0.035,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    color: AppTokens.paper,
                    child: Text(
                      '音 ${(index + 1).toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        color: AppTokens.ink,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 8,
                top: 6,
                child: Material(
                  color: const Color(0xDDFFF8F1),
                  shape: const CircleBorder(),
                  child: PopupMenuButton<_ClipAction>(
                    tooltip: '$titleのメニュー',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onSelected: (action) => switch (action) {
                      _ClipAction.rename => onRename(),
                      _ClipAction.moveUp => onMove(-1),
                      _ClipAction.moveDown => onMove(1),
                      _ClipAction.remove => onRemove(),
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: _ClipAction.rename,
                        child: Text('名前を変える'),
                      ),
                      if (index > 0)
                        const PopupMenuItem(
                          value: _ClipAction.moveUp,
                          child: Text('ひとつ前へ'),
                        ),
                      if (canMoveDown)
                        const PopupMenuItem(
                          value: _ClipAction.moveDown,
                          child: Text('ひとつ後ろへ'),
                        ),
                      const PopupMenuItem(
                        value: _ClipAction.remove,
                        child: Text('作品から外す'),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 13,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onPreview,
                  child: Row(
                    children: [
                      const Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 32,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        duration,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClipPreviewSheet extends StatefulWidget {
  const _ClipPreviewSheet({
    required this.clip,
    required this.segment,
    required this.presentation,
  });

  final ClipAsset clip;
  final PlaybackSegment segment;
  final MediaPresentationGateway presentation;

  @override
  State<_ClipPreviewSheet> createState() => _ClipPreviewSheetState();
}

class _ClipPreviewSheetState extends State<_ClipPreviewSheet> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.presentation,
  );

  @override
  void dispose() {
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: 0.78,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.clip.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '閉じる',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('曲にする前の、元の動画と音'),
            const SizedBox(height: 14),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: NativeMovieView(
                      relativePath: widget.clip.relativePath,
                      segments: [widget.segment],
                      gateway: widget.presentation,
                      controller: playback,
                      fallback: const ColoredBox(
                        color: Color(0xFF302D36),
                        child: Center(child: Text('元の動画')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _PlaybackControls(playback: playback, label: '元の音'),
          ],
        ),
      ),
    ),
  );
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
      child: Icon(
        synthetic ? Icons.graphic_eq_rounded : Icons.broken_image_outlined,
        size: 40,
        color: Colors.white70,
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

  Future<void> _openComparison() async {
    final state = widget.controller.state;
    final songPath = state.preview?.relativePath;
    if (songPath == null) return;
    await playback.pause();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComparisonPlayer(
          songPath: songPath,
          originalSegments: widget.controller.comparisonSegments,
          presentation: widget.controller.presentation,
          fallback: _SyntheticPreview(clips: state.clips),
        ),
      ),
    );
  }

  String get _soundWord {
    final captions = widget.controller.state.project?.videoRecipe['captions'];
    if (captions is! List || captions.isEmpty || captions.first is! Map) {
      return '';
    }
    return (captions.first as Map)['text'] as String? ?? '';
  }

  Future<void> _editSoundWord() async {
    final before = _soundWord;
    var draft = before;
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('動画にひとこと'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('曲の入りに、短く文字を出します。入れなくても大丈夫。'),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: before,
              autofocus: true,
              maxLength: 12,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                hintText: 'わっ！  コトッ  カタカタ',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => draft = value,
              onFieldSubmitted: (_) => Navigator.pop(dialogContext, draft),
            ),
          ],
        ),
        actions: [
          if (before.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, ''),
              child: const Text('文字を消す'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('動画に入れる'),
          ),
        ],
      ),
    );
    if (!mounted || chosen == null) return;
    final text = chosen.trim();
    final captions = widget.controller.state.project?.videoRecipe['captions'];
    final current =
        captions is List && captions.isNotEmpty && captions.first is Map
        ? captions.first as Map
        : null;
    if (text == before &&
        (text.isEmpty ||
            (current?['destinationStartSample'] == 0 &&
                current?['durationSamples'] == 72_000 &&
                current?['x'] == .5 &&
                current?['y'] == .22))) {
      return;
    }
    if (text.isEmpty) {
      if (before.isNotEmpty) await widget.controller.removeCaption(0);
    } else {
      await widget.controller.setCaption(
        text,
        x: .5,
        y: .22,
        destinationStartSample: 0,
        durationSamples: 72_000,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final path = state.preview?.relativePath;
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
              'さっきの場面が、\n曲になっていく。',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 18),
            Center(
              child: PlaybackChrome(
                child: SizedBox(
                  width: 225,
                  child: Stack(
                    children: [
                      AspectRatio(
                        aspectRatio: 9 / 16,
                        child: path == null
                            ? const _PreviewPlaceholder()
                            : NativeMovieView(
                                key: ValueKey(
                                  '$path:${state.project?.revision}',
                                ),
                                relativePath: path,
                                gateway: widget.controller.presentation,
                                controller: playback,
                                fallback: _SyntheticPreview(clips: state.clips),
                              ),
                      ),
                      if (path != null)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: _CompareVideoButton(
                            onPressed: _openComparison,
                          ),
                        ),
                    ],
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
              _PlaybackControls(playback: playback, label: '曲になった音'),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: state.phase == CreationPhase.ready
                  ? _editSoundWord
                  : null,
              icon: const Icon(Icons.edit_note_rounded),
              label: Text(
                _soundWord.isEmpty ? '動画にひとこと足す' : 'ひとこと「$_soundWord」を編集',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 16),
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

  Future<void> _openComparison() async {
    await playback.pause();
    if (!mounted) return;
    final state = widget.controller.state;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComparisonPlayer(
          songPath: state.preview!.relativePath,
          originalSegments: widget.controller.comparisonSegments,
          presentation: widget.controller.presentation,
          fallback: _SyntheticPreview(clips: state.clips),
        ),
      ),
    );
  }

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
              'あの瞬間が、\nみんなの曲に。',
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
                  child: Stack(
                    children: [
                      AspectRatio(
                        aspectRatio: 9 / 16,
                        child: NativeMovieView(
                          relativePath: state.preview!.relativePath,
                          gateway: widget.controller.presentation,
                          controller: playback,
                          fallback: _SyntheticPreview(clips: state.clips),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _CompareVideoButton(onPressed: _openComparison),
                      ),
                    ],
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

class _CompareVideoButton extends StatelessWidget {
  const _CompareVideoButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size(44, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      backgroundColor: AppTokens.paper,
      foregroundColor: AppTokens.ink,
    ),
    icon: const Icon(Icons.open_in_full_rounded, size: 18),
    label: const Text('見くらべる'),
  );
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
                onPressed: playback.isReady ? playback.toggle : null,
                tooltip: playback.isLoading
                    ? '動画を読み込み中'
                    : playback.isPlaying
                    ? '一時停止'
                    : '再生',
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
              onChanged: playback.isReady
                  ? (value) => unawaited(
                      playback.seek(Duration(microseconds: value.round())),
                    )
                  : null,
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
  const _CaptureRoute({required this.media, required this.presentation});
  final MediaGateway media;
  final MediaPresentationGateway presentation;

  @override
  State<_CaptureRoute> createState() => _CaptureRouteState();
}

class _CaptureRouteState extends State<_CaptureRoute> {
  bool _committed = false;
  late final CaptureController controller = CaptureController(
    widget.media,
    operationIdFactory: () =>
        'capture-${DateTime.now().microsecondsSinceEpoch}',
  );

  @override
  void dispose() {
    final unselected = controller.state.capturedMedia;
    if (!_committed && unselected != null) {
      unawaited(_discardUnselected(unselected.relativePath));
    }
    unawaited(controller.releaseCapture());
    controller.dispose();
    super.dispose();
  }

  Future<void> _discardUnselected(String path) async {
    try {
      await widget.media.discardStaged(path);
    } catch (_) {
      // Leaving this screen should still succeed if staging cleanup fails.
    }
  }

  @override
  Widget build(BuildContext context) => CaptureScreen(
    controller: controller,
    presentation: widget.presentation,
    onMediaReady: () {
      final media = controller.state.capturedMedia;
      if (media != null) {
        _committed = true;
        Navigator.pop(context, media);
      }
    },
  );
}
