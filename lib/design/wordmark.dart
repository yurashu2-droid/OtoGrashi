import 'package:flutter/material.dart';

import 'tokens.dart';

/// The hand-written "otogurashi." signature for the top-left of Home.
/// Uses iOS's built-in handwriting faces, so no font file ships with the app.
final class OtoWordmark extends StatelessWidget {
  const OtoWordmark({this.size = 34, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    label: 'オトグラシ',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          'otogurashi',
          style: TextStyle(
            fontFamily: 'Bradley Hand',
            fontFamilyFallback: const ['Noteworthy', 'Snell Roundhand'],
            fontSize: size,
            fontWeight: FontWeight.w700,
            height: 1,
            letterSpacing: -0.5,
            color: AppTokens.ink,
          ),
        ),
        // the full stop is a small pale-red dot, the one accent
        Padding(
          padding: EdgeInsets.only(left: size * 0.06, bottom: size * 0.12),
          child: Container(
            width: size * 0.16,
            height: size * 0.16,
            decoration: const BoxDecoration(
              color: AppTokens.blush,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    ),
  );
}
