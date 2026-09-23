import 'package:flutter/material.dart';

import '../../domain/clip_asset.dart';
import '../../domain/project.dart';
import '../../storage/asset_repository.dart';
import '../../storage/project_repository.dart';

typedef ProjectSelected = Future<void> Function(Project project);

final class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    required this.projects,
    required this.assets,
    required this.onCreate,
    this.onProjectSelected,
    this.onAssetSelected,
    this.initialTabIndex = 0,
    this.onSettings,
    super.key,
  });

  final ProjectRepository projects;
  final AssetRepository assets;
  final VoidCallback onCreate;
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
      title: const Text('作品と素材'),
      centerTitle: true,
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(text: '作品'),
          Tab(text: '音の引き出し'),
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
        actionLabel: '撮影・取り込みへ',
        onPressed: widget.onCreate,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          for (final project in _projects) _ProjectCard(
            project: project,
            completed: _exports
                .where((item) => item.projectId == project.id)
                .toList(growable: false),
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
        actionLabel: '撮影・取り込みへ',
        onPressed: widget.onCreate,
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        itemCount: _assets.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final asset = _assets[index];
          return _AssetCard(
            asset: asset,
            projects: widget.assets.referencingProjectIds(asset.id),
            onTap: widget.onAssetSelected == null
                ? null
                : () => widget.onAssetSelected!(asset),
          );
        },
      ),
    );
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

final class _ProjectCard extends StatefulWidget {
  const _ProjectCard({
    required this.project,
    required this.completed,
    required this.onOpen,
    required this.onDelete,
  });

  final Project project;
  final List<CompletedExport> completed;
  final VoidCallback? onOpen;
  final VoidCallback onDelete;

  @override
  State<_ProjectCard> createState() => _ProjectCardState();
}

final class _ProjectCardState extends State<_ProjectCard> {
  var _playing = false;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.project.title.isEmpty ? '無題の作品' : widget.project.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _playing = !_playing),
                icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                label: Text(_playing ? '停止' : '再生'),
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
          Text('${widget.project.clipIds.length}素材・編集 ${widget.project.revision}回目'),
          if (widget.completed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('完成版 ${widget.completed.length}件を保存中'),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: widget.onOpen,
            icon: const Icon(Icons.tune),
            label: const Text('再編集'),
          ),
        ],
      ),
    ),
  );
}

final class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.asset,
    required this.projects,
    required this.onTap,
  });

  final ClipAsset asset;
  final Future<List<String>> projects;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onTap,
      leading: const CircleAvatar(child: Icon(Icons.graphic_eq)),
      title: Text(asset.label.isEmpty ? '名前のない素材' : asset.label),
      subtitle: FutureBuilder<List<String>>(
        future: projects,
        builder: (context, snapshot) => Text(
          '${(asset.selectionDurationUs / 1000000).toStringAsFixed(1)}秒・'
          '${snapshot.data?.length ?? 0}作品で使用中',
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
    ),
  );
}

final class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inventory_2_outlined, size: 52),
          const SizedBox(height: 14),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
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
