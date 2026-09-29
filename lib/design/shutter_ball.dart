import 'package:flutter/material.dart';

import 'rolling_tab_bar.dart';
import 'tokens.dart';

/// Hero tag shared by the tab bar's mic ball and the capture shutter.
const captureShutterTag = 'capture-shutter';

enum ShutterMode { mic, busy, stop }

/// The round capture button. It fills whatever square it is given, so the
/// same widget reads as the tab bar ball and as the larger shutter.
final class ShutterBall extends StatelessWidget {
  const ShutterBall({this.mode = ShutterMode.mic, super.key});

  final ShutterMode mode;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest.shortestSide;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: mode == ShutterMode.stop ? AppTokens.ink : AppTokens.blush,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Color(0x33F08F89),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: switch (mode) {
          ShutterMode.mic => CustomPaint(
            size: Size.square(size * 0.42),
            painter: const TabIconPainter(
              tab: RollingTab.capture,
              color: Colors.white,
              progress: 1,
            ),
          ),
          ShutterMode.stop => Container(
            width: size * 0.3,
            height: size * 0.3,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(size * 0.06),
            ),
          ),
          ShutterMode.busy => SizedBox.square(
            dimension: size * 0.32,
            child: const CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Colors.white,
            ),
          ),
        },
      );
    },
  );
}
