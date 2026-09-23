import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design/clipboard_chrome.dart';
import '../../design/playback_chrome.dart';
import '../../design/pressable.dart';
import '../../design/tokens.dart';
import '../../domain/arrangement.dart';
import '../../domain/clip_asset.dart';
import '../../domain/project.dart';
import '../arrange/adjustments_sheet.dart';
import '../library/library_screen.dart';
import '../settings/settings_screen.dart';
import '../../storage/project_repository.dart';
import '../../features/capture/capture_controller.dart';
import '../../features/capture/capture_screen.dart';
import '../../media/media_gateway.dart';
import '../export/media_playback.dart';
import 'creation_controller.dart';

class CreationFlow extends StatefulWidget {
  const CreationFlow({
    required this.controller,
    required this.media,
    this.startWithCapture = false,
    super.key,
  });

  final CreationController controller;
  final MediaGateway media;
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
        2 => LibraryScreen(
          projects: widget.controller.projects,
          assets: widget.controller.assets,
          initialTabIndex: 1,
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
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (value) => setState(() => _tabIndex = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.add_circle_outline),
              label: 'つくる',
            ),
            NavigationDestination(
              icon: Icon(Icons.movie_creation_outlined),
              label: '作品',
            ),
            NavigationDestination(
              icon: Icon(Icons.library_music_outlined),
              label: '音の引き出し',
            ),
          ],
        ),
      );
    },
  );

  Widget _creationContent(CreationState state) {
    if (state.phase == CreationPhase.completed) {
      return _CompletedScreen(controller: widget.controller);
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
        title: const Text('今日のクリップ'),
        centerTitle: true,
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
          padding: const EdgeInsets.all(AppTokens.pagePadding),
          children: [
            ClipboardChrome(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.clips.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Text(
                        '家の中の短い音を、まず3つ。',
                        textAlign: TextAlign.center,
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
                        onRemove: () => unawaited(
                          controller.removeClip(state.clips[index].id),
                        ),
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
                  OutlinedButton(
                    onPressed: onCapture,
                    child: const Text('＋  撮影・写真から取り込む'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text(
              state.clips.length < 3
                  ? 'あと${3 - state.clips.length}つで音楽にできます'
                  : '${state.clips.length}つの音がそろいました',
              textAlign: TextAlign.center,
            ),
            if (state.phase == CreationPhase.preparing) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('音を確かめています', textAlign: TextAlign.center),
            ],
            if (state.phase == CreationPhase.readyToCreate) ...[
              const SizedBox(height: 16),
              Pressable(
                onPressed: controller.createPreview,
                semanticLabel: 'この音でつくる',
                child: Container(
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Text(
                    'この音でつくる',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
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
  Widget build(BuildContext context) => Semantics(
    sortKey: OrdinalSortKey(index.toDouble()),
    label:
        '${clip.label}、${(clip.selectionDurationUs / 1000000).toStringAsFixed(1)}秒、${index + 1}番目',
    child: Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 104,
        child: Row(
          children: [
            SizedBox(
              width: 132,
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
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      clip.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${(clip.selectionDurationUs / 1000000).toStringAsFixed(1)}秒',
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
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                child: Text(
                  '順番',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            IconButton(
              onPressed: onRemove,
              tooltip: '${clip.label}を作品から外す',
              icon: const Icon(Icons.close_rounded),
            ),
            const SizedBox(width: 4),
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
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.controller.presentation,
  );

  @override
  void dispose() {
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
        actions: [
          IconButton(
            onPressed: widget.controller.editClips,
            tooltip: '素材を編集',
            icon: const Icon(Icons.edit_outlined),
          ),
          Pressable(
            enabled: state.phase == CreationPhase.ready,
            onPressed: widget.controller.complete,
            semanticLabel: 'これで完成',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'これで完成',
                style: TextStyle(
                  color: state.phase == CreationPhase.ready
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).disabledColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppTokens.pagePadding),
          children: [
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
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: state.preview == null
                        ? null
                        : () => widget.controller.setCompareOriginal(
                            !state.compareOriginal,
                          ),
                    child: Text(state.compareOriginal ? '曲に戻す' : '元の音と比べる'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: widget.controller.another,
                    child: const Text('もうひとつ'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () => _showAdjustments(context),
              child: const Text('かんたん調整'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _showAdjustments(BuildContext context) =>
      showAdjustmentsSheet(context, widget.controller);
}

class _CompletedScreen extends StatefulWidget {
  const _CompletedScreen({required this.controller});
  final CreationController controller;

  @override
  State<_CompletedScreen> createState() => _CompletedScreenState();
}

class _CompletedScreenState extends State<_CompletedScreen> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.controller.presentation,
  );

  @override
  void dispose() {
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return Scaffold(
      backgroundColor: const Color(0xFF17161B),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('つくれたよ'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text(
              state.project?.title ?? '今日の音',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 10),
            Center(
              child: SizedBox(
                width: 286,
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
            _PlaybackControls(playback: playback, label: '完成した15秒', dark: true),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    enabled: false,
                    label: '保存、書き出し後に利用できます',
                    child: const _PendingExportButton(label: '↓  保存'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    button: true,
                    enabled: false,
                    label: 'シェア、書き出し後に利用できます',
                    child: const _PendingExportButton(label: '↑  シェア'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '映り込みや会話がないか、最後に確認してください。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFFCBC7D2)),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: widget.controller.startNew,
              child: const Text('新しくつくる'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.playback,
    required this.label,
    this.dark = false,
  });

  final MediaPlaybackController playback;
  final String label;
  final bool dark;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      final durationUs = playback.duration.inMicroseconds.clamp(1, 1 << 53);
      final positionUs = playback.position.inMicroseconds.clamp(0, durationUs);
      final foreground = dark ? Colors.white : null;
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
              Expanded(
                child: Text(label, style: TextStyle(color: foreground)),
              ),
              Text(
                '${_seconds(playback.position)} / ${_seconds(playback.duration)}',
                style: TextStyle(color: foreground),
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
              style: TextStyle(
                color: dark
                    ? const Color(0xFFFFA8A2)
                    : Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      );
    },
  );

  static String _seconds(Duration value) =>
      '${value.inSeconds.toString().padLeft(2, '0')}秒';
}

class _PendingExportButton extends StatelessWidget {
  const _PendingExportButton({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 52,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFF302E35),
      border: Border.all(color: const Color(0xFF74717B)),
      borderRadius: BorderRadius.circular(26),
    ),
    child: Text(
      label,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
    ),
  );
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
