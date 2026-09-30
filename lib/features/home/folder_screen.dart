import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import '../../storage/folder_repository.dart';
import 'sound_row.dart';

/// Inside a folder: every sound it holds, newest first. Pick up to six for
/// a song (or let it pick the newest), or record straight into the folder.
final class FolderScreen extends StatefulWidget {
  const FolderScreen({
    required this.folder,
    required this.folders,
    required this.assets,
    required this.onCapture,
    required this.onMakeSong,
    this.presentation,
    super.key,
  });

  final SoundFolder folder;
  final FolderRepository folders;
  final AssetRepository assets;
  final MediaPresentationGateway? presentation;

  /// Record into this folder; completes when the camera closes.
  final Future<void> Function(SoundFolder folder) onCapture;

  /// Start a song from these sounds (one to six).
  final Future<void> Function(List<ClipAsset> sounds) onMakeSong;

  static const maxPerSong = 6;

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  late SoundFolder _folder = widget.folder;
  List<ClipAsset>? _sounds;
  final _picked = <String>{};
  final _thumbnails = <String, Future<Uint8List>>{};
  final _waveforms = <String, Future<AudioWaveform>>{};
  var _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final folders = await widget.folders.list();
    final all = await widget.assets.list();
    if (!mounted) return;
    final folder = folders.firstWhere(
      (f) => f.id == _folder.id,
      orElse: () => _folder,
    );
    final byId = {for (final asset in all) asset.id: asset};
    setState(() {
      _folder = folder;
      _sounds = [for (final id in folder.assetIds) ?byId[id]];
      _picked.retainWhere((id) => byId.containsKey(id));
    });
  }

  Future<Uint8List>? _thumbnail(ClipAsset asset) {
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _thumbnails.putIfAbsent(
      asset.id,
      () => presentation.thumbnail(asset.relativePath),
    );
  }

  Future<AudioWaveform>? _waveform(ClipAsset asset) {
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _waveforms.putIfAbsent(
      asset.id,
      () => presentation.waveform(asset.relativePath),
    );
  }

  void _toggle(ClipAsset asset) {
    setState(() {
      if (!_picked.remove(asset.id)) {
        if (_picked.length >= FolderScreen.maxPerSong) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(const SnackBar(content: Text('1曲に使える音は6つまでです')));
          return;
        }
        _picked.add(asset.id);
      }
    });
  }

  Future<void> _rename() async {
    var draft = _folder.title;
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('フォルダの名前'),
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '例：沖縄旅行のオトグラシ'),
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
    if (chosen == null || chosen.trim().isEmpty) return;
    await widget.folders.rename(_folder.id, chosen);
    await _reload();
  }

  Future<void> _capture() async {
    await widget.onCapture(_folder);
    await _reload();
  }

  Future<void> _make() async {
    final sounds = _sounds ?? const <ClipAsset>[];
    if (sounds.isEmpty || _busy) return;
    // nothing picked: the newest sounds, up to six
    final chosen = _picked.isEmpty
        ? sounds.take(FolderScreen.maxPerSong).toList()
        : sounds.where((s) => _picked.contains(s.id)).toList();
    setState(() => _busy = true);
    try {
      await widget.onMakeSong(chosen);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sounds = _sounds;
    final created = _folder.createdAt.toLocal();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.maybePop(context),
          tooltip: '戻る',
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        actions: [
          IconButton(
            onPressed: _rename,
            tooltip: 'フォルダの名前を変える',
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: sounds == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                GestureDetector(
                  onTap: _rename,
                  child: Text(
                    _folder.title,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppTokens.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${sounds.length}の音 · ${created.month}/${created.day}から',
                  style: const TextStyle(fontSize: 12, color: AppTokens.mutedInk),
                ),
                const SizedBox(height: 6),
                Text(
                  _picked.isEmpty
                      ? 'タップで曲に使う音をえらべます（6つまで・えらばなければ新しい順）'
                      : '${_picked.length}/6 えらんでいます',
                  style: const TextStyle(fontSize: 12, color: AppTokens.mutedInk),
                ),
                const SizedBox(height: 14),
                if (sounds.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTokens.tile,
                      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                    ),
                    child: const Text(
                      'まだ音がありません。下のマイクから、このフォルダに録ってみよう。',
                      style: TextStyle(color: AppTokens.mutedInk),
                    ),
                  )
                else
                  for (var i = 0; i < sounds.length; i++) ...[
                    _FolderSoundTile(
                      number: i + 1,
                      asset: sounds[i],
                      color: AppTokens.soundColor(i),
                      picked: _picked.contains(sounds[i].id),
                      thumbnail: _thumbnail(sounds[i]),
                      waveform: _waveform(sounds[i]),
                      onTap: () => _toggle(sounds[i]),
                    ),
                    const SizedBox(height: 8),
                  ],
              ],
            ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Semantics(
              button: true,
              label: 'このフォルダに音を録る',
              child: GestureDetector(
                onTap: _capture,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    color: AppTokens.blush,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.mic_none_rounded, color: Colors.white),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: (sounds?.isEmpty ?? true) || _busy ? null : _make,
                child: Text(
                  _picked.isEmpty
                      ? 'この音で曲をつくる'
                      : '${_picked.length}つの音で曲をつくる',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String readableSoundName(String label, int index) =>
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(label)
    ? '録った音 $index'
    : label;

final class _FolderSoundTile extends StatelessWidget {
  const _FolderSoundTile({
    required this.number,
    required this.asset,
    required this.color,
    required this.picked,
    required this.thumbnail,
    required this.waveform,
    required this.onTap,
  });

  final int number;
  final ClipAsset asset;
  final Color color;
  final bool picked;
  final Future<Uint8List>? thumbnail;
  final Future<AudioWaveform>? waveform;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: picked,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: picked ? Colors.white : AppTokens.tile,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: picked ? AppTokens.ink : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            SoundThumb(
              thumbnail: thumbnail,
              color: color,
              number: number,
              size: 60,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          readableSoundName(asset.label, number),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(asset.selectionDurationUs / 1e6).toStringAsFixed(1)}秒',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTokens.mutedInk,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 22,
                    child: FutureBuilder<AudioWaveform>(
                      future: waveform,
                      builder: (context, snapshot) => CustomPaint(
                        size: Size.infinite,
                        painter: SoundBarsPainter(
                          levels:
                              snapshot.data?.levels ??
                              pseudoLevels(asset.id.hashCode),
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: picked ? AppTokens.ink : Colors.white,
                shape: BoxShape.circle,
              ),
              child: picked
                  ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                  : null,
            ),
          ],
        ),
      ),
    ),
  );
}
