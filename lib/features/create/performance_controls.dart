import 'package:flutter/material.dart';

import '../../domain/arrangement.dart';
import '../../design/tokens.dart';
import '../../media/depth_model.dart';

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
    PerformanceMode.window: (
      'とびだす',
      Icons.view_in_ar_rounded,
      '撮った顔や物が、窓から飛び出す3D。はじめに約50MBのダウンロードが必要です。',
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
                if (option == PerformanceMode.window)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: _WindowChip(
                      selected: mode == option,
                      onSelected: () => onMode(option),
                    ),
                  )
                else
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

/// とびだす is added by downloading its depth model once; until then the chip
/// shows a download mark and asks before fetching about 50 MB.
final class _WindowChip extends StatefulWidget {
  const _WindowChip({required this.selected, required this.onSelected});

  final bool selected;
  final VoidCallback onSelected;

  @override
  State<_WindowChip> createState() => _WindowChipState();
}

final class _WindowChipState extends State<_WindowChip> {
  final _model = DepthModel.instance;

  @override
  void initState() {
    super.initState();
    if (_model.value.phase == DepthModelPhase.unknown) _model.refresh();
  }

  Future<void> _tap() async {
    if (_model.isReady) {
      widget.onSelected();
      return;
    }
    if (_model.value.phase == DepthModelPhase.downloading) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('「とびだす」を追加'),
        content: const Text(
          '撮った顔や物を立体にするためのデータ（約${DepthModel.megabytes}MB）を'
          'ダウンロードします。Wi-Fi でのダウンロードがおすすめです。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('やめる'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('ダウンロード'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    final ready = await _model.download();
    if (!mounted) return;
    if (ready) {
      widget.onSelected();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'ダウンロードできませんでした。${_model.value.message ?? ''}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DepthModelState>(
    valueListenable: _model,
    builder: (context, state, _) {
      final label = PerformanceControls.labels[PerformanceMode.window]!;
      final downloading = state.phase == DepthModelPhase.downloading;
      final ready = state.phase == DepthModelPhase.ready;
      final on = widget.selected && ready;
      return ChoiceChip(
        label: Text(
          downloading
              ? '${label.$1} ${(state.progress * 100).round()}%'
              : label.$1,
        ),
        avatar: downloading
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                ready ? label.$2 : Icons.download_rounded,
                size: 17,
                color: on ? Colors.white : AppTokens.ink,
              ),
        selected: on,
        onSelected: (_) => _tap(),
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: AppTokens.tile,
        selectedColor: AppTokens.ink,
        showCheckmark: false,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w800,
          color: on ? Colors.white : AppTokens.ink,
        ),
      );
    },
  );
}
