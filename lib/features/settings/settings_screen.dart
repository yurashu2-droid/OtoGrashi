import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../media/depth_model.dart';
import '../../storage/profile_store.dart';
import '../../storage/project_repository.dart';

final class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    required this.usageLoader,
    required this.clearCache,
    this.ownerName,
    this.onOwnerName,
    super.key,
  });

  final Future<StorageUsage> Function() usageLoader;
  final Future<void> Function() clearCache;

  /// The creator's name, shown on the cover of every video.
  final String? ownerName;

  /// Saves a new name and returns it as stored. Without it the name is not
  /// offered for editing.
  final Future<String?> Function(String name)? onOwnerName;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

final class _SettingsScreenState extends State<SettingsScreen> {
  final _depthModel = DepthModel.instance;
  late Future<StorageUsage> _usage = widget.usageLoader();
  late String? _name = widget.ownerName;

  @override
  void initState() {
    super.initState();
    if (_depthModel.value.phase == DepthModelPhase.unknown) {
      _depthModel.refresh();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('設定'), centerTitle: true),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        if (widget.onOwnerName != null) ...[
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: const Text('あなたの名前'),
              subtitle: Text(
                _name == null
                    ? 'まだ決めていません（動画には「わたしの日常」と出ます）'
                    : '動画の最初に「$_nameの日常」と出ます',
              ),
              trailing: const Icon(Icons.edit_rounded, size: 20),
              onTap: _editName,
            ),
          ),
          const SizedBox(height: 18),
        ],
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
        // the とびだす data can be taken off the phone again once it is there
        ValueListenableBuilder<DepthModelState>(
          valueListenable: _depthModel,
          builder: (context, state, _) {
            if (state.phase != DepthModelPhase.ready) {
              return const SizedBox.shrink();
            }
            return Card(
              child: ListTile(
                leading: const Icon(Icons.view_in_ar_rounded),
                title: const Text('「とびだす」のデータ'),
                subtitle: const Text(
                  '約${DepthModel.megabytes}MB · 削除しても、あとでまた追加できます',
                ),
                trailing: TextButton(
                  onPressed: _deleteDepthModel,
                  child: const Text('削除'),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 18),
        const ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('オトグラシについて'),
          subtitle: Text('曲づくりと編集は端末の中で行います。共有フォルダに追加した素材は、参加した友だちと共有されます。'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('ライセンス'),
          subtitle: const Text('このアプリで使っているソフトウェアとデータ'),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: AppTokens.mutedInk,
          ),
          onTap: _showLicenses,
        ),
      ],
    ),
  );

  Future<void> _editName() async {
    final save = widget.onOwnerName;
    if (save == null) return;
    var draft = _name ?? '';
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('あなたの名前'),
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          maxLength: ProfileStore.maxNameLength,
          decoration: const InputDecoration(
            hintText: '例：ゆい',
            helperText: '空欄にすると「わたし」になります',
          ),
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
    if (chosen == null) return;
    try {
      final saved = await save(chosen);
      if (mounted) setState(() => _name = saved);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('名前を保存できませんでした')));
    }
  }

  void _showLicenses() {
    _registerNotices();
    showLicensePage(context: context, applicationName: 'オトグラシ');
  }

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
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('キャッシュを整理しました')));
  }

  Future<void> _deleteDepthModel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('「とびだす」のデータを削除しますか？'),
        content: const Text('つくった動画はそのまま残ります。もう一度使うときは、ダウンロードし直します。'),
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
    final deleted = await _depthModel.delete();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(deleted ? 'データを削除しました' : '削除できませんでした')),
    );
  }
}

final class _UsageRow extends StatelessWidget {
  const _UsageRow({
    required this.label,
    required this.value,
    required this.icon,
  });

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

var _noticesRegistered = false;

/// Notices for what is not a Dart package: the depth model behind とびだす is
/// fetched on demand, and the bundled songs are public-domain compositions.
void _registerNotices() {
  if (_noticesRegistered) return;
  _noticesRegistered = true;
  LicenseRegistry.addLicense(
    () => Stream<LicenseEntry>.fromIterable(const [
      LicenseEntryWithLineBreaks(['Depth Anything V2 Small (Core ML)'], '''
Depth Anything V2 Small, Core ML conversion published by Apple
(apple/coreml-depth-anything-v2-small). Used by the "とびだす" style and
downloaded to this device only when that style is added.

Copyright the Depth Anything V2 authors.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.'''),
      LicenseEntryWithLineBreaks(['オトグラシの曲'], '''
歓喜の歌、きらきら星、エリーゼのために、ジングルベル、運命、カノンは、著作権の保護期間が終わった楽曲（パブリックドメイン）です。演奏データはこのアプリのために打ち込んだものです。'''),
    ]),
  );
}
