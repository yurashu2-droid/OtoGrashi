import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../domain/project.dart';
import '../../media/media_delivery_gateway.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import '../../storage/project_repository.dart';
import '../export/completed_video_screen.dart';
import '../export/media_playback.dart';

typedef ProjectSelected = Future<void> Function(Project project);

final class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.projects,
    required this.assets,
    required this.onCreate,
    this.presentation,
    this.delivery,
    this.onProjectSelected,
    this.onAssetSelected,
    this.initialTabIndex = 0,
    this.onSettings,
    super.key,
  });

  final ProjectRepository projects;
  final AssetRepository assets;
  final VoidCallback onCreate;
  final MediaPresentationGateway? presentation;
  final MediaDeliveryGateway? delivery;
  final ProjectSelected? onProjectSelected;
  final ValueChanged<ClipAsset>? onAssetSelected;
  final int initialTabIndex;
  final VoidCallback? onSettings;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.initialTabIndex.clamp(0, 1),
  );
  var _loading = true;
  List<Project> _projects = const <Project>[];
  List<ClipAsset> _assets = const <ClipAsset>[];
  List<CompletedExport> _exports = const <CompletedExport>[];
  int _reloadGeneration = 0;
  var _smallAssetCards = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final projects = await widget.projects.list();
      final assets = await widget.assets.list();
      final exports = widget.projects is SqliteProjectRepository
          ? await (widget.projects as SqliteProjectRepository)
                .listCompletedExports()
          : const <CompletedExport>[];
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _assets = assets;
        _exports = exports;
        _reloadGeneration++;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('音の記録'),
      centerTitle: true,
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: 'つくった曲'),
          Tab(text: '音のストック'),
        ],
      ),
      actions: [
        if (widget.onSettings != null)
          IconButton(
            onPressed: widget.onSettings,
            tooltip: '設定',
            icon: const Icon(Icons.settings_outlined),
          ),
        IconButton(
          onPressed: _reload,
          tooltip: '更新',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? _ErrorState(onRetry: _reload)
        : TabBarView(
            controller: _tabs,
            children: [_buildProjects(context), _buildAssets(context)],
          ),
  );

  Widget _buildProjects(BuildContext context) {
    if (_projects.isEmpty) {
      return _EmptyState(
        message: 'まだ作品がありません',
        description: '集めた音から、はじめての曲をつくろう。',
        icon: Icons.movie_creation_outlined,
        actionLabel: '撮影・取り込みへ',
        onPressed: widget.onCreate,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          _SectionIntro(
            title: 'つくった曲',
            count: _projects.length,
            description: '完成した動画も、制作中の曲もここに。',
          ),
          const SizedBox(height: 12),
          for (final project in _projects)
            _ProjectCard(
              project: project,
              draftPath: _assets
                  .where((asset) => project.clipIds.contains(asset.id))
                  .firstOrNull
                  ?.relativePath,
              completed: _exports
                  .where((item) => item.projectId == project.id)
                  .toList(growable: false),
              presentation: widget.presentation,
              onView: widget.presentation == null || widget.delivery == null
                  ? null
                  : () {
                      final exports = _exports
                          .where((item) => item.projectId == project.id)
                          .toList(growable: false);
                      if (exports.isEmpty) return;
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CompletedVideoScreen(
                            project: project,
                            export: exports.first,
                            versions: exports,
                            presentation: widget.presentation!,
                            delivery: widget.delivery!,
                          ),
                        ),
                      );
                    },
              onOpen: widget.onProjectSelected == null
                  ? null
                  : () => widget.onProjectSelected!(project),
              onDelete: () => _deleteProject(context, project),
            ),
        ],
      ),
    );
  }

  Widget _buildAssets(BuildContext context) {
    if (_assets.isEmpty) {
      return _EmptyState(
        message: '素材はまだありません',
        description: '気になった音を撮って、ここに集めよう。',
        icon: Icons.graphic_eq_rounded,
        actionLabel: '撮影・取り込みへ',
        onPressed: widget.onCreate,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Column(
                children: [
                  _SectionIntro(
                    title: '音のストック',
                    count: _assets.length,
                    description: '聴き直して、名前をつけて、次の曲にも。',
                  ),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '表示サイズ',
                          style: TextStyle(
                            color: AppTokens.mutedInk,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _StockViewSelector(
                        small: _smallAssetCards,
                        onChanged: (small) =>
                            setState(() => _smallAssetCards = small),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_smallAssetCards)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 9 / 16,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) =>
                      _buildAssetCard(context, index, compact: true),
                  childCount: _assets.length,
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildAssetCard(context, index),
                  childCount: _assets.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAssetCard(
    BuildContext context,
    int index, {
    bool compact = false,
  }) {
    final asset = _assets[index];
    return _AssetCard(
      key: ValueKey(asset.id),
      asset: asset,
      index: index,
      compact: compact,
      presentation: widget.presentation,
      loadReferences: () => widget.assets.referencingProjectIds(asset.id),
      reloadGeneration: _reloadGeneration,
      onRename: () => _renameAsset(context, asset, index),
      onPreview: widget.presentation == null
          ? null
          : () => _previewAsset(context, asset, index),
      onReuse: widget.onAssetSelected == null
          ? null
          : () => widget.onAssetSelected!(asset),
    );
  }

  void _previewAsset(BuildContext context, ClipAsset asset, int index) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTokens.surfaceColor,
      showDragHandle: true,
      builder: (sheetContext) => _AssetPreviewSheet(
        asset: asset,
        title: _soundName(asset, index),
        presentation: widget.presentation!,
        onRename: () {
          Navigator.of(sheetContext).pop();
          _renameAsset(context, asset, index);
        },
        onReuse: widget.onAssetSelected == null
            ? null
            : () {
                Navigator.of(sheetContext).pop();
                widget.onAssetSelected!(asset);
              },
      ),
    );
  }

  Future<void> _renameAsset(
    BuildContext context,
    ClipAsset asset,
    int index,
  ) async {
    var name = _soundName(asset, index);
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音に名前をつける'),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          maxLength: 40,
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
      await widget.assets.rename(asset.id, chosen);
      await _reload();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('名前を保存できませんでした')));
      }
    }
  }

  Future<void> _deleteProject(BuildContext context, Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('作品を削除しますか？'),
        content: const Text('使っている素材と完成版は残ります。あとから取り消せます。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.projects.deleteProject(project.id);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('作品を削除しました'),
        action: widget.projects is SqliteProjectRepository
            ? SnackBarAction(
                label: '取り消す',
                onPressed: () async {
                  await (widget.projects as SqliteProjectRepository)
                      .restoreProject(project.id);
                  await _reload();
                },
              )
            : null,
      ),
    );
    await _reload();
  }
}

final class _SectionIntro extends StatelessWidget {
  const _SectionIntro({
    required this.title,
    required this.count,
    required this.description,
  });

  final String title;
  final int count;
  final String description;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '$count',
              style: const TextStyle(
                color: AppTokens.coral,
                fontWeight: FontWeight.w900,
                fontSize: 24,
              ),
            ),
          ],
        ),
        const SizedBox(
          width: 74,
          height: 7,
          child: CustomPaint(painter: _PencilUnderline()),
        ),
        const SizedBox(height: 1),
        Text(description, style: const TextStyle(color: AppTokens.mutedInk)),
      ],
    ),
  );
}

final class _PencilUnderline extends CustomPainter {
  const _PencilUnderline();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Path()
      ..moveTo(2, 4)
      ..quadraticBezierTo(18, 1, 34, 3)
      ..quadraticBezierTo(53, 4, size.width - 2, 2);
    canvas.drawPath(
      line,
      Paint()
        ..color = AppTokens.coral.withValues(alpha: .72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PencilUnderline oldDelegate) => false;
}

final class _StockViewSelector extends StatelessWidget {
  const _StockViewSelector({required this.small, required this.onChanged});

  final bool small;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: const Color(0xFFFFFEFB),
      border: Border.all(color: const Color(0xFFE7DCD2)),
      borderRadius: BorderRadius.circular(10),
    ),
    clipBehavior: Clip.antiAlias,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StockViewOption(
          label: '大',
          tooltip: '大きく表示',
          icon: Icons.view_agenda_outlined,
          selected: !small,
          onTap: () => onChanged(false),
        ),
        const SizedBox(
          height: 28,
          child: VerticalDivider(width: 1, color: Color(0xFFE7DCD2)),
        ),
        _StockViewOption(
          label: '小',
          tooltip: '小さく表示',
          icon: Icons.grid_view_rounded,
          selected: small,
          onTap: () => onChanged(true),
        ),
      ],
    ),
  );
}

final class _StockViewOption extends StatelessWidget {
  const _StockViewOption({
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: tooltip,
    child: Tooltip(
      message: tooltip,
      child: Material(
        color: selected
            ? AppTokens.coral.withValues(alpha: .15)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 66,
            height: 48,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 17, color: AppTokens.ink),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: AppTokens.ink,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

final class _ProjectCard extends StatefulWidget {
  const _ProjectCard({
    required this.project,
    required this.draftPath,
    required this.completed,
    required this.presentation,
    required this.onView,
    required this.onOpen,
    required this.onDelete,
  });

  final Project project;
  final String? draftPath;
  final List<CompletedExport> completed;
  final MediaPresentationGateway? presentation;
  final VoidCallback? onView;
  final VoidCallback? onOpen;
  final VoidCallback onDelete;

  @override
  State<_ProjectCard> createState() => _ProjectCardState();
}

class _ProjectCardState extends State<_ProjectCard> {
  Future<Uint8List>? _thumbnail;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _ProjectCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.completed.firstOrNull?.relativePath !=
            widget.completed.firstOrNull?.relativePath ||
        oldWidget.draftPath != widget.draftPath ||
        oldWidget.presentation != widget.presentation) {
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    final path = widget.completed.firstOrNull?.relativePath ?? widget.draftPath;
    _thumbnail = path == null || widget.presentation == null
        ? null
        : widget.presentation!.thumbnail(path);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    final finished = widget.completed.isNotEmpty;
    final editedAt = project.updatedAt.toLocal();
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: const Color(0xFFFFFEFB),
      elevation: 2,
      shadowColor: const Color(0x228D6B5B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: const BorderSide(color: Color(0xFFE7DCD2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 192,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FutureBuilder<Uint8List>(
                  future: _thumbnail,
                  builder: (context, snapshot) => snapshot.hasData
                      ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                      : const _ProjectArtwork(),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x99000000)],
                    ),
                  ),
                ),
                Positioned(
                  top: -2,
                  right: 25,
                  child: Transform.rotate(
                    angle: -.10,
                    child: const SizedBox(
                      width: 58,
                      height: 17,
                      child: ColoredBox(color: Color(0xCFFFEBC6)),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  top: 14,
                  child: _StatusPill(
                    text: finished ? '完成' : '制作中',
                    color: finished ? AppTokens.coral : AppTokens.lavender,
                  ),
                ),
                if (finished && widget.onView != null)
                  Positioned.fill(
                    child: Semantics(
                      button: true,
                      label: '完成動画を見る',
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: widget.onView,
                          child: Center(
                            child: Container(
                              width: 58,
                              height: 58,
                              decoration: const BoxDecoration(
                                color: Color(0xEFFFFFFF),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                size: 32,
                                color: AppTokens.ink,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 15,
                  right: 15,
                  bottom: 13,
                  child: Text(
                    '${editedAt.month}月${editedAt.day}日 · ${project.clipIds.length}つの音',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(color: Colors.black45, blurRadius: 3)],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 10, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        project.title.isEmpty ? '無題の作品' : project.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '作品の操作',
                      onSelected: (value) {
                        if (value == 'delete') widget.onDelete();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'delete', child: Text('削除')),
                      ],
                    ),
                  ],
                ),
                if (finished)
                  Text(
                    '完成版 ${widget.completed.length}本を保存中',
                    style: const TextStyle(color: AppTokens.mutedInk),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (finished && widget.onView != null) ...[
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.onView,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('動画を見る'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTokens.coral,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: widget.onOpen,
                        icon: Icon(
                          finished ? Icons.tune_rounded : Icons.edit_outlined,
                        ),
                        label: Text(finished ? '再編集' : '続きをつくる'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ProjectArtwork extends StatelessWidget {
  const _ProjectArtwork();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(colors: [Color(0xFFD7C5EA), Color(0xFF9B78C8)]),
    ),
    child: Center(
      child: Transform.rotate(
        angle: -0.09,
        child: const Icon(
          Icons.graphic_eq_rounded,
          size: 116,
          color: Color(0xAAFFFFFF),
        ),
      ),
    ),
  );
}

final class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTokens.ink,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    ),
  );
}

final class _AssetCard extends StatefulWidget {
  const _AssetCard({
    required this.asset,
    required this.index,
    this.compact = false,
    required this.presentation,
    required this.loadReferences,
    required this.reloadGeneration,
    required this.onPreview,
    required this.onReuse,
    required this.onRename,
    super.key,
  });

  final ClipAsset asset;
  final int index;
  final bool compact;
  final MediaPresentationGateway? presentation;
  final Future<List<String>> Function() loadReferences;
  final int reloadGeneration;
  final VoidCallback? onPreview;
  final VoidCallback? onReuse;
  final VoidCallback onRename;

  @override
  State<_AssetCard> createState() => _AssetCardState();
}

class _AssetCardState extends State<_AssetCard> {
  Future<Uint8List>? _thumbnail;
  Future<AudioWaveform>? _waveform;
  late Future<List<String>> _projects = widget.loadReferences();

  @override
  void initState() {
    super.initState();
    _loadMedia();
  }

  @override
  void didUpdateWidget(covariant _AssetCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.relativePath != widget.asset.relativePath ||
        oldWidget.presentation != widget.presentation) {
      _loadMedia();
    }
    if (oldWidget.asset.id != widget.asset.id ||
        oldWidget.reloadGeneration != widget.reloadGeneration) {
      _projects = widget.loadReferences();
    }
  }

  void _loadMedia() {
    final gateway = widget.presentation;
    _thumbnail = gateway?.thumbnail(widget.asset.relativePath);
    _waveform = gateway?.waveform(widget.asset.relativePath);
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final accent = switch (widget.index % 3) {
      0 => AppTokens.coral,
      1 => const Color(0xFF9B78C8),
      _ => const Color(0xFFE9A347),
    };
    final name = _soundName(asset, widget.index);
    if (widget.compact) {
      return _buildCompactCard(context, asset, accent, name);
    }
    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: const Color(0xFFFFFEFB),
      elevation: 2,
      shadowColor: const Color(0x228D6B5B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE7DCD2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height:
            166 +
            (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(0, 30),
        child: Row(
          children: [
            SizedBox(
              width: 112,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<Uint8List>(
                    future: _thumbnail,
                    builder: (context, snapshot) => snapshot.hasData
                        ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                        : DecoratedBox(
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: .5),
                            ),
                            child: const Icon(
                              Icons.graphic_eq_rounded,
                              color: Colors.white,
                              size: 48,
                            ),
                          ),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _StatusPill(
                      text: '${widget.index + 1}',
                      color: accent,
                    ),
                  ),
                  Positioned(
                    bottom: 7,
                    left: 7,
                    right: 7,
                    child: TextButton.icon(
                      onPressed: widget.onPreview,
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: const Text('聴く'),
                      style: TextButton.styleFrom(
                        backgroundColor: const Color(0xEFFFFFFF),
                        foregroundColor: AppTokens.ink,
                        minimumSize: const Size(0, 44),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 7, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: widget.onRename,
                          tooltip: '音の名前を変更',
                          icon: const Icon(Icons.edit_outlined, size: 19),
                        ),
                      ],
                    ),
                    FutureBuilder<List<String>>(
                      future: _projects,
                      builder: (context, snapshot) => Text(
                        '${(asset.selectionDurationUs / 1000000).toStringAsFixed(1)}秒 · ${snapshot.data?.length ?? 0}作品で使用',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTokens.mutedInk,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF8F1),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: FutureBuilder<AudioWaveform>(
                          future: _waveform,
                          builder: (context, snapshot) => snapshot.hasData
                              ? CustomPaint(
                                  painter: _StockWaveformPainter(
                                    waveform: snapshot.data!,
                                    color: accent,
                                    selectionStartUs: asset.selectionStartUs,
                                    selectionDurationUs:
                                        asset.selectionDurationUs,
                                  ),
                                  child: const SizedBox.expand(),
                                )
                              : Center(
                                  child: Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 19,
                                    color: accent,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: widget.onReuse,
                        icon: const Icon(
                          Icons.add_circle_outline_rounded,
                          size: 18,
                        ),
                        label: const Text('曲に使う'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          foregroundColor: AppTokens.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactCard(
    BuildContext context,
    ClipAsset asset,
    Color accent,
    String name,
  ) => Card(
    margin: EdgeInsets.zero,
    color: const Color(0xFFFFFEFB),
    elevation: 2,
    shadowColor: const Color(0x228D6B5B),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Color(0xFFE7DCD2)),
    ),
    clipBehavior: Clip.antiAlias,
    child: AspectRatio(
      aspectRatio: 9 / 16,
      child: InkWell(
        onTap: widget.onPreview,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List>(
              future: _thumbnail,
              builder: (context, snapshot) => snapshot.hasData
                  ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent.withValues(alpha: .65),
                            AppTokens.ink,
                          ],
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.graphic_eq_rounded,
                          color: Colors.white,
                          size: 36,
                        ),
                      ),
                    ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, .44, 1],
                  colors: [
                    Color(0x26000000),
                    Colors.transparent,
                    Color(0xD9000000),
                  ],
                ),
              ),
            ),
            FutureBuilder<AudioWaveform>(
              future: _waveform,
              builder: (context, snapshot) => snapshot.hasData
                  ? CustomPaint(
                      key: ValueKey('stock-grid-waveform-${asset.id}'),
                      painter: _StockThumbnailWaveformPainter(
                        waveform: snapshot.data!,
                        selectionStartUs: asset.selectionStartUs,
                        selectionDurationUs: asset.selectionDurationUs,
                      ),
                      child: const SizedBox.expand(),
                    )
                  : const Center(
                      child: Icon(
                        Icons.graphic_eq_rounded,
                        color: Color(0xBBFFFFFF),
                        size: 30,
                      ),
                    ),
            ),
            Positioned(
              top: 7,
              left: 7,
              child: _StatusPill(text: '${widget.index + 1}', color: accent),
            ),
            if (widget.onPreview != null)
              Positioned(
                top: 7,
                right: 7,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 17,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

final class _StockWaveformPainter extends CustomPainter {
  const _StockWaveformPainter({
    required this.waveform,
    required this.color,
    required this.selectionStartUs,
    required this.selectionDurationUs,
  });
  final AudioWaveform waveform;
  final Color color;
  final int selectionStartUs;
  final int selectionDurationUs;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final levels = waveform.levels;
    final count = size.width.floor().clamp(1, 48);
    final step = size.width / count;
    for (var i = 0; i < count; i++) {
      final start = i * levels.length ~/ count;
      final end = ((i + 1) * levels.length ~/ count).clamp(
        start + 1,
        levels.length,
      );
      var level = 0.0;
      for (var j = start; j < end; j++) {
        if (levels[j] > level) level = levels[j];
      }
      final height = 3 + level * (size.height - 9);
      final timeUs = (i + .5) * waveform.durationUs / count;
      final selected =
          timeUs >= selectionStartUs &&
          timeUs <= selectionStartUs + selectionDurationUs;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset((i + .5) * step, size.height / 2),
            width: (step * .65).clamp(1, 3),
            height: height,
          ),
          const Radius.circular(2),
        ),
        Paint()
          ..color = selected
              ? color
              : AppTokens.mutedInk.withValues(alpha: .32),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StockWaveformPainter oldDelegate) =>
      oldDelegate.waveform != waveform ||
      oldDelegate.color != color ||
      oldDelegate.selectionStartUs != selectionStartUs ||
      oldDelegate.selectionDurationUs != selectionDurationUs;
}

final class _StockThumbnailWaveformPainter extends CustomPainter {
  const _StockThumbnailWaveformPainter({
    required this.waveform,
    required this.selectionStartUs,
    required this.selectionDurationUs,
  });

  final AudioWaveform waveform;
  final int selectionStartUs;
  final int selectionDurationUs;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || waveform.levels.isEmpty) return;
    final levels = waveform.levels;
    final count = size.width.floor().clamp(24, 48);
    final step = size.width / count;
    final centerY = size.height * .53;
    for (var i = 0; i < count; i++) {
      final start = i * levels.length ~/ count;
      final end = ((i + 1) * levels.length ~/ count).clamp(
        start + 1,
        levels.length,
      );
      var level = 0.0;
      for (var j = start; j < end; j++) {
        if (levels[j] > level) level = levels[j];
      }
      final height = 3 + level * 23;
      final timeUs = (i + .5) * waveform.durationUs / count;
      final selected =
          timeUs >= selectionStartUs &&
          timeUs <= selectionStartUs + selectionDurationUs;
      final rect = Rect.fromCenter(
        center: Offset((i + .5) * step, centerY),
        width: (step * .58).clamp(1.1, 2.2),
        height: height,
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
      canvas.drawRRect(
        rrect.shift(const Offset(0, 1)),
        Paint()..color = const Color(0x99000000),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = selected
              ? AppTokens.coral
              : Colors.white.withValues(alpha: .42),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StockThumbnailWaveformPainter oldDelegate) =>
      oldDelegate.waveform != waveform ||
      oldDelegate.selectionStartUs != selectionStartUs ||
      oldDelegate.selectionDurationUs != selectionDurationUs;
}

final class _AssetPreviewSheet extends StatefulWidget {
  const _AssetPreviewSheet({
    required this.asset,
    required this.title,
    required this.presentation,
    required this.onRename,
    required this.onReuse,
  });
  final ClipAsset asset;
  final String title;
  final MediaPresentationGateway presentation;
  final VoidCallback onRename;
  final VoidCallback? onReuse;

  @override
  State<_AssetPreviewSheet> createState() => _AssetPreviewSheetState();
}

class _AssetPreviewSheetState extends State<_AssetPreviewSheet> {
  late final playback = MediaPlaybackController(widget.presentation);

  @override
  void dispose() {
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: .8,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
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
            const Text('ストックした元の動画と音'),
            const SizedBox(height: 12),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: NativeMovieView(
                      relativePath: widget.asset.relativePath,
                      segments: [
                        PlaybackSegment(
                          relativePath: widget.asset.relativePath,
                          startUs: widget.asset.selectionStartUs,
                          durationUs: widget.asset.selectionDurationUs,
                        ),
                      ],
                      gateway: widget.presentation,
                      controller: playback,
                      fallback: const ColoredBox(color: AppTokens.ink),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            AnimatedBuilder(
              animation: playback,
              builder: (context, _) => Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: playback.toggle,
                    tooltip: playback.isPlaying ? '一時停止' : '再生',
                    icon: Icon(
                      playback.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${(widget.asset.selectionDurationUs / 1000000).toStringAsFixed(1)}秒の音',
                  ),
                  const Spacer(),
                  if (playback.error != null) const Text('再生できませんでした'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.onRename,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('名前を変更'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                    ),
                  ),
                ),
                if (widget.onReuse != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: widget.onReuse,
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 18,
                      ),
                      label: const Text('曲に使う'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.coral,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

String _soundName(ClipAsset asset, int index) {
  final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
      .hasMatch(asset.label);
  return generatedName || asset.label.isEmpty
      ? '録った音 ${index + 1}'
      : asset.label;
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    required this.description,
    required this.icon,
    required this.actionLabel,
    required this.onPressed,
  });

  final String message;
  final String description;
  final IconData icon;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 106,
            height: 106,
            decoration: const BoxDecoration(
              color: AppTokens.paper,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 52, color: AppTokens.coral),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 5),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTokens.mutedInk),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: onPressed, child: Text(actionLabel)),
        ],
      ),
    ),
  );
}

final class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('読み込めませんでした'),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: onRetry, child: const Text('もう一度')),
      ],
    ),
  );
}
