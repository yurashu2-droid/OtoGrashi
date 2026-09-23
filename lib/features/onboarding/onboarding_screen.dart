import 'package:flutter/material.dart';

import '../../design/pressable.dart';
import '../../design/tokens.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({
    required this.onCreate,
    this.busy = false,
    this.error,
    super.key,
  });

  final VoidCallback onCreate;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        children: [
          const SizedBox(height: 64),
          Container(
            height: 220,
            decoration: BoxDecoration(
              color: const Color(0xFFFFE6DC),
              borderRadius: BorderRadius.circular(36),
            ),
            child: const Stack(
              children: [
                Positioned(left: 32, top: 36, child: _SoundDot(size: 48)),
                Positioned(right: 44, top: 68, child: _SoundDot(size: 72)),
                Positioned(left: 96, bottom: 28, child: _SoundDot(size: 88)),
                Center(child: Icon(Icons.graphic_eq_rounded, size: 82)),
              ],
            ),
          ),
          const SizedBox(height: 38),
          Text(
            '暮らしの音が、\n15秒の音楽になる。',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const SizedBox(height: 14),
          Text(
            'コップ、蛇口、キーボード。3つの短い動画から、音と映像をつなぎます。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 32),
          Pressable(
            enabled: !busy,
            onPressed: onCreate,
            semanticLabel: '自分の音でつくる',
            child: _ButtonSurface(
              filled: true,
              label: busy ? '準備中…' : '自分の音でつくる',
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '撮影した動画を3つ選んで、あなただけの音楽をつくろう。',
            textAlign: TextAlign.center,
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ButtonSurface extends StatelessWidget {
  const _ButtonSurface({required this.label, this.filled = false});
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    constraints: const BoxConstraints(minHeight: 56),
    decoration: BoxDecoration(
      color: filled
          ? Theme.of(context).colorScheme.primary
          : Colors.transparent,
      border: Border.all(color: Theme.of(context).colorScheme.primary),
      borderRadius: BorderRadius.circular(28),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: filled
            ? Theme.of(context).colorScheme.onPrimary
            : Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _SoundDot extends StatelessWidget {
  const _SoundDot({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: size > 80 ? const Color(0xFFB9A0FF) : const Color(0xFFFF8C7E),
      shape: BoxShape.circle,
    ),
  );
}
