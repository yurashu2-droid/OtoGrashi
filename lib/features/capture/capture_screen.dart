import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../design/capture_chrome.dart';
import '../../media/media_messages.dart';
import '../../media/media_presentation_gateway.dart';
import '../export/media_playback.dart';
import 'capture_controller.dart';
import 'capture_state.dart';

final class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    required this.controller,
    this.presentation,
    this.onMediaReady,
    this.testFixture = false,
    super.key,
  });

  final CaptureController controller;
  final MediaPresentationGateway? presentation;
  final VoidCallback? onMediaReady;
  final bool testFixture;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

final class _CaptureScreenState extends State<CaptureScreen> {
  int _durationUs = 3000000;
  late final MediaPresentationGateway _presentation =
      widget.presentation ?? PlatformMediaPresentationGateway();
  late final MediaPlaybackController _playback = MediaPlaybackController(
    _presentation,
  );

  @override
  void dispose() {
    _playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        final captured = state.capturedMedia;
        return Scaffold(
          appBar: AppBar(title: const Text('音を撮る')),
          bottomNavigationBar: state.phase == CapturePhase.completed
              ? _reviewActions()
              : null,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(AppTokens.pagePadding),
              children: [
                SizedBox(
                  height: (MediaQuery.sizeOf(context).height * 0.47).clamp(
                    280.0,
                    MediaQuery.textScalerOf(context).scale(16) > 21
                        ? 330.0
                        : 405.0,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: CaptureChrome(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (captured != null &&
                              (state.phase == CapturePhase.completed ||
                                  state.phase == CapturePhase.importing))
                            NativeMovieView(
                              key: ValueKey(captured.relativePath),
                              relativePath: captured.relativePath,
                              gateway: _presentation,
                              controller: _playback,
                              fallback: const ColoredBox(
                                color: Color(0xFF252126),
                                child: Center(
                                  child: Text(
                                    '撮った動画のプレビュー',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                ),
                              ),
                            )
                          else
                            _CapturePreview(
                              handle: state.handle,
                              testFixture: widget.testFixture,
                            ),
                          if (state.phase == CapturePhase.completed &&
                              captured != null)
                            _reviewPlayback(captured),
                        ],
                      ),
                    ),
                  ),
                ),
                if (state.phase == CapturePhase.recording)
                  LinearProgressIndicator(value: state.progress),
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
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () => widget.controller.record(
                            maxDurationUs: _durationUs,
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTokens.coral,
                            foregroundColor: const Color(0xFF2C2730),
                          ),
                          child: Text(
                            _durationUs == 3000000 ? '●  3秒撮る' : '●  6秒撮る',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: widget.controller.isSwitchingCamera
                            ? null
                            : widget.controller.switchCamera,
                        icon: const Icon(Icons.flip_camera_ios_outlined),
                        label: Text(
                          state.cameraFacing == CameraFacing.back
                              ? 'インカメ'
                              : '外カメ',
                        ),
                      ),
                    ],
                  ),
                ],
                if (state.phase == CapturePhase.recording)
                  FilledButton(
                    onPressed: widget.controller.stop,
                    child: const Text('■  録画を止める'),
                  ),
                if (!state.isBusy &&
                    state.phase != CapturePhase.recording &&
                    state.phase != CapturePhase.completed) ...[
                  const SizedBox(height: AppTokens.controlGap),
                  OutlinedButton(
                    onPressed: widget.controller.importVideo,
                    child: const Text('写真から動画を選ぶ'),
                  ),
                ],
                if (state.phase == CapturePhase.completed)
                  AnimatedBuilder(
                    animation: _playback,
                    builder: (context, _) => _playback.error == null
                        ? const SizedBox.shrink()
                        : const Text('再生できませんでした。撮り直すか、別の動画を選んでください。'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _reviewPlayback(CapturedMedia captured) => AnimatedBuilder(
    animation: _playback,
    builder: (context, _) => Stack(
      children: [
        Center(
          child: SizedBox(
            width: MediaQuery.textScalerOf(context)
                .scale(220)
                .clamp(220.0, 300.0),
            child: FilledButton.tonalIcon(
              onPressed: _playback.isReady ? _playback.toggle : null,
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.paper,
                foregroundColor: AppTokens.ink,
                disabledBackgroundColor: AppTokens.paper,
                disabledForegroundColor: AppTokens.mutedInk,
              ),
              icon: Icon(
                _playback.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(
                _playback.error != null
                    ? '再生できません'
                    : !_playback.isReady
                    ? '再生を準備中'
                    : _playback.isPlaying
                    ? '一時停止'
                    : '再生して確認',
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 73,
          right: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xDD211C1A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Text(
                '${_playback.position.inSeconds} / ${captured.durationUs ~/ 1000000}秒',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _reviewActions() => Material(
    color: AppTokens.surfaceColor,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await _playback.pause();
                      await widget.controller.retake();
                    },
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('撮り直す'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: widget.onMediaReady,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.coral,
                      foregroundColor: AppTokens.ink,
                    ),
                    child: const Text('この音を使う'),
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: () async {
                await _playback.pause();
                await widget.controller.chooseAnotherVideo();
              },
              child: const Text('別の動画を選ぶ'),
            ),
          ],
        ),
      ),
    ),
  );

  String _statusText(CaptureState state) => switch (state.phase) {
    CapturePhase.idle => '準備するときに、カメラとマイクの使用を確認します',
    CapturePhase.preparing => 'カメラとマイクを準備しています',
    CapturePhase.ready => '撮ったあとに再生・撮り直しできます',
    CapturePhase.starting => '録画を始めています',
    CapturePhase.recording => '録画中',
    CapturePhase.stopping => '動画を確定しています',
    CapturePhase.importing => '動画を読み込んでいます',
    CapturePhase.completed => '動画と音を確認してください',
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
