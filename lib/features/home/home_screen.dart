import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import 'folder_mock_screen.dart';
import 'sound_row.dart';

/// Home: the folders ("オトグラシ") sounds are collected into, and the most
/// recent sounds. The first folder is the real in-progress collection; the
/// others preview the shared-folder idea and are mock screens for now.
final class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.currentClips,
    required this.thumbnails,
    required this.assets,
    required this.onOpenCurrent,
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
  final String? ownerName;
  final MediaPresentationGateway? presentation;
  final ValueChanged<ClipAsset>? onAssetSelected;
  final VoidCallback? onSettings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<ClipAsset>> _recent = _loadRecent();
  final _waveforms = <String, Future<AudioWaveform>>{};

  Future<AudioWaveform>? _waveform(ClipAsset asset) {
    final presentation = widget.presentation;
    if (presentation == null) return null;
    return _waveforms.putIfAbsent(
      asset.id,
      () => presentation.waveform(asset.relativePath),
    );
  }

  Future<List<ClipAsset>> _loadRecent() async {
    final all = await widget.assets.list();
    return all.reversed.take(8).toList();
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentClips.length != widget.currentClips.length) {
      _recent = _loadRecent();
    }
  }

  void _soon(String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$whatは、もうすぐ使えるようになります')));
  }

  @override
  Widget build(BuildContext context) {
    final owner = widget.ownerName;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'オトグラシ',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: AppTokens.ink,
                        ),
                      ),
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
            const SizedBox(height: 20),
            const _SectionLabel('フォルダ'),
            const SizedBox(height: 10),
            SizedBox(
              height: 236,
              child: ListView(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                children: [
                  _FolderCard(
                    title: 'いま集めてる音',
                    caption: '${widget.currentClips.length}/6つ',
                    tiles: [
                      for (final clip in widget.currentClips.take(4))
                        _Tile(image: widget.thumbnails[clip.id]),
                    ],
                    colors: [
                      for (var i = 0; i < widget.currentClips.length; i++)
                        AppTokens.soundColor(i),
                    ],
                    live: true,
                    onTap: widget.onOpenCurrent,
                  ),
                  const SizedBox(width: 12),
                  for (final folder in FolderMock.samples) ...[
                    _FolderCard(
                      title: folder.title,
                      caption: '${folder.sounds.length}つ · ${folder.members}人',
                      tiles: [
                        for (final tone in folder.tones.take(4))
                          _Tile(tone: tone),
                      ],
                      colors: [
                        for (final sound in folder.sounds)
                          AppTokens.soundColor(sound.colorIndex),
                      ],
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FolderMockScreen(folder: folder),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  _NewFolderCard(onTap: () => _soon('フォルダづくり')),
                ],
              ),
            ),
            const SizedBox(height: 28),
            const _SectionLabel('さいきんの音'),
            const SizedBox(height: 10),
            FutureBuilder<List<ClipAsset>>(
              future: _recent,
              builder: (context, snapshot) {
                final recent = snapshot.data ?? const <ClipAsset>[];
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(height: 120);
                }
                if (recent.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTokens.tile,
                      borderRadius:
                          BorderRadius.circular(AppTokens.tileRadius),
                    ),
                    child: const Text(
                      'まだ音がありません。まんなかのマイクから録ってみよう。',
                      style: TextStyle(color: AppTokens.mutedInk),
                    ),
                  );
                }
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < recent.length; i++)
                        SoundRow(
                          number: i + 1,
                          color: AppTokens.soundColor(i),
                          label: _readableLabel(recent[i].label, i),
                          seconds: recent[i].selectionDurationUs / 1e6,
                          waveform: _waveform(recent[i]),
                          seed: recent[i].id.hashCode,
                          trailing: widget.onAssetSelected == null
                              ? null
                              : IconButton(
                                  tooltip: 'いま集めてる音に入れる',
                                  onPressed: () =>
                                      widget.onAssetSelected!(recent[i]),
                                  icon: const Icon(Icons.add_rounded),
                                ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _readableLabel(String label, int index) =>
    RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(label)
    ? '録った音 ${index + 1}'
    : label;

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

final class _Tile {
  const _Tile({this.image, this.tone});
  final Uint8List? image;
  final Color? tone;
}

final class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.title,
    required this.caption,
    required this.tiles,
    required this.colors,
    required this.onTap,
    this.live = false,
  });

  final String title;
  final String caption;
  final List<_Tile> tiles;
  final List<Color> colors;
  final VoidCallback onTap;
  final bool live;

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
                          ? _tile(tiles[i], i)
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
                child: colors.isEmpty
                    ? Container(color: AppTokens.tile)
                    : Row(
                        children: [
                          for (final color in colors)
                            Expanded(child: Container(color: color)),
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
                if (live) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: AppTokens.blush,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
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

  Widget _tile(_Tile tile, int index) {
    if (tile.image case final bytes?) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) =>
            Container(color: AppTokens.soundColor(index)),
      );
    }
    return Container(color: tile.tone ?? AppTokens.soundColor(index));
  }
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
