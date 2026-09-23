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
          for (final project in _projects)
            _ProjectCard(
              project: project,
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
            index: index,
            projects: widget.assets.referencingProjectIds(asset.id),
            onRename: () => _renameAsset(context, asset, index),
            onTap: widget.onAssetSelected == null
                ? null
                : () => widget.onAssetSelected!(asset),
          );
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

final class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.completed,
    required this.presentation,
    required this.onView,
    required this.onOpen,
    required this.onDelete,
  });

  final Project project;
  final List<CompletedExport> completed;
  final MediaPresentationGateway? presentation;
  final VoidCallback? onView;
  final VoidCallback? onOpen;
  final VoidCallback onDelete;

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
                  project.title.isEmpty ? '無題の作品' : project.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '作品の操作',
                onSelected: (value) {
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('削除')),
                ],
              ),
            ],
          ),
          if (completed.isNotEmpty && presentation != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 174,
                child: FutureBuilder<Uint8List>(
                  future: presentation!.thumbnail(completed.first.relativePath),
                  builder: (context, snapshot) => snapshot.hasData
                      ? Image.memory(
                          snapshot.data!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                        )
                      : const ColoredBox(
                          color: AppTokens.paper,
                          child: Center(
                            child: Icon(Icons.movie_outlined, size: 38),
                          ),
                        ),
                ),
              ),
            ),
          ],
          Text('${project.clipIds.length}素材・編集 ${project.revision}回目'),
          if (completed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('完成版 ${completed.length}件を保存中'),
            ),
          const SizedBox(height: 10),
          if (completed.isNotEmpty && onView != null) ...[
            FilledButton.icon(
              onPressed: onView,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('完成動画を見る'),
            ),
            const SizedBox(height: 8),
          ],
          OutlinedButton.icon(
            onPressed: onOpen,
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
    required this.index,
    required this.projects,
    required this.onTap,
    required this.onRename,
  });

  final ClipAsset asset;
  final int index;
  final Future<List<String>> projects;
  final VoidCallback? onTap;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      onTap: onTap,
      leading: const CircleAvatar(child: Icon(Icons.graphic_eq)),
      title: Text(_soundName(asset, index)),
      subtitle: FutureBuilder<List<String>>(
        future: projects,
        builder: (context, snapshot) => Text(
          '${(asset.selectionDurationUs / 1000000).toStringAsFixed(1)}秒・'
          '${snapshot.data?.length ?? 0}作品で使用中',
        ),
      ),
      trailing: IconButton(
        onPressed: onRename,
        tooltip: '音の名前を変更',
        icon: const Icon(Icons.edit_outlined),
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
