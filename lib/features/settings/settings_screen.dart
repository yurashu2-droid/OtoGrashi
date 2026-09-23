import 'package:flutter/material.dart';

import '../../storage/project_repository.dart';

final class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.usageLoader,
    required this.clearCache,
    super.key,
  });

  final Future<StorageUsage> Function() usageLoader;
  final Future<void> Function() clearCache;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

final class _SettingsScreenState extends State<SettingsScreen> {
  late Future<StorageUsage> _usage = widget.usageLoader();
  var _haptics = true;
  var _decorations = true;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('設定'), centerTitle: true),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        SwitchListTile(
          title: const Text('触覚フィードバック'),
          value: _haptics,
          onChanged: (value) => setState(() => _haptics = value),
        ),
        SwitchListTile(
          title: const Text('道具の装飾'),
          subtitle: const Text('控えめにすると動画と文字を広く見せます'),
          value: _decorations,
          onChanged: (value) => setState(() => _decorations = value),
        ),
        const SizedBox(height: 18),
        Text('容量', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        FutureBuilder<StorageUsage>(
          future: _usage,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              );
            }
            final usage = snapshot.data!;
            return Card(
              child: Column(
                children: [
                  _UsageRow(
                    label: '原本',
                    value: usage.originalsBytes,
                    icon: Icons.video_library_outlined,
                  ),
                  _UsageRow(
                    label: '完成した作品',
                    value: usage.completedBytes,
                    icon: Icons.movie_outlined,
                  ),
                  _UsageRow(
                    label: '再生成できるキャッシュ',
                    value: usage.cacheBytes,
                    icon: Icons.cached,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                    child: OutlinedButton(
                      onPressed: usage.cacheBytes == 0 ? null : _clearCache,
                      child: const Text('キャッシュを整理'),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 18),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('オトグラシについて'),
          subtitle: Text('撮った音と動画はこの端末の中で編集します。'),
        ),
      ],
    ),
  );

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('キャッシュを整理しますか？'),
        content: const Text('原本と完成した作品はそのまま残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('整理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.clearCache();
    if (!mounted) return;
    setState(() => _usage = widget.usageLoader());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('キャッシュを整理しました')),
    );
  }
}

final class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.label, required this.value, required this.icon});

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    trailing: Text(_formatBytes(value)),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
