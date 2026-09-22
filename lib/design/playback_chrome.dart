import 'package:flutter/material.dart';

class PlaybackChrome extends StatelessWidget {
  const PlaybackChrome({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF3A383F), Color(0xFF1D1C21), Color(0xFF2A282E)],
        stops: [0, 0.18, 1],
      ),
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x3D000000),
          blurRadius: 24,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 18),
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
    ),
  );
}
