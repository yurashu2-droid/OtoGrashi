import 'package:flutter/material.dart';

class CaptureChrome extends StatelessWidget {
  const CaptureChrome({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(16) > 21;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        IgnorePointer(
          child: CustomPaint(
            painter: _CaptureChromePainter(compact: largeText),
          ),
        ),
      ],
    );
  }
}

class _CaptureChromePainter extends CustomPainter {
  const _CaptureChromePainter({required this.compact});
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final lidHeight = compact ? 34.0 : 58.0;
    final rimHeight = compact ? 38.0 : 66.0;
    final lid = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFA4A474E), Color(0xFA1C1B20)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, lidHeight));
    final inner = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF111014), Color(0xFF403D44), Color(0xFF17161A)],
      ).createShader(Rect.fromLTWH(30, lidHeight - 21, size.width - 60, 20));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(-12, -16, size.width + 24, lidHeight + 16),
        const Radius.elliptical(42, 24),
      ),
      lid,
    );
    canvas.drawOval(
      Rect.fromLTWH(30, lidHeight - 19, size.width - 60, 17),
      inner,
    );
    canvas.drawOval(
      Rect.fromLTWH(54, lidHeight - 15, size.width - 108, 8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = const Color(0x886D6871),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, 8),
          width: 50,
          height: 18,
        ),
        const Radius.circular(7),
      ),
      Paint()..color = const Color(0xFF111014),
    );
    final rimRect = Rect.fromLTWH(
      -18,
      size.height - rimHeight,
      size.width + 36,
      rimHeight + 24,
    );
    canvas.drawOval(
      rimRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFFFEBD0), Color(0xFFE7D3B7)],
        ).createShader(rimRect),
    );
    canvas.drawOval(
      Rect.fromLTWH(
        9,
        size.height - rimHeight + 9,
        size.width - 18,
        rimHeight - 5,
      ),
      Paint()..color = const Color(0xFF6A3424),
    );
    canvas.drawArc(
      Rect.fromLTWH(
        18,
        size.height - rimHeight + 11,
        size.width - 36,
        rimHeight - 10,
      ),
      3.35,
      2.72,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = const Color(0x88FFFFFF),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - 18, size.width, 18),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFF4E3), Color(0xFFEBD7BC)],
        ).createShader(Rect.fromLTWH(0, size.height - 18, size.width, 18)),
    );
  }

  @override
  bool shouldRepaint(covariant _CaptureChromePainter oldDelegate) =>
      oldDelegate.compact != compact;
}
