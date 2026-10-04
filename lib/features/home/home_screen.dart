import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/wordmark.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import '../../storage/folder_repository.dart';
import 'folder_screen.dart';
import 'sound_row.dart';

/// Home: the in-progress collection, the folders ("〇〇のオトグラシ") sounds
/// are kept in, and the most recent sounds.
final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.currentClips,
    required this.thumbnails,
    required this.assets,
    required this.onOpenCurrent,
    this.folders,
    this.onOpenFolder,
    this.onOpenSharedFolders,
    this.ownerName,
    this.presentation,
    this.onAssetSelected,
    this.onSettings,
    super.key,
  });

  final List<ClipAsset> currentClips;
  final Map<String, Uint8List> thumbnails;
  final AssetRepository assets;
  final VoidCallback onOpenCurrent;
  final FolderRepository? folders;

  /// Opens a folder; completes when the person comes back to Home.
  final Future<void> Function(SoundFolder folder)? onOpenFolder;
  final VoidCallback? onOpenSharedFolders;
  final String? ownerName;
  final MediaPresentationGateway? presentation;
  final ValueChanged<ClipAsset>? onAssetSelected;
  final VoidCallback? onSettings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _data = _load();
  final _waveforms = <String, Future<AudioWaveform>>{};
  final _thumbs = <String, Future<Uint8List>>{};

  Future<_HomeData> _load() async {
    final folders = await widget.folders?.list() ?? const <SoundFolder>[];
    final all = await widget.assets.list();
    return _HomeData(
      folders: folders,
      assets: {for (final asset in all) asset.id: asset},
      recent: all.reversed.take(8).toList(),
    );
  }

  void _reload() => setState(() => _data = _load());

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentClips.length != widget.currentClips.length) {
      _data = _load();
    }
  }

  Future<AudioWaveform>? _waveform(ClipAsset asset) {
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _waveforms.putIfAbsent(
      asset.id,
      () => _guard(() => presentation.waveform(asset.relativePath)),
    );
  }

  Future<Uint8List>? _thumb(ClipAsset asset) {
    final cached = widget.thumbnails[asset.id];
    if (cached != null) return Future<Uint8List>.value(cached);
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _thumbs.putIfAbsent(
      asset.id,
      () => _guard(() => presentation.thumbnail(asset.relativePath)),
    );
  }

  Future<void> _newFolder() async {
    final folders = widget.folders;
    if (folders == null) return;
    var draft = '';
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新しいフォルダ'),
        content: TextFormField(
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
            child: const Text('つくる'),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await folders.create(chosen);
    if (mounted) _reload();
  }

  Future<void> _open(SoundFolder folder) async {
    await widget.onOpenFolder?.call(folder);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.ownerName;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: FutureBuilder<_HomeData>(
          future: _data,
          builder: (context, snapshot) {
            final data = snapshot.data;
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const OtoWordmark(),
                          const SizedBox(height: 4),
                          Text(
                            owner == null || owner.isEmpty
                                ? '毎日の音を、フォルダにあつめる'
                                : '$ownerの毎日の音',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    if (widget.onSettings != null)
                      IconButton(
                        onPressed: widget.onSettings,
                        tooltip: '設定',
                        icon: const Icon(Icons.settings_outlined),
                      ),
                  ],
                ),
                if (widget.currentClips.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _DraftSongCard(
                    thumbs: [
                      for (final clip in widget.currentClips) _thumb(clip),
                    ],
                    onTap: widget.onOpenCurrent,
                  ),
                ],
                const SizedBox(height: 20),
                const _SectionLabel('フォルダ'),
                const SizedBox(height: 10),
                SizedBox(
                  height: 236,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.none,
                    children: [
                      for (final folder
                          in data?.folders ?? const <SoundFolder>[]) ...[
                        _FolderCard(
                          title: folder.title,
                          caption: '${folder.assetIds.length}の音',
                          tiles: [
                            for (final id in folder.assetIds.take(4))
                              if (data!.assets[id] case final asset?)
                                _thumb(asset),
                          ],
                          colorCount: folder.assetIds.length.clamp(0, 12),
                          onTap: () => _open(folder),
                        ),
                        const SizedBox(width: 12),
                      ],
                      if (widget.folders != null)
                        _NewFolderCard(onTap: _newFolder),
                    ],
                  ),
                ),
                if (widget.onOpenSharedFolders != null) ...[
                  const SizedBox(height: 20),
                  Card(
                    color: AppTokens.blushSoft,
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      leading: const Icon(
                        Icons.people_alt_outlined,
                        color: AppTokens.ink,
                        size: 30,
                      ),
                      title: const Text(
                        'みんなの音',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: const Text('友だちとひとつのフォルダに集めよう'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: widget.onOpenSharedFolders,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                const _SectionLabel('さいきんの音'),
                const SizedBox(height: 10),
                if (data == null)
                  const SizedBox(height: 120)
                else if (data.recent.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTokens.tile,
                      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                    ),
                    child: const Text(
                      'まだ音がありません。まんなかのマイクから録ってみよう。',
                      style: TextStyle(color: AppTokens.mutedInk),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < data.recent.length; i++)
                          SoundRow(
                            number: i + 1,
                            color: AppTokens.soundColor(i),
                            label: readableSoundName(
                              data.recent[i].label,
                              i + 1,
                            ),
                            seconds: data.recent[i].selectionDurationUs / 1e6,
                            waveform: _waveform(data.recent[i]),
                            thumbnail: _thumb(data.recent[i]),
                            seed: data.recent[i].id.hashCode,
                            trailing: widget.onAssetSelected == null
                                ? null
                                : IconButton(
                                    tooltip: 'つくりかけの曲に入れる',
                                    onPressed: () =>
                                        widget.onAssetSelected!(data.recent[i]),
                                    icon: const Icon(Icons.add_rounded),
                                  ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _HomeData {
  const _HomeData({
    required this.folders,
    required this.assets,
    required this.recent,
  });

  final List<SoundFolder> folders;
  final Map<String, ClipAsset> assets;
  final List<ClipAsset> recent;
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w800,
      color: AppTokens.ink,
    ),
  );
}

final class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.title,
    required this.caption,
    required this.tiles,
    required this.colorCount,
    required this.onTap,
  });

  final String title;
  final String caption;
  final List<Future<Uint8List>?> tiles;
  final int colorCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$title $caption',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTokens.tileRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 3,
                  crossAxisSpacing: 3,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  children: [
                    for (var i = 0; i < 4; i++)
                      i < tiles.length
                          ? FutureBuilder<Uint8List>(
                              future: tiles[i],
                              builder: (context, snapshot) => snapshot.hasData
                                  ? Image.memory(
                                      snapshot.data!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stack) =>
                                          Container(
                                            color: AppTokens.soundColor(i),
                                          ),
                                    )
                                  : Container(color: AppTokens.soundColor(i)),
                            )
                          : Container(color: AppTokens.tile),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: colorCount == 0
                    ? Container(color: AppTokens.tile)
                    : Row(
                        children: [
                          for (var i = 0; i < colorCount; i++)
                            Expanded(
                              child: Container(color: AppTokens.soundColor(i)),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: AppTokens.ink,
              ),
            ),
            Row(
              children: [
                Text(
                  caption,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTokens.mutedInk,
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

final class _NewFolderCard extends StatelessWidget {
  const _NewFolderCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'フォルダをつくる',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 120,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTokens.tileRadius),
          border: Border.all(color: AppTokens.hairline, width: 2),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_rounded, color: AppTokens.mutedInk, size: 28),
            SizedBox(height: 6),
            Text(
              'フォルダを\nつくる',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppTokens.mutedInk,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The song in progress: its sounds in a row, one tap to carry on.
final class _DraftSongCard extends StatelessWidget {
  const _DraftSongCard({required this.thumbs, required this.onTap});

  final List<Future<Uint8List>?> thumbs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'つくりかけの曲 ${thumbs.length}/6つの音',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(AppTokens.tileRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: AppTokens.blush,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'つくりかけの曲',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: AppTokens.ink,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${thumbs.length}/6つの音',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppTokens.mutedInk,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (var i = 0; i < thumbs.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: SoundThumb(
                            thumbnail: thumbs[i],
                            color: AppTokens.soundColor(i),
                            number: i + 1,
                            size: 40,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppTokens.mutedInk),
          ],
        ),
      ),
    ),
  );
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
