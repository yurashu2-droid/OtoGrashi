import 'package:flutter/material.dart';

class ClipboardChrome extends StatelessWidget {
  const ClipboardChrome({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFFCF3), Color(0xFFF6E9D2)],
      ),
      borderRadius: BorderRadius.circular(28),
      boxShadow: const [
        BoxShadow(
          color: Color(0x180E0718),
          blurRadius: 28,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 32, 14, 14),
          child: child,
        ),
        Positioned(
          top: -8,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              width: 112,
              height: 34,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFFB9B2B8),
                    Color(0xFFF1EEF0),
                    Color(0xFF8C858B),
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF6F686D), width: 1.5),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x44000000),
                    blurRadius: 5,
                    offset: Offset(0, 3),
                  ),
                  BoxShadow(
                    color: Color(0xAAFFFFFF),
                    blurRadius: 1,
                    offset: Offset(0, -1),
                  ),
                ],
              ),
              child: Center(
                child: Container(
                  width: 62,
                  height: 8,
                  decoration: BoxDecoration(
                    color: const Color(0xFF696268),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
