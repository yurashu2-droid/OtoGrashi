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
        const Text(
          '音と映像のあそび方',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 7,
          runSpacing: 6,
          children: [
            for (final option in PerformanceMode.values)
              ChoiceChip(
                label: Text(labels[option]!.$1),
                avatar: Icon(labels[option]!.$2, size: 17),
                selected: mode == option,
                onSelected: (_) => onMode(option),
                selectedColor: AppTokens.coral.withValues(alpha: .16),
                showCheckmark: false,
                labelStyle: TextStyle(
                  fontWeight: mode == option
                      ? FontWeight.w800
                      : FontWeight.w500,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(labels[mode]!.$3, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 14),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 15,
              label: Text('15秒'),
              icon: Icon(Icons.bolt_rounded),
            ),
            ButtonSegment(
              value: 30,
              label: Text('30秒・展開あり'),
              icon: Icon(Icons.loop_rounded),
            ),
          ],
          selected: {seconds},
          onSelectionChanged: (v) => onDuration(v.first),
        ),
      ],
    ),
  );
}
