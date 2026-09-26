import 'package:flutter/material.dart';

import '../../design/pressable.dart';
import '../../design/tokens.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    required this.onCreate,
    this.busy = false,
    this.error,
    this.initialName,
    super.key,
  });

  /// Starts creating; the name (possibly empty) goes on every video's cover.
  final ValueChanged<String> onCreate;
  final bool busy;
  final String? error;
  final String? initialName;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );

  bool get busy => widget.busy;
  String? get error => widget.error;

  void onCreate() => widget.onCreate(_name.text);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(AppTokens.pagePadding),
        children: [
          const SizedBox(height: 64),
          AspectRatio(
            aspectRatio: 1.54,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.asset(
                'assets/art/onboarding-moments-v1.webp',
                fit: BoxFit.cover,
                semanticLabel: '友達の笑顔、キーボード、コップの動画が重なるイメージ',
              ),
            ),
          ),
          const SizedBox(height: 38),
          Text(
            'いつもの一瞬が、\n曲になる。',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const SizedBox(height: 14),
          Text(
            '友達の「わっ！」も、タイピングの音も。何気ない3つの動画が重なって、15秒の曲になります。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _name,
            maxLength: 12,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'あなたの名前',
              hintText: 'ゆうた',
              helperText: '動画の最初に「〇〇の日常」と出ます。あとで空欄でもOK。',
              counterText: '',
            ),
          ),
          const SizedBox(height: 20),
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
          const Text('今撮っても、写真から選んでもOK。', textAlign: TextAlign.center),
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
