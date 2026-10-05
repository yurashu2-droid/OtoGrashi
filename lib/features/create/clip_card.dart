import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import 'clip_range_preview.dart';

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
    required this.onTrim,
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
  final ValueChanged<Future<AudioWaveform>> onTrim;
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
    final contributorParts = title.split(' · ');
    final hasContributor =
        contributorParts.length == 2 &&
        contributorParts.every((part) => part.trim().isNotEmpty);
    final duration =
        '${(widget.selectionDurationUs / 1000000).toStringAsFixed(1)}秒';
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final accent = _clipAccent(index);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: Colors.white,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTokens.tileRadius),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 160 + (textScale - 1).clamp(0, 2) * 56,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
              width: 106,
              height: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.thumbnail != null
                      ? Image.memory(
                          widget.thumbnail!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _ThumbnailFallback(
                                index: index,
                                synthetic:
                                    clip.label.startsWith('synthetic-') ||
                                    clip.label.startsWith('合成素材'),
                              ),
                        )
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
                        borderRadius: BorderRadius.circular(9),
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
                        color: const Color(0xCC333333),
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
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 5),
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
                                      child: hasContributor
                                          ? Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  contributorParts.first,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: accent,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                                Text(
                                                  contributorParts.last,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Text(
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
                        onTap: () => widget.onTrim(_waveform),
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

Color _clipAccent(int index) => AppTokens.soundColor(index);

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
    label: '$clipNameの波形。色のついた範囲を使用します。タップして範囲を選ぶ',
    child: Tooltip(
      message: '$clipNameの使う範囲を選ぶ',
      child: Material(
        color: const Color(0xFFFFFFFF),
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
                  child: const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(3),
                      child: Text(
                        '範囲を選ぶ',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          backgroundColor: Color(0xDDFFF8F1),
                        ),
                      ),
                    ),
                  ),
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
    this.playheadUs,
  });

  final AudioWaveform waveform;
  final int selectionStartUs;
  final int selectionDurationUs;
  final Color accent;
  final int? playheadUs;

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
    if (playheadUs case final position?) {
      final x = (position / waveform.durationUs).clamp(0.0, 1.0) * size.width;
      final playheadPaint = Paint()
        ..color = AppTokens.ink
        ..strokeWidth = 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), playheadPaint);
      canvas.drawCircle(Offset(x, 3), 3, playheadPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ClipWaveformPainter oldDelegate) =>
      oldDelegate.waveform != waveform ||
      oldDelegate.selectionStartUs != selectionStartUs ||
      oldDelegate.selectionDurationUs != selectionDurationUs ||
      oldDelegate.playheadUs != playheadUs ||
      oldDelegate.accent != accent;
}

Future<void> showClipTrimSheet(
  BuildContext context, {
  required ClipAsset clip,
  required Future<AudioWaveform> waveform,
  required MediaPresentationGateway presentation,
  required int selectionStartUs,
  required int selectionDurationUs,
  required Future<void> Function(int startUs, int durationUs) onSave,
  Future<void> Function(int startUs, int durationUs)? onAudition,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ClipTrimSheet(
    clip: clip,
    waveform: waveform,
    presentation: presentation,
    selectionStartUs: selectionStartUs,
    selectionDurationUs: selectionDurationUs,
    onSave: onSave,
    onAudition: onAudition,
  ),
);

class _ClipTrimSheet extends StatefulWidget {
  const _ClipTrimSheet({
    required this.clip,
    required this.waveform,
    required this.presentation,
    required this.selectionStartUs,
    required this.selectionDurationUs,
    required this.onSave,
    this.onAudition,
  });

  final ClipAsset clip;
  final Future<AudioWaveform> waveform;
  final int selectionStartUs;
  final int selectionDurationUs;
  final Future<void> Function(int startUs, int durationUs) onSave;
  final Future<void> Function(int startUs, int durationUs)? onAudition;
  final MediaPresentationGateway presentation;

  @override
  State<_ClipTrimSheet> createState() => _ClipTrimSheetState();
}

class _ClipTrimSheetState extends State<_ClipTrimSheet> {
  late int _startUs = widget.selectionStartUs;
  late int _endUs = widget.selectionStartUs + widget.selectionDurationUs;
  bool _saving = false;
  late final _playhead = ValueNotifier<int>(_startUs);

  @override
  void dispose() {
    _playhead.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxUs = widget.clip.durationUs;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('使う音を選ぶ', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              widget.clip.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            ClipRangePreview(
              clip: widget.clip,
              presentation: widget.presentation,
              startUs: _startUs,
              endUs: _endUs,
              enabled: !_saving,
              onAudition: widget.onAudition,
              positionNotifier: _playhead,
            ),
            const Text('左右のつまみを動かすと、その位置の動画が見られます。'),
            const SizedBox(height: 8),
            SizedBox(
              height: 56,
              child: FutureBuilder<AudioWaveform>(
                future: widget.waveform,
                builder: (context, snapshot) {
                  final waveform = snapshot.data;
                  if (waveform == null) {
                    return Center(
                      child: Text(
                        snapshot.hasError ? '波形を表示できません' : '波形を読み込んでいます…',
                      ),
                    );
                  }
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFFFFF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ValueListenableBuilder<int>(
                      valueListenable: _playhead,
                      builder: (context, positionUs, _) => Semantics(
                        label:
                            '波形上の動画位置 ${(positionUs / 1e6).toStringAsFixed(1)}秒',
                        child: CustomPaint(
                          key: const ValueKey('trim-waveform-playhead'),
                          painter: _ClipWaveformPainter(
                            waveform: waveform,
                            selectionStartUs: _startUs,
                            selectionDurationUs: _endUs - _startUs,
                            accent: AppTokens.coral,
                            playheadUs: positionUs,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            RangeSlider(
              values: RangeValues(_startUs.toDouble(), _endUs.toDouble()),
              min: 0,
              max: maxUs.toDouble(),
              labels: RangeLabels(
                '${(_startUs / 1e6).toStringAsFixed(1)}秒',
                '${(_endUs / 1e6).toStringAsFixed(1)}秒',
              ),
              onChanged: _saving
                  ? null
                  : (values) => setState(() {
                      final start = values.start.round().clamp(0, maxUs - 1);
                      final end = values.end.round().clamp(start + 1, maxUs);
                      _startUs = start;
                      _endUs = end - start > 6000000 ? start + 6000000 : end;
                    }),
            ),
            FutureBuilder<AudioWaveform>(
              future: widget.waveform,
              builder: (context, snapshot) {
                final suggestedStart = snapshot.data?.strongestWindowStart(
                  _endUs - _startUs,
                );
                if (suggestedStart == null || suggestedStart == _startUs) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                            final durationUs = _endUs - _startUs;
                            _startUs = suggestedStart.clamp(
                              0,
                              maxUs - durationUs,
                            );
                            _endUs = _startUs + durationUs;
                          }),
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    label: const Text('大きい音へ移動'),
                  ),
                );
              },
            ),
            Text(
              '開始 ${(_startUs / 1e6).toStringAsFixed(1)}秒 ・ 終了 ${(_endUs / 1e6).toStringAsFixed(1)}秒\n${((_endUs - _startUs) / 1e6).toStringAsFixed(1)}秒を使う',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving
                  ? null
                  : () async {
                      setState(() => _saving = true);
                      try {
                        await widget.onSave(_startUs, _endUs - _startUs);
                        if (context.mounted) Navigator.pop(context);
                      } catch (_) {
                        if (!context.mounted) return;
                        setState(() => _saving = false);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('範囲を保存できませんでした。もう一度お試しください。'),
                          ),
                        );
                      }
                    },
              child: const Text('この範囲を使う'),
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
