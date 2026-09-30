import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../media/media_presentation_gateway.dart';

/// One sound in a list: numbered colour badge, name, and its waveform drawn
/// in the sound's own colour.
final class SoundRow extends StatelessWidget {
  const SoundRow({
    required this.number,
    required this.color,
    required this.label,
    required this.seconds,
    required this.seed,
    this.waveform,
    this.thumbnail,
    this.trailing,
    this.caption,
    super.key,
  });

  final int number;
  final Color color;
  final String label;
  final double seconds;
  final int seed;
  final Future<AudioWaveform>? waveform;

  /// The recording's frame; without one the row shows a numbered dot.
  final Future<Uint8List>? thumbnail;
  final Widget? trailing;
  final String? caption;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
    child: Row(
      children: [
        if (thumbnail != null)
          SoundThumb(thumbnail: thumbnail, color: color, number: number)
        else
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: AppTokens.ink,
                      ),
                    ),
                  ),
                  Text(
                    caption ?? '${seconds.toStringAsFixed(1)}秒',
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
                      levels: snapshot.data?.levels ?? pseudoLevels(seed),
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (trailing case final trailing?) trailing else const SizedBox(width: 8),
      ],
    ),
  );
}

/// A stable stand-in waveform for sounds whose real levels are not loaded.
List<double> pseudoLevels(int seed, [int count = 40]) {
  var x = seed.abs() % 233280;
  return List<double>.generate(count, (i) {
    x = (x * 9301 + 49297) % 233280;
    final envelope = math.sin(math.pi * (i + 0.5) / count);
    return (0.25 + 0.75 * (x / 233280)) * (0.35 + 0.65 * envelope);
  });
}

final class SoundBarsPainter extends CustomPainter {
  const SoundBarsPainter({required this.levels, required this.color});

  final List<double> levels;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0) return;
    const bars = 40;
    final step = size.width / bars;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.5, step * 0.5);
    for (var i = 0; i < bars; i++) {
      final level = levels[(i * levels.length / bars).floor()];
      final h = math.max(2.0, level * size.height);
      final x = step * (i + 0.5);
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(SoundBarsPainter oldDelegate) =>
      oldDelegate.color != color || !identical(oldDelegate.levels, levels);
}

/// A sound's photo with its number badge in the sound's colour.
final class SoundThumb extends StatelessWidget {
  const SoundThumb({
    required this.thumbnail,
    required this.color,
    required this.number,
    this.size = 44,
    super.key,
  });

  final Future<Uint8List>? thumbnail;
  final Color color;
  final int number;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.24),
            child: FutureBuilder<Uint8List>(
              future: thumbnail,
              builder: (context, snapshot) => snapshot.hasData
                  ? Image.memory(
                      snapshot.data!,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          ColoredBox(color: color.withValues(alpha: 0.35)),
                    )
                  : ColoredBox(color: color.withValues(alpha: 0.35)),
            ),
          ),
        ),
        Positioned(
          left: -4,
          top: -4,
          child: Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A user tag on a sound ("海", "1日目"…).
final class SoundTagChip extends StatelessWidget {
  const SoundTagChip(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: AppTokens.surfaceColor,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: AppTokens.hairline),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        color: AppTokens.mutedInk,
      ),
    ),
  );
}
