import 'package:flutter/material.dart';

class PlaybackChrome extends StatelessWidget {
  const PlaybackChrome({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xFFFBF4EA),
      border: Border.all(color: const Color(0xFFE8DCCB)),
      borderRadius: BorderRadius.circular(18),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1F32251F),
          blurRadius: 18,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.all(5),
      child: ClipRRect(borderRadius: BorderRadius.circular(13), child: child),
    ),
  );
}
