import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/capture_chrome.dart';
import '../../media/media_messages.dart';
import 'capture_controller.dart';
import 'capture_state.dart';

final class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    required this.controller,
    this.onMediaReady,
    this.testFixture = false,
    super.key,
  });

  final CaptureController controller;
  final VoidCallback? onMediaReady;
  final bool testFixture;

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
                SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(16) > 21
                      ? 330
                      : 405,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: CaptureChrome(
                      child: _CapturePreview(
                        handle: state.handle,
                        testFixture: widget.testFixture,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppTokens.smallGap),
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
                  Row(
                    children: [
                      for (final duration in const [3000000, 6000000])
                        Expanded(
                          child: Padding(
                            padding: EdgeInsets.only(
                              right: duration == 3000000 ? 5 : 0,
                              left: duration == 6000000 ? 5 : 0,
                            ),
                            child: _DurationChoice(
                              label: duration == 3000000 ? '3秒' : '6秒',
                              selected: _durationUs == duration,
                              onPressed: () =>
                                  setState(() => _durationUs = duration),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppTokens.controlGap),
                  FilledButton(
                    onPressed: () =>
                        widget.controller.record(maxDurationUs: _durationUs),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.coral,
                      foregroundColor: const Color(0xFF2C2730),
                    ),
                    child: Text(_durationUs == 3000000 ? '●  3秒撮る' : '●  6秒撮る'),
                  ),
                ],
                if (state.phase == CapturePhase.recording)
                  FilledButton(
                    onPressed: widget.controller.stop,
                    child: const Text('■  録画を止める'),
                  ),
                if (!state.isBusy && state.phase != CapturePhase.recording) ...[
                  const SizedBox(height: AppTokens.controlGap),
                  OutlinedButton(
                    onPressed: widget.controller.importVideo,
                    child: const Text('写真から動画を選ぶ'),
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

class _DurationChoice extends StatelessWidget {
  const _DurationChoice({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Colors.transparent,
      ),
      child: Text(label),
    ),
  );
}

final class _CapturePreview extends StatelessWidget {
  const _CapturePreview({required this.handle, required this.testFixture});

  final CaptureHandle? handle;
  final bool testFixture;

  @override
  Widget build(BuildContext context) {
    if (handle != null && defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(viewType: handle!.previewViewType);
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          testFixture ? 'TEST カメラプレビュー' : 'カメラ映像',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
