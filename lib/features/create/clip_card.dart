import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';

enum _ClipAction { moveUp, moveDown }

/// A recorded sound stays identifiable even when the list gets long.
class ClipCard extends StatefulWidget {
  const ClipCard({
    required this.clip,
    required this.index,
    required this.thumbnail,
    required this.presentation,
    required this.selectionStartUs,
    required this.selectionDurationUs,
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
  final MediaPresentationGateway presentation;
  final int selectionStartUs;
  final int selectionDurationUs;
  final VoidCallback onPreview;
  final VoidCallback onRename;
  final ValueChanged<int> onMove;
  final VoidCallback onRemove;
  final bool canMoveDown;

  @override
  State<ClipCard> createState() => _ClipCardState();
}

class _ClipCardState extends State<ClipCard> {
  late Future<AudioWaveform> _waveform = _requestWaveform();

  Future<AudioWaveform> _requestWaveform() {
    try {
      return widget.presentation.waveform(widget.clip.relativePath);
    } catch (error, stackTrace) {
      return Future<AudioWaveform>.error(error, stackTrace);
    }
  }

  @override
  void didUpdateWidget(covariant ClipCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presentation != widget.presentation ||
        oldWidget.clip.relativePath != widget.clip.relativePath) {
      _waveform = _requestWaveform();
    }
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final index = widget.index;
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    final title = generatedName ? '録った音 ${index + 1}' : clip.label;
    final duration =
        '${(widget.selectionDurationUs / 1000000).toStringAsFixed(1)}秒';
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final accent = _clipAccent(index);
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      color: const Color(0xFFFFFEFB),
      elevation: 2,
      shadowColor: const Color(0x228D6B5B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE7DCD2)),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 160 + (textScale - 1).clamp(0, 2) * 56,
        child: Row(
          children: [
            SizedBox(
              width: 122,
              height: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.thumbnail != null
                      ? Image.memory(widget.thumbnail!, fit: BoxFit.cover)
                      : _ThumbnailFallback(
                          index: index,
                          synthetic:
                              clip.label.startsWith('synthetic-') ||
                              clip.label.startsWith('合成素材'),
                        ),
                  Material(
                    color: const Color(0x11000000),
                    child: InkWell(
                      onTap: widget.onPreview,
                      child: const Align(
                        alignment: Alignment.bottomLeft,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 38,
                            shadows: [
                              Shadow(color: Color(0x77000000), blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: 27,
                        height: 27,
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 7,
                    bottom: 11,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xCC211C1A),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        child: Text(
                          duration,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
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
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 48),
                            child: InkWell(
                              onTap: widget.onRename,
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
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
                        ),
                        if (index > 0 || widget.canMoveDown)
                          PopupMenuButton<_ClipAction>(
                            tooltip: '$titleの順番を変える',
                            icon: const Icon(Icons.more_horiz_rounded),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onSelected: (action) => switch (action) {
                              _ClipAction.moveUp => widget.onMove(-1),
                              _ClipAction.moveDown => widget.onMove(1),
                            },
                            itemBuilder: (_) => [
                              if (index > 0)
                                const PopupMenuItem(
                                  value: _ClipAction.moveUp,
                                  child: Text('ひとつ前へ'),
                                ),
                              if (widget.canMoveDown)
                                const PopupMenuItem(
                                  value: _ClipAction.moveDown,
                                  child: Text('ひとつ後ろへ'),
                                ),
                            ],
                          ),
                      ],
                    ),
                    Container(
                      width: 30,
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 7),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Expanded(
                      child: _ClipWaveform(
                        key: ValueKey('clip-waveform-${clip.id}'),
                        painterKey: ValueKey(
                          'clip-waveform-painter-${clip.id}',
                        ),
                        future: _waveform,
                        clipName: title,
                        selectionStartUs: widget.selectionStartUs,
                        selectionDurationUs: widget.selectionDurationUs,
                        accent: accent,
                        onTap: widget.onPreview,
                      ),
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: widget.onPreview,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('聴く'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(48, 44),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: widget.onRemove,
                          tooltip: '$titleを作品から外す',
                          icon: const Icon(Icons.delete_outline_rounded),
                          color: AppTokens.mutedInk,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
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

Color _clipAccent(int index) => switch (index % 3) {
  0 => AppTokens.coral,
  1 => const Color(0xFF9B78C8),
  _ => const Color(0xFFE9A347),
};

class _ClipWaveform extends StatelessWidget {
  const _ClipWaveform({
    required this.future,
    required this.clipName,
    required this.selectionStartUs,
    required this.selectionDurationUs,
    required this.accent,
    required this.onTap,
    required this.painterKey,
    super.key,
  });

  final Future<AudioWaveform> future;
  final String clipName;
  final int selectionStartUs;
  final int selectionDurationUs;
  final Color accent;
  final VoidCallback onTap;
  final Key painterKey;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '$clipNameの波形。色のついた範囲を使用します。タップして聴く',
    child: Tooltip(
      message: '$clipNameを聴く',
      child: Material(
        color: const Color(0xFFFFF8F1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
          side: BorderSide(color: accent.withValues(alpha: 0.2)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox.expand(
            child: FutureBuilder<AudioWaveform>(
              future: future,
              builder: (context, snapshot) {
                final waveform =
                    snapshot.connectionState == ConnectionState.done
                    ? snapshot.data
                    : null;
                if (waveform == null) {
                  return Center(
                    child: snapshot.hasError
                        ? Text(
                            '波形を表示できません',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          )
                        : SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: accent,
                            ),
                          ),
                  );
                }
                return CustomPaint(
                  key: painterKey,
                  painter: _ClipWaveformPainter(
                    waveform: waveform,
                    selectionStartUs: selectionStartUs,
                    selectionDurationUs: selectionDurationUs,
                    accent: accent,
                  ),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}

class _ClipWaveformPainter extends CustomPainter {
  const _ClipWaveformPainter({
    required this.waveform,
    required this.selectionStartUs,
    required this.selectionDurationUs,
    required this.accent,
  });

  final AudioWaveform waveform;
  final int selectionStartUs;
  final int selectionDurationUs;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rangeStart =
        (selectionStartUs / waveform.durationUs).clamp(0.0, 1.0) * size.width;
    final rangeEnd =
        ((selectionStartUs + selectionDurationUs) / waveform.durationUs).clamp(
          0.0,
          1.0,
        ) *
        size.width;
    final range = Rect.fromLTRB(rangeStart, 0, rangeEnd, size.height);
    canvas.drawRect(range, Paint()..color = accent.withValues(alpha: 0.08));

    final slotWidth = size.width / waveform.levels.length;
    final barWidth = (slotWidth * 0.66).clamp(1.0, 3.0).toDouble();
    final maxBarHeight = size.height * 0.72;
    for (var index = 0; index < waveform.levels.length; index++) {
      final centerX = (index + 0.5) * slotWidth;
      final centerUs =
          (index + 0.5) * waveform.durationUs / waveform.levels.length;
      final selected =
          centerUs >= selectionStartUs &&
          centerUs <= selectionStartUs + selectionDurationUs;
      final amplitude = waveform.levels[index];
      final barHeight = 1.5 + amplitude * (maxBarHeight - 1.5);
      final rect = Rect.fromCenter(
        center: Offset(centerX, size.height / 2),
        width: barWidth,
        height: barHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)),
        Paint()
          ..color = selected
              ? accent
              : AppTokens.mutedInk.withValues(alpha: 0.32),
      );
    }

    final handlePaint = Paint()
      ..color = accent
      ..strokeWidth = 1.25;
    for (final x in [rangeStart, rangeEnd]) {
      canvas.drawLine(Offset(x, 4), Offset(x, size.height - 4), handlePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ClipWaveformPainter oldDelegate) =>
      oldDelegate.waveform != waveform ||
      oldDelegate.selectionStartUs != selectionStartUs ||
      oldDelegate.selectionDurationUs != selectionDurationUs ||
      oldDelegate.accent != accent;
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
