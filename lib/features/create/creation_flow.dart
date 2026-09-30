import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/playback_chrome.dart';
import '../../design/rolling_tab_bar.dart';
import '../../design/tokens.dart';
import '../../domain/arrangement.dart';
import '../../domain/clip_asset.dart';
import '../../domain/melody_template.dart';
import '../../domain/project.dart';
import '../../domain/video_recipe.dart';
import '../arrange/adjustments_sheet.dart';
import '../home/home_screen.dart';
import '../library/library_screen.dart';
import '../settings/settings_screen.dart';
import '../songs/songs_screen.dart';
import '../../storage/project_repository.dart';
import '../../features/capture/capture_controller.dart';
import '../../features/capture/capture_screen.dart';
import '../../features/capture/capture_state.dart';
import '../../media/media_gateway.dart';
import '../../media/media_presentation_gateway.dart';
import '../../media/media_delivery_gateway.dart';
import '../export/comparison_player.dart';
import '../export/media_playback.dart';
import 'beat_building_preview.dart';
import 'performance_controls.dart';
import 'clip_card.dart';
import 'creation_controller.dart';
import 'making_screen.dart';

class CreationFlow extends StatefulWidget {
  const CreationFlow({
    required this.controller,
    required this.media,
    this.delivery,
    this.startWithCapture = false,
    this.startInLibrary = false,
    super.key,
  });

  final CreationController controller;
  final MediaGateway media;
  final MediaDeliveryGateway? delivery;
  final bool startWithCapture;
  final bool startInLibrary;

  @override
  State<CreationFlow> createState() => _CreationFlowState();
}

final class _SongRoleSummary extends StatelessWidget {
  const _SongRoleSummary({required this.state});

  final CreationState state;

  @override
  Widget build(BuildContext context) {
    final isMidiScore = state.melody.isMidiScore;
    final arrangement = state.project?.arrangement;
    final roles =
        arrangement != null &&
            arrangement['melodyTemplate'] == state.melody.name
        ? arrangement['songRoles']
        : null;
    if (roles is! Map) {
      return Text(
        '撮った音の担当を探しています…',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    String name(Object? id) {
      if (id is! String) return 'お休み';
      for (final clip in state.clips) {
        if (clip.id == id) return clip.label;
      }
      return 'お休み';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('撮った音の担当', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry
                  in (isMidiScore
                          ? <String, Object?>{
                              'メロディ': roles['melody'],
                              'ベース': roles['bass'],
                              'ピアノ': roles['keys'],
                            }
                          : <String, Object?>{
                              '拍': roles['beat'],
                              'ベース風': roles['bass'],
                              'ピアノ風': roles['keys'],
                              '旋律': roles['melody'],
                            })
                      .entries)
                Chip(label: Text('${entry.key}  ${name(entry.value)}')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isMidiScore ? '音程が取れない音も、楽譜のリズムに合わせて鳴らします' : 'どの役割も、撮った音だけで鳴らしています',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _CreationFlowState extends State<CreationFlow> {
  var _captureOpened = false;
  late int _tabIndex = widget.startInLibrary ? 1 : 0;
  // Home shows the folder list; the current folder opens on top of it.
  var _folderOpen = true;
  var _capturing = false;
  String? _shownProjectId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.startWithCapture && !_captureOpened) {
      _captureOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openCapture());
    }
  }

  Future<void> _openCapture({bool fromPhotos = false}) async {
    final before = widget.controller.state.clips.map((clip) => clip.id).toSet();
    await Navigator.of(context).push<void>(
      // A fade, so the shutter (a Hero shared with the tab bar's mic ball)
      // is what visibly travels and grows into place.
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 460),
        reverseTransitionDuration: const Duration(milliseconds: 340),
        transitionsBuilder: (context, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
        pageBuilder: (_, _, _) => _CaptureRoute(
          media: widget.media,
          presentation: widget.controller.presentation,
          fromPhotos: fromPhotos,
          recordedClipCount: widget.controller.state.clips.length,
          onCommit: (captured) async {
            final added = await widget.controller.addCaptured(captured);
            if (added && mounted) unawaited(HapticFeedback.selectionClick());
            return added;
          },
        ),
        fullscreenDialog: true,
      ),
    );
    if (mounted) await _nameNewRelayClip(before);
  }

  Future<void> _nameNewRelayClip(Set<String> previousIds) async {
    if (!widget.controller.isRelay) return;
    final clips = widget.controller.state.clips;
    final newClips = clips.where((clip) => !previousIds.contains(clip.id));
    if (newClips.isEmpty) return;
    final clip = newClips.last;
    final person = TextEditingController(text: '${clips.length}人目');
    final sound = TextEditingController(text: '音');
    try {
      final label = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'この音はだれの？',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text('名前は完成動画にも表示されます。あとから変更できます。'),
              const SizedBox(height: 16),
              TextField(
                controller: person,
                maxLength: 16,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '撮った人'),
              ),
              TextField(
                controller: sound,
                maxLength: 20,
                decoration: const InputDecoration(labelText: '音の名前'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final who = person.text.trim();
                  final what = sound.text.trim();
                  final parts = [who, what].where((part) => part.isNotEmpty);
                  Navigator.pop(sheetContext, parts.join(' · '));
                },
                child: const Text('次の人へ渡す'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('あとで名前をつける'),
              ),
            ],
          ),
        ),
      );
      if (label != null && label.isNotEmpty && mounted) {
        try {
          await widget.controller.renameClip(clip.id, label);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('名前を保存できませんでした')));
          }
        }
      }
    } finally {
      person.dispose();
      sound.dispose();
    }
  }

  Future<void> _openProject(Project project) async {
    await widget.controller.openProject(project);
    if (mounted) {
      setState(() {
        _tabIndex = 0;
        _folderOpen = true;
      });
    }
  }

  /// The centre mic: the ball rolls onto it, then the camera opens; after
  /// capture the new sound lands in the current folder on Home.
  Future<void> _captureFromBar() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    await Future<void>.delayed(const Duration(milliseconds: 540));
    if (!mounted) return;
    try {
      await _startCaptureFromLibrary();
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _selectTab(RollingTab tab) {
    switch (tab) {
      case RollingTab.home:
        setState(() {
          if (_tabIndex == 0) _folderOpen = false;
          _tabIndex = 0;
        });
      case RollingTab.capture:
        unawaited(_captureFromBar());
      case RollingTab.songs:
        setState(() => _tabIndex = 1);
    }
  }

  Future<void> _startCaptureFromLibrary() async {
    if (mounted) {
      setState(() {
        _tabIndex = 0;
        _folderOpen = true;
      });
    }
    if (widget.controller.state.phase == CreationPhase.completed) {
      widget.controller.startNew();
    }
    await _openCapture();
  }

  Future<void> _reuseAsset(ClipAsset asset) async {
    final before = widget.controller.state.clips.map((clip) => clip.id).toSet();
    await widget.controller.addExisting(asset);
    if (mounted) {
      setState(() {
        _tabIndex = 0;
        _folderOpen = true;
      });
      await _nameNewRelayClip(before);
    }
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
        1 => SongsScreen(
          onSettings: _openSettings,
          onMakeWithTemplate: () => unawaited(_captureFromBar()),
          mine: LibraryScreen(
            projects: widget.controller.projects,
            assets: widget.controller.assets,
            presentation: widget.controller.presentation,
            delivery: widget.delivery ?? PlatformMediaDeliveryGateway(),
            initialTabIndex: 0,
            embedded: true,
            onCreate: _startCaptureFromLibrary,
            onProjectSelected: _openProject,
            onAssetSelected: _reuseAsset,
          ),
        ),
        _ => _creationContent(state),
      };
      final showBar =
          content is HomeScreen || content is _CollectScreen || _tabIndex == 1;
      return Scaffold(
        body: content,
        bottomNavigationBar: showBar
            ? SafeArea(
                top: false,
                child: RollingTabBar(
                  selected: _capturing
                      ? RollingTab.capture
                      : _tabIndex == 1
                      ? RollingTab.songs
                      : RollingTab.home,
                  onSelected: _selectTab,
                ),
              )
            : null,
      );
    },
  );

  void _openSettings() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => _settings()));

  Widget _creationContent(CreationState state) {
    if (state.phase == CreationPhase.completed) {
      return _CompletedScreen(
        controller: widget.controller,
        delivery: widget.delivery,
        onOpenLibrary: () => setState(() => _tabIndex = 1),
      );
    }
    // The first render of a song gets its own waiting screen; re-renders
    // after a setting change keep the arrange screen and its controls.
    if (state.preview != null) _shownProjectId = state.project?.id;
    if (state.phase == CreationPhase.rendering &&
        state.preview == null &&
        state.project?.id != _shownProjectId) {
      return MakingScreen(
        clips: state.clips,
        thumbnails: state.thumbnails,
        seconds: state.durationSeconds,
      );
    }
    if (state.preview != null ||
        state.phase == CreationPhase.rendering ||
        (state.phase == CreationPhase.failed && state.project != null)) {
      return _ArrangeScreen(controller: widget.controller);
    }
    if (!_folderOpen) {
      return HomeScreen(
        currentClips: state.clips,
        thumbnails: state.thumbnails,
        assets: widget.controller.assets,
        presentation: widget.controller.presentation,
        ownerName: widget.controller.ownerName,
        onOpenCurrent: () => setState(() => _folderOpen = true),
        onAssetSelected: (asset) => unawaited(_reuseAsset(asset)),
        onSettings: _openSettings,
      );
    }
    return _CollectScreen(
      controller: widget.controller,
      onBack: () => setState(() => _folderOpen = false),
      onCapture: _openCapture,
      onPhotos: () => _openCapture(fromPhotos: true),
    );
  }
}

class _CollectScreen extends StatelessWidget {
  const _CollectScreen({
    required this.controller,
    required this.onBack,
    required this.onCapture,
    required this.onPhotos,
  });
  final CreationController controller;
  final VoidCallback onBack;
  final VoidCallback onCapture;
  final VoidCallback onPhotos;

  Future<void> _previewClip(BuildContext context, ClipAsset clip, int index) =>
      _previewClipSegment(context, clip, controller.comparisonSegments[index]);

  Future<void> _previewClipSegment(
    BuildContext context,
    ClipAsset clip,
    PlaybackSegment segment,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ClipPreviewSheet(
      clip: clip,
      segment: segment,
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

  Future<void> _removeClip(
    BuildContext context,
    ClipAsset clip,
    int index,
  ) async {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    final title = generatedName ? '録った音 ${index + 1}' : clip.label;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音を作品から外しますか？'),
        content: Text('「$title」を音の並びから外します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('外す'),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    await controller.removeClip(clip.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final segments = controller.comparisonSegments;
    final clipCount = state.clips.length;
    final collectionHint = clipCount == 0
        ? '1本から作成OK · 全6つまで'
        : clipCount < 6
        ? '作成OK · あと${6 - clipCount}つ追加できます'
        : '作成OK · 追加はここまで';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onBack,
          tooltip: 'フォルダ一覧',
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        title: const Text(
          'いま集めてる音',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (state.clips.isNotEmpty || controller.isRelay)
            TextButton(
              onPressed: controller.startNew,
              child: Text(state.clips.isEmpty ? 'ひとりでつくる' : '新しくつくる'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            state.clips.isEmpty ? 12 : 8,
            20,
            28,
          ),
          children: [
            if (state.clips.isEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Transform.rotate(
                  angle: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTokens.blushSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
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
                controller.isRelay ? 'ひとり一音、\nみんなで一曲。' : 'いつもの音が、\n音楽に変わる。',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 10),
              Text(
                controller.isRelay
                    ? 'スマホを順番に渡して、一人ずつ短い音を撮ろう。3人から作れます。'
                    : '声やリアクションは1本から。少ない素材は別の場面もパーツに。最大6本。',
                style: const TextStyle(color: AppTokens.mutedInk, height: 1.5),
              ),
              const SizedBox(height: 22),
            ],
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      for (var index = 0; index < 6; index++) ...[
                        Expanded(
                          child: Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: index < clipCount
                                  ? AppTokens.soundColor(index)
                                  : AppTokens.hairline,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        if (index < 5) SizedBox(width: index == 2 ? 12 : 5),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  controller.isRelay ? '$clipCount/6人' : '$clipCount/6',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            if (controller.isRelay || clipCount > 0) ...[
              const SizedBox(height: 4),
              Text(
                controller.isRelay
                    ? clipCount >= 6
                          ? 'みんなの音が集まりました'
                          : clipCount >= 3
                          ? '曲にするか、次の人へ渡そう'
                          : 'あと${3 - clipCount}人で作成OK · 次の人へスマホを渡そう'
                    : collectionHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTokens.mutedInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 22),
            if (state.clips.isEmpty)
              Container(
                padding: EdgeInsets.symmetric(
                  vertical: controller.isRelay ? 38 : 20,
                  horizontal: 22,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                ),
                child: Column(
                  children: [
                    if (controller.isRelay)
                      const Icon(
                        Icons.graphic_eq_rounded,
                        color: AppTokens.coral,
                        size: 42,
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: state.phase == CreationPhase.preparing
                            ? null
                            : controller.startRelay,
                        icon: const Icon(Icons.groups_rounded),
                        label: const Text('みんなで一音ずつ'),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      controller.isRelay
                          ? '最初の人の音から始めよう。'
                          : '会話や長い音も、そのまま録ってみよう。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      controller.isRelay ? '撮ったら次の人へ。' : '同じ場所の音でも大丈夫。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: state.clips.length,
                onReorderItem: controller.reorder,
                itemBuilder: (context, index) => ClipCard(
                  key: ValueKey(state.clips[index].id),
                  clip: state.clips[index],
                  index: index,
                  thumbnail: state.thumbnails[state.clips[index].id],
                  presentation: controller.presentation,
                  selectionStartUs: segments[index].startUs,
                  selectionDurationUs: segments[index].durationUs,
                  onPreview: () =>
                      _previewClip(context, state.clips[index], index),
                  onTrim: (waveform) => showClipTrimSheet(
                    context,
                    clip: state.clips[index],
                    waveform: waveform,
                    selectionStartUs: segments[index].startUs,
                    selectionDurationUs: segments[index].durationUs,
                    onSave: (startUs, durationUs) => controller.setTrim(
                      state.clips[index].id,
                      startUs,
                      durationUs,
                    ),
                    onAudition: (startUs, durationUs) => _previewClipSegment(
                      context,
                      state.clips[index],
                      PlaybackSegment(
                        relativePath: state.clips[index].relativePath,
                        startUs: startUs,
                        durationUs: durationUs,
                      ),
                    ),
                  ),
                  onRename: () =>
                      _renameClip(context, state.clips[index], index),
                  onRemove: () =>
                      _removeClip(context, state.clips[index], index),
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
            if (clipCount >= 6) ...[
              const Text(
                '音は最大6つまで追加できます。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTokens.mutedInk),
              ),
              const SizedBox(height: 8),
            ],
            if (!controller.isRelay || clipCount < 3)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: state.clips.length >= 6 ? null : onCapture,
                      icon: const Icon(Icons.videocam_outlined),
                      label: const Text('今撮る'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.ink,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 148,
                    child: OutlinedButton.icon(
                      onPressed: state.clips.length >= 6 ? null : onPhotos,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('動画を選ぶ'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                ],
              ),
            if (state.clips.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.tune_rounded),
                label: Text(
                  '演出と長さ · ${PerformanceControls.labels[state.performanceMode]!.$1} · ${state.durationSeconds}秒',
                ),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (sheetContext) => SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: AnimatedBuilder(
                        animation: controller,
                        builder: (context, _) => PerformanceControls(
                          mode: controller.state.performanceMode,
                          seconds: controller.state.durationSeconds,
                          onMode: controller.selectPerformance,
                          onDuration: controller.selectDuration,
                        ),
                      ),
                    ),
                  ),
                ),
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
                child: controller.isRelay && clipCount < 6
                    ? Row(
                        children: [
                          IconButton.outlined(
                            onPressed: onPhotos,
                            tooltip: '動画を選ぶ',
                            icon: const Icon(Icons.photo_library_outlined),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            onPressed: onCapture,
                            tooltip: '次の人を撮る',
                            icon: const Icon(Icons.videocam_outlined),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: controller.createPreview,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTokens.ink,
                                foregroundColor: Colors.white,
                              ),
                              child: Text('${state.durationSeconds}秒の曲にする ↗'),
                            ),
                          ),
                        ],
                      )
                    : FilledButton(
                        onPressed: controller.createPreview,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTokens.ink,
                          foregroundColor: Colors.white,
                        ),
                        child: Text('この音で${state.durationSeconds}秒をつくる  ↗'),
                      ),
              ),
            )
          : null,
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

  Future<void> _renameSounds() async {
    final startingRevision = widget.controller.state.project?.revision;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final clips = widget.controller.state.clips;
          return SafeArea(
            child: SizedBox(
              height: (88.0 + clips.length * 62).clamp(
                150.0,
                MediaQuery.sizeOf(context).height * .7,
              ),
              child: ListView(
                children: [
                  const ListTile(title: Text('音の名前をつける')),
                  for (var index = 0; index < clips.length; index++)
                    ListTile(
                      title: Text(_soundName(clips[index], index)),
                      trailing: const Icon(Icons.edit_rounded),
                      onTap: () => _renameSound(clips[index], index),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted &&
        widget.controller.state.project?.revision != startingRevision) {
      widget.controller.refreshNamedPreview();
    }
  }

  String _soundName(ClipAsset clip, int index) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(clip.label)
      ? '録った音 ${index + 1}'
      : clip.label;

  Future<void> _renameSound(ClipAsset clip, int index) async {
    var draft = _soundName(clip, index);
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音の名前'),
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '例：友達のわっ！'),
          onChanged: (value) => draft = value,
          onFieldSubmitted: (_) => Navigator.pop(dialogContext, draft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || chosen == null || chosen.trim().isEmpty) return;
    try {
      await widget.controller.renameClip(clip.id, chosen.trim());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('音の名前を保存できませんでした')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final path = state.preview?.relativePath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('曲をつくる'),
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
            _UsedSounds(
              clips: state.clips,
              thumbnails: state.thumbnails,
              onRename: _renameSounds,
            ),
            const SizedBox(height: 20),
            const _SectionLabel('曲'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final melody in const <MelodyTemplate>[
                  MelodyTemplate.midiScore,
                  MelodyTemplate.hop,
                  MelodyTemplate.wink,
                  MelodyTemplate.answer,
                  MelodyTemplate.odeToJoy,
                  MelodyTemplate.twinkle,
                  MelodyTemplate.furElise,
                  MelodyTemplate.jingleBells,
                  MelodyTemplate.fate,
                  MelodyTemplate.canon,
                  MelodyTemplate.none,
                ])
                  _PillChoice(
                    label: melody.label,
                    tooltip: melody.description,
                    selected: state.melody == melody,
                    onTap: () => widget.controller.selectMelody(melody),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              state.melody.description,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            PerformanceControls(
              mode: state.performanceMode,
              seconds: state.durationSeconds,
              onMode: widget.controller.selectPerformance,
              onDuration: widget.controller.selectDuration,
            ),
            if (state.melody.isMidiScore) ...[
              const SizedBox(height: 8),
              Text(
                'この楽譜を撮った音で。${state.durationSeconds}秒で再生。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
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
                            ? state.phase == CreationPhase.failed
                                  ? const _PreviewFailed()
                                  : BeatBuildingPreview(
                                      clips: state.clips,
                                      thumbnails: state.thumbnails,
                                    )
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
              Column(
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text('${state.durationSeconds}秒のプレビューをつくっています'),
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
              onPressed: _renameSounds,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('音の名前をつける'),
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
            const SizedBox(height: 16),
            if (state.melody != MelodyTemplate.none)
              _SongRoleSummary(state: state),
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
  String? _busyStage;

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
      _busyStage = '高画質の動画を準備しています';
    });
    try {
      final video = await _ensureFullVideo();
      if (mounted) setState(() => _busyStage = '写真に保存しています');
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
      if (mounted) {
        setState(() {
          _busy = false;
          _busyStage = null;
        });
      }
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _busyStage = '高画質の動画を準備しています';
    });
    try {
      final video = await _ensureFullVideo();
      if (mounted) setState(() => _busyStage = '共有画面を開いています');
      await delivery.share(video.relativePath);
    } catch (_) {
      if (mounted) setState(() => _message = '共有できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyStage = null;
        });
      }
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
            _PlaybackControls(
              playback: playback,
              label: '完成した${state.durationSeconds}秒',
            ),
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
                Text(_busyStage ?? '動画を準備しています'),
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

class _PreviewFailed extends StatelessWidget {
  const _PreviewFailed();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF302D36),
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          '音をつなげられませんでした',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
    ),
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
  const _CaptureRoute({
    required this.media,
    required this.presentation,
    required this.fromPhotos,
    required this.recordedClipCount,
    required this.onCommit,
  });
  final MediaGateway media;
  final MediaPresentationGateway presentation;
  final bool fromPhotos;
  final int recordedClipCount;
  final Future<bool> Function(CapturedMedia) onCommit;

  @override
  State<_CaptureRoute> createState() => _CaptureRouteState();
}

class _CaptureRouteState extends State<_CaptureRoute> {
  bool _committed = false;
  bool _saving = false;
  String? _saveError;
  late final CaptureController controller = CaptureController(
    widget.media,
    operationIdFactory: () =>
        'capture-${DateTime.now().microsecondsSinceEpoch}',
  );

  @override
  void initState() {
    super.initState();
    controller.addListener(_clearStaleSaveError);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startWhenSettled());
  }

  // Starting the camera session mid-transition stalls the UI thread and makes
  // the shutter's flight stutter, so wait until the route has fully arrived.
  void _startWhenSettled() {
    if (!mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _start();
      return;
    }
    void onStatus(AnimationStatus status) {
      if (!status.isCompleted) return;
      animation.removeStatusListener(onStatus);
      if (mounted) _start();
    }

    animation.addStatusListener(onStatus);
  }

  void _start() {
    if (widget.fromPhotos) {
      unawaited(controller.importVideo());
    } else {
      unawaited(controller.prepare());
    }
  }

  @override
  void dispose() {
    controller.removeListener(_clearStaleSaveError);
    final unselected = controller.state.capturedMedia;
    if (!_committed && unselected != null) {
      unawaited(_discardUnselected(unselected.relativePath));
    }
    unawaited(controller.releaseCapture());
    controller.dispose();
    super.dispose();
  }

  void _clearStaleSaveError() {
    if (_saveError != null &&
        controller.state.phase != CapturePhase.completed &&
        mounted) {
      setState(() => _saveError = null);
    }
  }

  Future<void> _discardUnselected(String path) async {
    try {
      await widget.media.discardStaged(path);
    } catch (_) {
      // Leaving this screen should still succeed if staging cleanup fails.
    }
  }

  Future<void> _commit() async {
    final captured = controller.state.capturedMedia;
    if (_saving || captured == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    bool saved;
    try {
      saved = await widget.onCommit(captured);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _saving = false;
        _saveError = '追加できませんでした。もう一度試すか、撮り直してください。';
      });
      return;
    }
    _committed = true;
    setState(() => _saving = false);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: CaptureScreen(
      controller: controller,
      presentation: widget.presentation,
      isAdding: _saving,
      addError: _saveError,
      recordedClipCount: widget.recordedClipCount,
      onMediaReady: () => unawaited(_commit()),
    ),
  );
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.5,
      color: AppTokens.mutedInk,
    ),
  );
}

/// A rounded choice: dark when chosen, pale grey otherwise.
final class _PillChoice extends StatelessWidget {
  const _PillChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    hint: tooltip,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTokens.ink : AppTokens.tile,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: selected ? Colors.white : AppTokens.ink,
          ),
        ),
      ),
    ),
  );
}

/// The sounds this song is made of, as a row of small photos.
final class _UsedSounds extends StatelessWidget {
  const _UsedSounds({
    required this.clips,
    required this.thumbnails,
    required this.onRename,
  });

  final List<ClipAsset> clips;
  final Map<String, Uint8List> thumbnails;
  final VoidCallback onRename;

  static String _name(ClipAsset clip, int index) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(clip.label)
      ? '音${index + 1}'
      : clip.label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTokens.tile,
      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '使う音',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              '${clips.length}つ',
              style: const TextStyle(fontSize: 11, color: AppTokens.mutedInk),
            ),
          ],
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: onRename,
          child: Row(
            children: [
              for (var i = 0; i < 6; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: i < clips.length
                        ? Column(
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Positioned.fill(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(14),
                                        child: thumbnails[clips[i].id] != null
                                            ? Image.memory(
                                                thumbnails[clips[i].id]!,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (context, error, stack) =>
                                                        ColoredBox(
                                                          color: AppTokens
                                                              .soundColor(i),
                                                        ),
                                              )
                                            : ColoredBox(
                                                color: AppTokens.soundColor(i),
                                              ),
                                      ),
                                    ),
                                    Positioned(
                                      left: -3,
                                      top: -3,
                                      child: Container(
                                        width: 16,
                                        height: 16,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: AppTokens.soundColor(i),
                                          borderRadius: BorderRadius.circular(5),
                                        ),
                                        child: Text(
                                          '${i + 1}',
                                          style: const TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _name(clips[i], i),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
