import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../media/media_messages.dart';
import 'capture_controller.dart';
import 'capture_state.dart';

final class CaptureScreen extends StatefulWidget {
  const CaptureScreen({required this.controller, this.onMediaReady, super.key});

  final CaptureController controller;
  final VoidCallback? onMediaReady;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

final class _CaptureScreenState extends State<CaptureScreen> {
  int _durationUs = 3000000;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        return Scaffold(
          appBar: AppBar(title: const Text('音を撮る')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(AppTokens.pagePadding),
              children: [
                AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: _CapturePreview(handle: state.handle),
                  ),
                ),
                const SizedBox(height: AppTokens.sectionGap),
                Text(
                  _statusText(state),
                  key: const ValueKey('capture-status'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (state.message case final message?) ...[
                  const SizedBox(height: AppTokens.smallGap),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
                const SizedBox(height: AppTokens.controlGap),
                if (state.phase == CapturePhase.idle || state.canRetry)
                  FilledButton(
                    onPressed: state.isBusy ? null : widget.controller.prepare,
                    child: const Text('カメラとマイクを準備'),
                  ),
                if (state.phase == CapturePhase.ready) ...[
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 3000000, label: Text('3秒')),
                      ButtonSegment(value: 6000000, label: Text('6秒')),
                    ],
                    selected: {_durationUs},
                    onSelectionChanged: (selection) {
                      setState(() => _durationUs = selection.single);
                    },
                  ),
                  const SizedBox(height: AppTokens.controlGap),
                  FilledButton.icon(
                    onPressed: () =>
                        widget.controller.record(maxDurationUs: _durationUs),
                    icon: const Icon(Icons.fiber_manual_record),
                    label: Text(_durationUs == 3000000 ? '3秒撮る' : '6秒撮る'),
                  ),
                ],
                if (state.phase == CapturePhase.recording ||
                    state.phase == CapturePhase.starting)
                  FilledButton.icon(
                    onPressed: widget.controller.stop,
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('録画を止める'),
                  ),
                if (!state.isBusy && state.phase != CapturePhase.recording) ...[
                  const SizedBox(height: AppTokens.controlGap),
                  OutlinedButton.icon(
                    onPressed: widget.controller.importVideo,
                    icon: const Icon(Icons.video_library_outlined),
                    label: const Text('写真から動画を選ぶ'),
                  ),
                ],
                if (state.phase == CapturePhase.completed) ...[
                  const SizedBox(height: AppTokens.controlGap),
                  FilledButton(
                    onPressed: widget.onMediaReady,
                    child: const Text('この音を使う'),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusText(CaptureState state) => switch (state.phase) {
    CapturePhase.idle => '準備するときに、カメラとマイクの使用を確認します',
    CapturePhase.preparing => 'カメラとマイクを準備しています',
    CapturePhase.ready => '撮る長さを選んでください',
    CapturePhase.starting => '録画を始めています',
    CapturePhase.recording => '録画中',
    CapturePhase.stopping => '動画を確定しています',
    CapturePhase.importing => '動画を読み込んでいます',
    CapturePhase.completed => '音のある動画を保存しました',
    CapturePhase.permissionDenied => 'カメラとマイクを利用できません',
    CapturePhase.interrupted => '録画が中断されました',
    CapturePhase.failed => '動画を保存できませんでした',
  };
}

final class _CapturePreview extends StatelessWidget {
  const _CapturePreview({required this.handle});

  final CaptureHandle? handle;

  @override
  Widget build(BuildContext context) {
    if (handle != null && defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(viewType: handle!.previewViewType);
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.videocam_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
