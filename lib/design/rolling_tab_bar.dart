import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'shutter_ball.dart';
import 'tokens.dart';

enum RollingTab { home, capture, songs }

/// Floating pill tab bar whose dark ball rolls one full turn per slot to the
/// tapped tab, lands with a small squash, and redraws the tab's icon inside.
/// The ball turns pale red on the capture tab.
class RollingTabBar extends StatefulWidget {
  const RollingTabBar({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final RollingTab selected;
  final ValueChanged<RollingTab> onSelected;

  static const barHeight = 80.0;

  @override
  State<RollingTabBar> createState() => _RollingTabBarState();
}

class _RollingTabBarState extends State<RollingTabBar>
    with SingleTickerProviderStateMixin {
  static const _pillWidth = 300.0;
  static const _pillHeight = 68.0;
  static const _ball = 52.0;
  static const _slots = [32.0, 124.0, 216.0];
  static const _labels = ['ホーム', '録る', '曲'];
  static const _ghostInk = Color(0xFFB5B5B5);
  static const _roll = Cubic(0.45, 0.05, 0.3, 1.15);

  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
    value: 1,
  );
  late int _from = widget.selected.index;
  late int _to = widget.selected.index;
  double _fromX = 0;
  double _spinFrom = 0;
  double _spinTo = 0;

  @override
  void initState() {
    super.initState();
    _fromX = _slots[_to];
  }

  @override
  void didUpdateWidget(RollingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.selected.index;
    if (next == _to) return;
    // start from wherever the ball is right now, so quick taps chain smoothly
    _fromX = _ballX(_motion.value);
    _spinFrom = _spin(_motion.value);
    _spinTo = _spinTo + (next - _to) * math.pi * 2;
    _from = _to;
    _to = next;
    _motion.forward(from: 0);
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  double _ballX(double t) =>
      _lerp(_fromX, _slots[_to], _roll.transform(t));

  double _spin(double t) =>
      _lerp(_spinFrom, _spinTo, _roll.transform(t));

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  Color _ballColor(int index) =>
      index == RollingTab.capture.index ? AppTokens.blush : AppTokens.barInk;

  // Parked on 録る, the ball is the same object as the capture screen's
  // shutter, so it flies there and grows when the camera opens.
  Widget _heroWhenCapture(Widget ball) => _to == RollingTab.capture.index
      ? Hero(tag: captureShutterTag, child: ball)
      : ball;

  // landing squash: flat, then tall, then settled
  Offset _squash(double t) {
    const keys = [
      (0.55, 1.0, 1.0),
      (0.70, 1.18, 0.8),
      (0.84, 0.93, 1.08),
      (1.0, 1.0, 1.0),
    ];
    if (_from == _to || t <= keys.first.$1) return const Offset(1, 1);
    for (var k = 1; k < keys.length; k++) {
      final (t1, x1, y1) = keys[k];
      if (t <= t1) {
        final (t0, x0, y0) = keys[k - 1];
        final f = Curves.easeInOut.transform((t - t0) / (t1 - t0));
        return Offset(_lerp(x0, x1, f), _lerp(y0, y1, f));
      }
    }
    return const Offset(1, 1);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: RollingTabBar.barHeight,
    child: Center(
      child: Container(
        width: _pillWidth,
        height: _pillHeight,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 30,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < 3; i++)
              Positioned(
                left: _slots[i],
                top: (_pillHeight - _ball) / 2,
                width: _ball,
                height: _ball,
                child: AnimatedScale(
                  scale: i == _to ? 0.4 : 1,
                  duration: const Duration(milliseconds: 450),
                  curve: i == _to ? Curves.easeIn : Curves.easeOutBack,
                  child: AnimatedOpacity(
                    opacity: i == _to ? 0 : 1,
                    duration: const Duration(milliseconds: 220),
                    child: Center(
                      child: CustomPaint(
                        size: const Size.square(22),
                        painter: TabIconPainter(
                          tab: RollingTab.values[i],
                          color: _ghostInk,
                          progress: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            AnimatedBuilder(
              animation: _motion,
              builder: (context, _) {
                final t = _motion.value;
                final squash = _squash(t);
                final colorT = ((t - 0.4) / 0.5).clamp(0.0, 1.0);
                final color = Color.lerp(
                  _ballColor(_from),
                  _ballColor(_to),
                  Curves.easeInOut.transform(colorT),
                )!;
                final moving = _from != _to;
                final oldOpacity = moving ? (1 - t / 0.24).clamp(0.0, 1.0) : 0.0;
                final draw = moving
                    ? Curves.easeOut.transform(((t - 0.5) / 0.5).clamp(0.0, 1.0))
                    : 1.0;
                return Positioned(
                  left: _ballX(t),
                  top: (_pillHeight - _ball) / 2,
                  width: _ball,
                  height: _ball,
                  child: IgnorePointer(
                    child: Transform(
                      alignment: Alignment.bottomCenter,
                      transform: Matrix4.diagonal3Values(
                        squash.dx,
                        squash.dy,
                        1,
                      ),
                      child: Transform.rotate(
                        angle: _spin(t),
                        child: _heroWhenCapture(DecoratedBox(
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (oldOpacity > 0)
                                Opacity(
                                  opacity: oldOpacity,
                                  child: CustomPaint(
                                    size: const Size.square(22),
                                    painter: TabIconPainter(
                                      tab: RollingTab.values[_from],
                                      color: Colors.white,
                                      progress: 1,
                                    ),
                                  ),
                                ),
                              CustomPaint(
                                size: const Size.square(22),
                                painter: TabIconPainter(
                                  tab: RollingTab.values[_to],
                                  color: Colors.white,
                                  progress: draw,
                                ),
                              ),
                            ],
                          ),
                        )),
                      ),
                    ),
                  ),
                );
              },
            ),
            for (var i = 0; i < 3; i++)
              Positioned(
                left: _slots[i] - 12,
                top: 0,
                width: _ball + 24,
                height: _pillHeight,
                child: Semantics(
                  button: true,
                  selected: i == _to,
                  label: _labels[i],
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onSelected(RollingTab.values[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Stroke icon for a tab on the 24px grid; [progress] < 1 draws it partway.
class TabIconPainter extends CustomPainter {
  const TabIconPainter({
    required this.tab,
    required this.color,
    required this.progress,
  });

  final RollingTab tab;
  final Color color;
  final double progress;

  static Path _icon(RollingTab tab) => switch (tab) {
    RollingTab.home => Path()
      ..moveTo(4, 11)
      ..lineTo(12, 4)
      ..lineTo(20, 11)
      ..lineTo(20, 20)
      ..lineTo(15, 20)
      ..lineTo(15, 14)
      ..lineTo(9, 14)
      ..lineTo(9, 20)
      ..lineTo(4, 20)
      ..close(),
    RollingTab.capture => Path()
      ..addRRect(
        RRect.fromLTRBR(8.5, 3, 15.5, 15, const Radius.circular(3.5)),
      )
      ..addArc(
        Rect.fromCircle(center: const Offset(12, 11), radius: 7),
        math.pi,
        -math.pi,
      )
      ..moveTo(12, 18)
      ..lineTo(12, 21),
    RollingTab.songs => Path()
      ..moveTo(9, 18)
      ..lineTo(9, 6)
      ..lineTo(19, 4)
      ..lineTo(19, 16)
      ..addOval(Rect.fromCircle(center: const Offset(6.5, 18), radius: 2.5))
      ..addOval(Rect.fromCircle(center: const Offset(16.5, 16), radius: 2.5)),
  };

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final scale = size.width / 24;
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = _icon(tab);
    if (progress >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // redraw the icon stroke by stroke, like a pen tracing it
    final metrics = path.computeMetrics().toList();
    final total = metrics.fold<double>(0, (sum, m) => sum + m.length);
    var remaining = total * progress;
    for (final metric in metrics) {
      if (remaining <= 0) break;
      canvas.drawPath(
        metric.extractPath(0, math.min(metric.length, remaining)),
        paint,
      );
      remaining -= metric.length;
    }
  }

  @override
  bool shouldRepaint(TabIconPainter oldDelegate) =>
      oldDelegate.tab != tab ||
      oldDelegate.color != color ||
      oldDelegate.progress != progress;
}
