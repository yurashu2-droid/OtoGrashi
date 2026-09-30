import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import '../../storage/folder_repository.dart';
import '../create/clip_card.dart' show showClipTrimSheet;
import '../export/media_playback.dart';
import 'sound_actions.dart';
import 'sound_player_screen.dart';
import 'sound_row.dart';

/// Inside a folder: every sound it holds, newest first. Tap a sound to hear
/// it, tap its circle to pick it for a song (up to six), hold it for more.
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
  static const suggestedTags = ['声', 'まわりの音', 'リズム', '1日目', '2日目'];

  @override
  State<FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<FolderScreen> {
  late SoundFolder _folder = widget.folder;
  List<SoundFolder> _allFolders = const [];
  List<ClipAsset>? _sounds;
  Map<String, List<String>> _tags = const {};
  String? _filter;
  final _picked = <String>{};
  final _thumbnails = <String, Future<Uint8List>>{};
  final _waveforms = <String, Future<AudioWaveform>>{};
  var _busy = false;

  MediaPlaybackController? _playback;
  String? _playingId;
  PlaybackSegment? _playingSegment;
  var _autoStarted = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  Future<void> _reload() async {
    final folders = await widget.folders.list();
    final all = await widget.assets.list();
    final folder = folders.firstWhere(
      (f) => f.id == _folder.id,
      orElse: () => _folder,
    );
    final byId = {for (final asset in all) asset.id: asset};
    final sounds = [for (final id in folder.assetIds) ?byId[id]];
    final tags = await widget.folders.tagsFor(sounds.map((s) => s.id));
    if (!mounted) return;
    setState(() {
      _folder = folder;
      _allFolders = folders;
      _sounds = sounds;
      _tags = tags;
      _picked.retainWhere((id) => byId.containsKey(id));
      if (_filter != null && !tags.values.any((t) => t.contains(_filter))) {
        _filter = null;
      }
    });
  }

  Future<Uint8List>? _thumbnail(ClipAsset asset) {
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _thumbnails.putIfAbsent(
      asset.id,
      () => _guard(() => presentation.thumbnail(asset.relativePath)),
    );
  }

  Future<AudioWaveform>? _waveform(ClipAsset asset) {
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _waveforms.putIfAbsent(
      asset.id,
      () => _guard(() => presentation.waveform(asset.relativePath)),
    );
  }

  // --- playback: the tapped sound plays inside its own thumbnail ----------

  void _stop() {
    final playback = _playback;
    if (playback == null) return;
    playback.removeListener(_onPlayback);
    unawaited(playback.pause());
    // the movie view detaches on its way out; dispose after that frame
    WidgetsBinding.instance.addPostFrameCallback((_) => playback.dispose());
    _playback = null;
    _playingId = null;
    _playingSegment = null;
  }

  void _onPlayback() {
    final playback = _playback;
    if (playback == null) return;
    if (!_autoStarted && playback.isReady) {
      _autoStarted = true;
      unawaited(playback.toggle());
    }
    if (_autoStarted && playback.ended) {
      setState(_stop);
    }
  }

  void _play(ClipAsset asset, {int? startUs, int? durationUs}) {
    final presentation = widget.presentation;
    if (presentation == null) return;
    if (_playingId == asset.id && startUs == null) {
      unawaited(_playback?.toggle());
      return;
    }
    setState(() {
      _stop();
      _autoStarted = false;
      _playingId = asset.id;
      _playingSegment = PlaybackSegment(
        relativePath: asset.relativePath,
        startUs: startUs ?? asset.selectionStartUs,
        durationUs: durationUs ?? asset.selectionDurationUs,
      );
      _playback = MediaPlaybackController(presentation)
        ..addListener(_onPlayback);
    });
  }

  // --- picking ------------------------------------------------------------

  void _togglePick(ClipAsset asset) {
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

  // --- long-press actions -------------------------------------------------

  Future<void> _actions(ClipAsset asset, int number, Color color) async {
    final presentation = widget.presentation;
    final allTags = <String>{
      ...FolderScreen.suggestedTags,
      for (final tags in _tags.values) ...tags,
    }.toList();
    await showSoundActions(
      context,
      name: readableSoundName(asset.label, number),
      thumbnail: _thumbnail(asset),
      color: color,
      number: number,
      tags: _tags[asset.id] ?? const [],
      tagSuggestions: allTags,
      moveTargets: [
        for (final folder in _allFolders)
          if (folder.id != _folder.id) (id: folder.id, title: folder.title),
      ],
      onFullScreen: () {
        if (presentation == null) return;
        _stop();
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              fullscreenDialog: true,
              builder: (_) => SoundPlayerScreen(
                asset: asset,
                title: readableSoundName(asset.label, number),
                presentation: presentation,
              ),
            ),
          ),
        );
      },
      onTrim: () {
        final waveform = _waveform(asset);
        if (waveform == null) return;
        unawaited(
          showClipTrimSheet(
            context,
            clip: asset,
            waveform: waveform,
            selectionStartUs: asset.selectionStartUs,
            selectionDurationUs: asset.selectionDurationUs,
            onSave: (startUs, durationUs) async {
              await widget.folders.setSelection(asset.id, startUs, durationUs);
              await _reload();
            },
            onAudition: (startUs, durationUs) async =>
                _play(asset, startUs: startUs, durationUs: durationUs),
          ),
        );
      },
      onRename: (name) async {
        if (name.trim().isEmpty) return;
        await widget.assets.rename(asset.id, name.trim());
        await _reload();
      },
      onTags: (tags) async {
        await widget.folders.setTags(asset.id, tags);
        await _reload();
      },
      onMove: (folderId) async {
        await widget.folders.moveAsset(asset.id, _folder.id, folderId);
        _picked.remove(asset.id);
        await _reload();
      },
      onDelete: () async {
        if (_playingId == asset.id) setState(_stop);
        await widget.folders.removeEverywhere(asset.id);
        await widget.assets.deleteUnreferenced(asset.id);
        _picked.remove(asset.id);
        await _reload();
      },
    );
  }

  // --- folder -------------------------------------------------------------

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

  Future<void> _deleteFolder() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('「${_folder.title}」を削除しますか？'),
        content: const Text(
          'ほかのフォルダにも入っていない音は、一緒に削除されます。作った曲はそのまま残ります。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.blush,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 44),
            ),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(_stop);
    final elsewhere = <String>{
      for (final folder in _allFolders)
        if (folder.id != _folder.id) ...folder.assetIds,
    };
    await widget.folders.delete(_folder.id);
    for (final id in _folder.assetIds) {
      if (!elsewhere.contains(id)) await widget.assets.deleteUnreferenced(id);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _capture() async {
    setState(_stop);
    await widget.onCapture(_folder);
    await _reload();
  }

  Future<void> _make() async {
    final sounds = _sounds ?? const <ClipAsset>[];
    if (sounds.isEmpty || _busy) return;
    setState(_stop);
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
    final tagsInFolder = <String>{
      for (final tags in _tags.values) ...tags,
    }.toList();
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
          IconButton(
            onPressed: _deleteFolder,
            tooltip: 'フォルダを削除',
            icon: const Icon(Icons.delete_outline_rounded),
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
                  '${sounds.length}の音 · ${created.month}/${created.day}から'
                  '${_picked.isEmpty ? '' : ' · ${_picked.length}/6 えらんでいます'}',
                  style: const TextStyle(fontSize: 12, color: AppTokens.mutedInk),
                ),
                if (tagsInFolder.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final tag in [null, ...tagsInFolder])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _FilterPill(
                              label: tag ?? 'すべて',
                              selected: _filter == tag,
                              onTap: () => setState(() => _filter = tag),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
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
                else ...[
                  for (var i = 0; i < sounds.length; i++)
                    if (_filter == null ||
                        (_tags[sounds[i].id]?.contains(_filter) ?? false)) ...[
                      _FolderSoundTile(
                        number: i + 1,
                        asset: sounds[i],
                        color: AppTokens.soundColor(i),
                        tags: _tags[sounds[i].id] ?? const [],
                        picked: _picked.contains(sounds[i].id),
                        playing: _playingId == sounds[i].id,
                        playback: _playingId == sounds[i].id ? _playback : null,
                        segment: _playingId == sounds[i].id
                            ? _playingSegment
                            : null,
                        presentation: widget.presentation,
                        thumbnail: _thumbnail(sounds[i]),
                        waveform: _waveform(sounds[i]),
                        onTap: () => _play(sounds[i]),
                        onPick: () => _togglePick(sounds[i]),
                        onLongPress: () => _actions(
                          sounds[i],
                          i + 1,
                          AppTokens.soundColor(i),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  const SizedBox(height: 4),
                  const Text(
                    'タップで再生 · 右の丸で曲にえらぶ · 長押しでその他',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: AppTokens.mutedInk),
                  ),
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

final class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? AppTokens.ink : AppTokens.tile,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
          color: selected ? Colors.white : AppTokens.ink,
        ),
      ),
    ),
  );
}

final class _FolderSoundTile extends StatelessWidget {
  const _FolderSoundTile({
    required this.number,
    required this.asset,
    required this.color,
    required this.tags,
    required this.picked,
    required this.playing,
    required this.playback,
    required this.segment,
    required this.presentation,
    required this.thumbnail,
    required this.waveform,
    required this.onTap,
    required this.onPick,
    required this.onLongPress,
  });

  final int number;
  final ClipAsset asset;
  final Color color;
  final List<String> tags;
  final bool picked;
  final bool playing;
  final MediaPlaybackController? playback;
  final PlaybackSegment? segment;
  final MediaPresentationGateway? presentation;
  final Future<Uint8List>? thumbnail;
  final Future<AudioWaveform>? waveform;
  final VoidCallback onTap;
  final VoidCallback onPick;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final name = readableSoundName(asset.label, number);
    return Semantics(
      button: true,
      label: '$nameを再生',
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: playing || picked ? Colors.white : AppTokens.tile,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: picked
                  ? AppTokens.ink
                  : playing
                  ? color
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 60,
                child: playing &&
                        playback != null &&
                        segment != null &&
                        presentation != null
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: NativeMovieView(
                          key: ValueKey('${asset.id}:${segment!.startUs}'),
                          relativePath: asset.relativePath,
                          segments: [segment!],
                          gateway: presentation!,
                          controller: playback!,
                          fallback: ColoredBox(color: color),
                        ),
                      )
                    : SoundThumb(
                        thumbnail: thumbnail,
                        color: color,
                        number: number,
                        size: 60,
                      ),
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
                            name,
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
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [for (final tag in tags) SoundTagChip(tag)],
                      ),
                    ],
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
              const SizedBox(width: 4),
              Semantics(
                button: true,
                selected: picked,
                label: picked ? '$nameを曲から外す' : '$nameを曲にえらぶ',
                child: GestureDetector(
                  onTap: onPick,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox.square(
                    dimension: 44,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: picked ? AppTokens.ink : Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: picked ? AppTokens.ink : AppTokens.hairline,
                            width: 2,
                          ),
                        ),
                        child: picked
                            ? const Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
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

/// A preview that fails (even synchronously) must not take the page down;
/// the sound then shows its colour and a stand-in waveform.
Future<T> _guard<T>(Future<T> Function() request) {
  try {
    return request();
  } catch (error, stackTrace) {
    return Future<T>.error(error, stackTrace);
  }
}
