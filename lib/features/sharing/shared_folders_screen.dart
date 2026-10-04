import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../../sharing/shared_folder_service.dart';
import '../../storage/asset_repository.dart';
import '../home/sound_player_screen.dart';

/// Private folders are separate from the personal stock on this device.
class SharedFoldersScreen extends StatefulWidget {
  const SharedFoldersScreen({
    required this.service,
    required this.assets,
    required this.presentation,
    required this.onMakeSong,
    this.ownerName,
    this.initialInvitation,
    super.key,
  });
  final SharedFolderService service;
  final AssetRepository assets;
  final MediaPresentationGateway presentation;
  final Future<void> Function(List<ClipAsset>) onMakeSong;
  final String? ownerName, initialInvitation;
  @override
  State<SharedFoldersScreen> createState() => _SharedFoldersScreenState();
}

class _SharedFoldersScreenState extends State<SharedFoldersScreen> {
  List<SharedFolderMembership> _folders = [];
  String? _error;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
    if (widget.initialInvitation != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _form(join: true, initial: widget.initialInvitation);
      });
    }
  }

  Future<void> _load() async {
    try {
      final folders = await widget.service.listMemberships();
      if (mounted) {
        setState(() {
          _folders = folders;
          _error = null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _form({required bool join, String? initial}) async {
    Uri? server;
    try {
      server = await widget.service.configuredServer();
    } catch (e) {
      if (mounted) _notice(context, _message(e));
      return;
    }
    if (!mounted) return;
    final result = await showDialog<SharedFolder>(
      context: context,
      builder: (_) => _ConnectionDialog(
        service: widget.service,
        join: join,
        server: server,
        initialInvitation: initial,
        ownerName: widget.ownerName,
      ),
    );
    if (result != null) {
      await _load();
      final matches = _folders.where((m) => m.folderId == result.id);
      if (mounted && matches.isNotEmpty) await _open(matches.first);
    }
  }

  Future<void> _open(SharedFolderMembership membership) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _SharedFolderScreen(
          service: widget.service,
          assets: widget.assets,
          presentation: widget.presentation,
          membership: membership,
          onMakeSong: widget.onMakeSong,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('友だちと音を集める')),
    body: _page(
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(
              Icons.people_alt_outlined,
              size: 48,
              color: AppTokens.lavender,
            ),
            const SizedBox(height: 16),
            const Text(
              'いつもの音を、みんなの音に。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            const Text(
              '自分のストックから選んだ音だけを共有します。友だちの音を保存して、曲づくりにも使えます。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _form(join: false),
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('共有フォルダをつくる'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _form(join: true),
              icon: const Icon(Icons.link),
              label: const Text('招待リンクで参加する'),
            ),
            const SizedBox(height: 32),
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (_error != null) _retry(_error!, _load),
            if (!_loading && _error == null && _folders.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('参加したフォルダがここに並びます。', textAlign: TextAlign.center),
              ),
            for (final folder in _folders)
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  leading: const Icon(
                    Icons.folder_outlined,
                    color: AppTokens.lavender,
                  ),
                  title: Text(folder.title),
                  subtitle: Text(folder.isOwner ? 'あなたがつくったフォルダ' : '参加中'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(folder),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _ConnectionDialog extends StatefulWidget {
  const _ConnectionDialog({
    required this.service,
    required this.join,
    this.server,
    this.initialInvitation,
    this.ownerName,
  });
  final SharedFolderService service;
  final bool join;
  final Uri? server;
  final String? initialInvitation, ownerName;
  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late final _link = TextEditingController(text: widget.initialInvitation);
  late final _name = TextEditingController(text: widget.ownerName);
  final _title = TextEditingController();
  final _server = TextEditingController();
  bool _busy = false;
  String? _error;
  Uri? _invitationServer;
  @override
  void initState() {
    super.initState();
    _parse();
    _link.addListener(_parse);
  }

  void _parse() {
    Uri? value;
    try {
      value = SharedInvitation.parse(_link.text).server;
    } catch (_) {}
    if (mounted) setState(() => _invitationServer = value);
  }

  @override
  void dispose() {
    _link.dispose();
    _name.dispose();
    _title.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_name.text.trim().isEmpty || _name.text.trim().runes.length > 30) {
        throw const FormatException('表示名を1〜30文字で入力してください。');
      }
      if (widget.join) {
        SharedInvitation.parse(_link.text);
      } else {
        if (_title.text.trim().isEmpty ||
            _title.text.trim().runes.length > 40) {
          throw const FormatException('フォルダ名を1〜40文字で入力してください。');
        }
        if (widget.server == null) {
          await widget.service.configureServer(_server.text);
        }
      }
      final folder = widget.join
          ? await widget.service.joinFolder(
              _link.text.trim(),
              _name.text.trim(),
            )
          : await widget.service.createFolder(
              _title.text.trim(),
              _name.text.trim(),
            );
      if (mounted) Navigator.pop(context, folder);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _message(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.join ? '友だちのフォルダに参加' : '共有フォルダをつくる'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: widget.join ? _link : _title,
              enabled: !_busy,
              maxLines: widget.join ? 3 : 1,
              decoration: InputDecoration(
                labelText: widget.join ? '招待リンク' : 'フォルダ名',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '友だちに見える表示名'),
            ),
            if (!widget.join && widget.server == null) ...[
              const SizedBox(height: 16),
              const Text('共有サービスのアドレスが未設定です。管理者から受け取ったアドレスを入力してください。'),
              const SizedBox(height: 8),
              TextField(
                controller: _server,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'サービスのアドレス（HTTPS）',
                ),
              ),
            ],
            if (widget.join) ...[
              const SizedBox(height: 16),
              if (_invitationServer != null) Text('接続先：$_invitationServer'),
              const SizedBox(height: 8),
              const Text('参加すると、このフォルダの音を閲覧・保存し、自分の音を追加できます。'),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      TextButton(
        onPressed: _busy || (widget.join && _invitationServer == null)
            ? null
            : _submit,
        child: Text(widget.join ? 'この接続先に参加する' : 'つくる'),
      ),
    ],
  );
}

class _SharedFolderScreen extends StatefulWidget {
  const _SharedFolderScreen({
    required this.service,
    required this.assets,
    required this.presentation,
    required this.membership,
    required this.onMakeSong,
  });
  final SharedFolderService service;
  final AssetRepository assets;
  final MediaPresentationGateway presentation;
  final SharedFolderMembership membership;
  final Future<void> Function(List<ClipAsset>) onMakeSong;
  @override
  State<_SharedFolderScreen> createState() => _SharedFolderScreenState();
}

class _SharedFolderScreenState extends State<_SharedFolderScreen> {
  SharedFolder? _folder;
  String? _error;
  bool _busy = false;
  final _selected = <String>{};
  final _thumbnails = <String, Future<Uint8List?>>{};
  final _downloads = <String, Future<ClipAsset>>{};
  final _progress = <String, double>{};
  final _transferErrors = <String, String>{};
  final _uploaded = <String>{};
  final _uploadAssets = <String, ClipAsset>{};
  String get _id => widget.membership.folderId;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final folder = await widget.service.refresh(_id);
      if (mounted) {
        setState(() {
          _folder = folder;
          _error = null;
          _selected.removeWhere((id) => !folder.clips.any((c) => c.id == id));
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _notice(context, _message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ClipAsset> _download(SharedClip clip) {
    return _downloads.putIfAbsent(clip.id, () async {
      try {
        return await widget.service.download(
          _id,
          clip,
          onProgress: (p) {
            if (mounted) setState(() => _progress[clip.id] = p);
          },
        );
      } catch (e) {
        _downloads.remove(clip.id);
        rethrow;
      } finally {
        if (mounted) setState(() => _progress.remove(clip.id));
      }
    });
  }

  Future<void> _preview(SharedClip clip) => _action(() async {
    final asset = await _download(clip);
    if (mounted) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SoundPlayerScreen(
            asset: asset,
            title: clip.label,
            presentation: widget.presentation,
          ),
        ),
      );
    }
  });
  Future<void> _save(SharedClip clip) => _action(() async {
    await _download(clip);
    if (mounted) _notice(context, '自分のストックに保存しました。');
  });
  Future<void> _makeSong() => _action(() async {
    final assets = <ClipAsset>[];
    for (final clip in _folder!.clips.where((c) => _selected.contains(c.id))) {
      assets.add(await _download(clip));
    }
    if (mounted) await widget.onMakeSong(assets);
  });
  Future<void> _uploadOne(ClipAsset asset) async {
    setState(() {
      _progress[asset.id] = 0;
      _transferErrors.remove(asset.id);
    });
    try {
      Uint8List? thumbnail;
      try {
        thumbnail = await widget.presentation.thumbnail(asset.relativePath);
      } catch (_) {}
      await widget.service.upload(
        _id,
        asset,
        thumbnail: thumbnail,
        onProgress: (p) {
          if (mounted) setState(() => _progress[asset.id] = p);
        },
      );
      if (mounted) setState(() => _uploaded.add(asset.id));
    } catch (e) {
      if (mounted) {
        setState(() {
          if (e is SharedFolderException &&
              e.code == 'thumbnail_failed_after_upload') {
            _uploaded.add(asset.id);
          }
          _transferErrors[asset.id] = _message(e);
        });
      }
    } finally {
      if (mounted) setState(() => _progress.remove(asset.id));
    }
  }

  Future<void> _pickUpload() => _action(() async {
    final assets = await widget.assets.list();
    if (!mounted) return;
    final selected = await showDialog<List<ClipAsset>>(
      context: context,
      builder: (_) =>
          _StockPicker(assets: assets, presentation: widget.presentation),
    );
    if (selected == null || !mounted) return;
    for (final asset in selected) {
      _uploadAssets[asset.id] = asset;
      await _uploadOne(asset);
      if (!mounted) return;
    }
    await _refresh();
  });
  Future<void> _invite() => _action(() async {
    if (!await _confirm(
      context,
      '招待リンクを発行する',
      '新しい招待リンクを発行すると、以前のリンクは使えなくなります。参加済みの友だちはそのままです。',
    )) {
      return;
    }
    final link = await widget.service.invite(_id);
    if (!mounted) return;
    final text =
        'OtoGrashiで一緒に音を集めよう！\n$link\nアプリの「友だちと音を集める」→「招待リンクで参加する」に貼り付けてください。\n参加してほしい人だけに送ってください（有効期限7日）。';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('友だちを招待'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: link.toString()));
                if (context.mounted) _notice(context, '招待リンクをコピーしました。');
              } catch (_) {
                if (context.mounted) {
                  _notice(context, 'コピーできませんでした。招待リンクを長押ししてコピーしてください。');
                }
              }
            },
            child: const Text('招待リンクをコピー'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  });
  Future<void> _members() async {
    final folder = _folder;
    if (folder == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '参加している友だち',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 16),
              for (final member in folder.members)
                ListTile(
                  title: Text(member.displayName),
                  subtitle: Text(member.role == 'owner' ? 'フォルダのオーナー' : 'メンバー'),
                  trailing: widget.membership.isOwner && member.role != 'owner'
                      ? IconButton(
                          tooltip: '参加を取り消す',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () async {
                            if (!await _confirm(
                              sheetContext,
                              '${member.displayName}さんの参加を取り消す',
                              'フォルダにアクセスできなくなります。すでに保存された音は相手の端末に残ります。',
                            )) {
                              return;
                            }
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
                            await _action(() async {
                              await widget.service.removeMember(_id, member.id);
                              await _refresh();
                            });
                          },
                        )
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exit() => _action(() async {
    final owner = widget.membership.isOwner;
    if (!await _confirm(
      context,
      owner ? '共有フォルダを閉じる' : 'フォルダから退出する',
      owner
          ? '全員がアクセスできなくなり、共有したファイルは削除されます。自分や友だちの端末に保存された音は残ります。'
          : 'この端末からフォルダにアクセスできなくなります。自分のストックに保存した音は残ります。',
    )) {
      return;
    }
    if (owner) {
      await widget.service.deleteFolder(_id);
    } else {
      await widget.service.leaveFolder(_id);
    }
    if (mounted) Navigator.pop(context);
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_folder?.title ?? widget.membership.title),
      actions: [
        IconButton(
          tooltip: '参加者',
          onPressed: _busy ? null : _members,
          icon: const Icon(Icons.people_outline),
        ),
        PopupMenuButton<String>(
          enabled: !_busy,
          onSelected: (value) {
            if (value == 'invite') _invite();
            if (value == 'exit') _exit();
          },
          itemBuilder: (_) => [
            if (widget.membership.isOwner)
              const PopupMenuItem(value: 'invite', child: Text('招待リンクを発行・更新')),
            PopupMenuItem(
              value: 'exit',
              child: Text(widget.membership.isOwner ? 'フォルダを閉じる' : 'フォルダから退出'),
            ),
          ],
        ),
      ],
    ),
    body: _page(
      RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            if (_busy) const LinearProgressIndicator(),
            const Text(
              'みんなが見つけた音',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text('下に引っぱって最新の音を読み込みます。'),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickUpload,
              icon: const Icon(Icons.add),
              label: const Text('自分のストックから共有'),
            ),
            for (final asset in _uploadAssets.values)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${asset.label}：${_uploaded.contains(asset.id)
                          ? '共有しました'
                          : _transferErrors.containsKey(asset.id)
                          ? '共有できませんでした'
                          : '共有中'}',
                    ),
                    if (_progress.containsKey(asset.id))
                      LinearProgressIndicator(value: _progress[asset.id]),
                    if (_transferErrors.containsKey(asset.id)) ...[
                      Text(_transferErrors[asset.id]!),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _action(() async {
                                await _uploadOne(asset);
                                await _refresh();
                              }),
                        child: const Text('この音を再試行'),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 20),
            if (_error != null) _retry(_error!, _refresh),
            if (_folder == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_folder != null && _folder!.clips.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('最初の音を共有してみましょう。', textAlign: TextAlign.center),
              ),
            for (final clip in _folder?.clips ?? <SharedClip>[])
              _clipCard(clip),
            const SizedBox(height: 80),
          ],
        ),
      ),
    ),
    bottomNavigationBar: _selected.isEmpty
        ? null
        : SafeArea(
            child: _page(
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: FilledButton.icon(
                  onPressed: _busy ? null : _makeSong,
                  icon: const Icon(Icons.music_note),
                  label: Text('選んだ${_selected.length}つの音で曲をつくる'),
                ),
              ),
            ),
          ),
  );
  Widget _clipCard(SharedClip clip) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: FutureBuilder<Uint8List?>(
                    future: clip.hasThumbnail
                        ? _thumbnails.putIfAbsent(
                            clip.id,
                            () => widget.service.thumbnail(_id, clip.id),
                          )
                        : null,
                    builder: (_, snapshot) => snapshot.data != null
                        ? Image.memory(
                            snapshot.data!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => _soundIcon(),
                          )
                        : _soundIcon(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clip.label,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '${clip.memberName} · ${(clip.durationUs / 1000000).toStringAsFixed(1)}秒',
                    ),
                  ],
                ),
              ),
              Checkbox(
                value: _selected.contains(clip.id),
                semanticLabel: '${clip.label}を曲に使う',
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == true && _selected.length >= 6) {
                          _notice(context, '一度に使える音は6つまでです。');
                          return;
                        }
                        setState(() {
                          if (value == true) {
                            _selected.add(clip.id);
                          } else {
                            _selected.remove(clip.id);
                          }
                        });
                      },
              ),
            ],
          ),
          if (_progress.containsKey(clip.id))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(value: _progress[clip.id]),
            ),
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _preview(clip),
                icon: const Icon(Icons.play_arrow),
                label: const Text('聴く'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : () => _save(clip),
                icon: const Icon(Icons.download_outlined),
                label: const Text('ストックに保存'),
              ),
              if (widget.membership.isOwner ||
                  widget.membership.memberId == clip.memberId)
                IconButton(
                  tooltip: '共有した音を削除',
                  onPressed: _busy
                      ? null
                      : () => _action(() async {
                          if (!await _confirm(
                            context,
                            '共有した音を削除',
                            '「${clip.label}」を共有フォルダから削除します。端末に保存された音は残ります。',
                          )) {
                            return;
                          }
                          await widget.service.deleteClip(_id, clip.id);
                          await _refresh();
                        }),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _soundIcon() => const ColoredBox(
    color: AppTokens.blushSoft,
    child: Center(child: Icon(Icons.music_note, color: AppTokens.ink)),
  );
}

class _StockPicker extends StatefulWidget {
  const _StockPicker({required this.assets, required this.presentation});
  final List<ClipAsset> assets;
  final MediaPresentationGateway presentation;
  @override
  State<_StockPicker> createState() => _StockPickerState();
}

class _StockPickerState extends State<_StockPicker> {
  final _selected = <String>{};
  final _thumbnails = <String, Future<Uint8List>>{};
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('共有する音を選ぶ'),
    content: SizedBox(
      width: 400,
      height: 360,
      child: widget.assets.isEmpty
          ? const Center(child: Text('まだストックに音がありません。先に音を録ってみましょう。'))
          : ListView(
              children: [
                for (final asset in widget.assets)
                  CheckboxListTile(
                    secondary: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 44,
                        height: 56,
                        child: FutureBuilder<Uint8List>(
                          future: _thumbnails.putIfAbsent(
                            asset.id,
                            () => widget.presentation.thumbnail(
                              asset.relativePath,
                            ),
                          ),
                          builder: (_, snapshot) => snapshot.hasData
                              ? Image.memory(
                                  snapshot.data!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) =>
                                      const Icon(Icons.music_note),
                                )
                              : const ColoredBox(
                                  color: AppTokens.blushSoft,
                                  child: Icon(Icons.music_note),
                                ),
                        ),
                      ),
                    ),
                    title: Text(asset.label),
                    subtitle: Text(
                      '${(asset.durationUs / 1000000).toStringAsFixed(1)}秒',
                    ),
                    value: _selected.contains(asset.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected.add(asset.id);
                      } else {
                        _selected.remove(asset.id);
                      }
                    }),
                  ),
              ],
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      TextButton(
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.pop(
                context,
                widget.assets.where((a) => _selected.contains(a.id)).toList(),
              ),
        child: Text('${_selected.length}つの音を共有'),
      ),
    ],
  );
}

Widget _page(Widget child) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: AppTokens.contentWidth),
    child: child,
  ),
);
Widget _retry(String message, Future<void> Function() retry) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 16),
  child: Column(
    children: [
      Text(message),
      TextButton.icon(
        onPressed: retry,
        icon: const Icon(Icons.refresh),
        label: const Text('もう一度試す'),
      ),
    ],
  ),
);
void _notice(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
String _message(Object error) {
  if (error is SharedFolderException) return error.message;
  if (error is FormatException) return error.message;
  return '通信できませんでした。接続を確認して、もう一度試してください。';
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('続ける'),
          ),
        ],
      ),
    ) ??
    false;
