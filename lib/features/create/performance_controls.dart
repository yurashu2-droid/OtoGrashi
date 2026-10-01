import 'package:flutter/material.dart';

import '../../domain/arrangement.dart';
import '../../design/tokens.dart';

class PerformanceControls extends StatelessWidget {
  const PerformanceControls({
    super.key,
    required this.mode,
    required this.seconds,
    required this.onMode,
    required this.onDuration,
  });
  final PerformanceMode mode;
  final int seconds;
  final ValueChanged<PerformanceMode> onMode;
  final ValueChanged<int> onDuration;
  static const labels = {
    PerformanceMode.mad: (
      'MAD（おすすめ）',
      Icons.graphic_eq_rounded,
      '声を1音ずつ歌わせて、連打・スクラッチ・分身で曲にする。',
    ),
    PerformanceMode.collect: (
      'あつめる',
      Icons.collections_rounded,
      '音が1つずつ登場して集まり、ビートに積み上がってから曲になる。',
    ),
    PerformanceMode.natural: (
      '原声を楽しむ',
      Icons.record_voice_over_rounded,
      '言葉の続きを残して、自然に音程が変わる。',
    ),
    PerformanceMode.mosaic: (
      'どんどん増殖',
      Icons.grid_view_rounded,
      '左上から思い出が増える。連打→セリフ→余韻。',
    ),
    PerformanceMode.vinyl: (
      '声レコード',
      Icons.album_rounded,
      '丸い動画が回る。声も前後にスクラッチ。',
    ),
    PerformanceMode.sampler: (
      'サンプラー',
      Icons.apps_rounded,
      '鳴るパッドが跳ねる。色枠と円形ビジュアライザー。',
    ),
    PerformanceMode.voiceLead: (
      'メロディ＋会話',
      Icons.forum_rounded,
      '同じ声のメロディを背景に、長いリアクションが主役。',
    ),
    PerformanceMode.neonTune: (
      '虹色チューン',
      Icons.auto_awesome_rounded,
      'このモードだけ強めの音程切替。虹色にゆがむ。',
    ),
    PerformanceMode.loopStation: (
      'ループ育成',
      Icons.layers_rounded,
      'ビート→ベース→メロディ。音と動画を積み上げる。',
    ),
  };
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Text(
                'つくり方',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                  color: AppTokens.mutedInk,
                ),
              ),
            ),
            for (final (value, label) in const [(15, '15秒'), (30, '30秒・展開あり')])
              _LengthPill(
                label: label,
                selected: seconds == value,
                onTap: () => onDuration(value),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // one sliding row of modes keeps the screen short
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              for (final option in PerformanceMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(labels[option]!.$1),
                    avatar: Icon(
                      labels[option]!.$2,
                      size: 17,
                      color: mode == option ? Colors.white : AppTokens.ink,
                    ),
                    selected: mode == option,
                    onSelected: (_) => onMode(option),
                    shape: const StadiumBorder(),
                    side: BorderSide.none,
                    backgroundColor: AppTokens.tile,
                    selectedColor: AppTokens.ink,
                    showCheckmark: false,
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: mode == option ? Colors.white : AppTokens.ink,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(labels[mode]!.$3, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

final class _LengthPill extends StatelessWidget {
  const _LengthPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppTokens.ink : AppTokens.tile,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: selected ? Colors.white : AppTokens.ink,
          ),
        ),
      ),
    ),
  );
}
