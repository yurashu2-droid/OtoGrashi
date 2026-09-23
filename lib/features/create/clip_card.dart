import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';

enum _ClipAction { moveUp, moveDown }

/// A recorded sound stays identifiable even when the list gets long.
class ClipCard extends StatelessWidget {
  const ClipCard({
    required this.clip,
    required this.index,
    required this.thumbnail,
    required this.onPreview,
    required this.onRename,
    required this.onMove,
    required this.onRemove,
    required this.canMoveDown,
    super.key,
  });

  final ClipAsset clip;
  final int index;
  final Uint8List? thumbnail;
  final VoidCallback onPreview;
  final VoidCallback onRename;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;
  final bool canMoveDown;

  @override
  Widget build(BuildContext context) {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    final title = generatedName ? '録った音 ${index + 1}' : clip.label;
    final duration =
        '${(clip.selectionDurationUs / 1000000).toStringAsFixed(1)}秒';
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE9DDD4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 136 + (textScale - 1).clamp(0, 2) * 56,
        child: Row(
          children: [
            SizedBox(
              width: 112,
              height: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  thumbnail != null
                      ? Image.memory(thumbnail!, fit: BoxFit.cover)
                      : _ThumbnailFallback(
                          index: index,
                          synthetic:
                              clip.label.startsWith('synthetic-') ||
                              clip.label.startsWith('合成素材'),
                        ),
                  Material(
                    color: const Color(0x22000000),
                    child: InkWell(
                      onTap: onPreview,
                      child: const Center(
                        child: Icon(
                          Icons.play_circle_fill_rounded,
                          color: Colors.white,
                          size: 42,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 7,
                    top: 7,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTokens.paper,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        child: Text(
                          '${index + 1}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: onRename,
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  const Icon(Icons.edit_outlined, size: 16),
                                ],
                              ),
                            ),
                          ),
                        ),
                        PopupMenuButton<_ClipAction>(
                          tooltip: '$titleの順番を変える',
                          icon: const Icon(Icons.more_horiz_rounded),
                          onSelected: (action) => switch (action) {
                            _ClipAction.moveUp => onMove(-1),
                            _ClipAction.moveDown => onMove(1),
                          },
                          itemBuilder: (_) => [
                            if (index > 0)
                              const PopupMenuItem(
                                value: _ClipAction.moveUp,
                                child: Text('ひとつ前へ'),
                              ),
                            if (canMoveDown)
                              const PopupMenuItem(
                                value: _ClipAction.moveDown,
                                child: Text('ひとつ後ろへ'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    Text(
                      duration,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: onPreview,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('聴く'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(48, 44),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: onRemove,
                          tooltip: '$titleを作品から外す',
                          icon: const Icon(Icons.delete_outline_rounded),
                          color: AppTokens.mutedInk,
                        ),
                      ],
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
}

class _ThumbnailFallback extends StatelessWidget {
  const _ThumbnailFallback({required this.index, required this.synthetic});
  final int index;
  final bool synthetic;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: index.isEven
            ? const [Color(0xFF9A83C4), Color(0xFF6E5A94)]
            : const [Color(0xFFE89586), Color(0xFFB86562)],
      ),
    ),
    child: Center(
      child: Icon(
        synthetic ? Icons.graphic_eq_rounded : Icons.broken_image_outlined,
        size: 40,
        color: Colors.white70,
      ),
    ),
  );
}
