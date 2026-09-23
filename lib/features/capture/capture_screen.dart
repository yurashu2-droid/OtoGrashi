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
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (state.phase == CapturePhase.completed &&
                              captured != null)
                            NativeMovieView(
                              key: ValueKey(captured.relativePath),
                              relativePath: captured.relativePath,
                              gateway: _presentation,
                              controller: _playback,
                              fallback: const ColoredBox(
                                color: Color(0xFF252126),
                                child: Center(child: Text('撮った動画のプレビュー')),
                              ),
                            )
                          else
                            _CapturePreview(
                              handle: state.handle,
                              testFixture: widget.testFixture,
                            ),
                          if (state.phase == CapturePhase.ready)
                            Positioned(
                              top: 65,
                              right: 12,
                              child: FilledButton.tonalIcon(
                                onPressed: widget.controller.isSwitchingCamera
                                    ? null
                                    : widget.controller.switchCamera,
                                icon: const Icon(
                                  Icons.flip_camera_ios_outlined,
                                ),
                                label: Text(
                                  state.cameraFacing == CameraFacing.back
                                      ? 'インカメに切替'
                                      : '外カメに切替',
                                ),
                              ),
                            ),
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
                if (!state.isBusy &&
                    state.phase != CapturePhase.recording &&
                    state.phase != CapturePhase.completed) ...[
                  const SizedBox(height: AppTokens.controlGap),
                  OutlinedButton(
                    onPressed: widget.controller.importVideo,
                    child: const Text('写真から動画を選ぶ'),
                  ),
                ],
                if (state.phase == CapturePhase.completed) ...[
                  const SizedBox(height: AppTokens.controlGap),
                  AnimatedBuilder(
                    animation: _playback,
                    builder: (context, _) => Column(
                      children: [
                        Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: _playback.toggle,
                              icon: Icon(
                                _playback.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                              label: Text(
                                _playback.isPlaying ? '一時停止' : '再生して確認',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '${_playback.position.inSeconds} / ${state.capturedMedia!.durationUs ~/ 1000000}秒',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                        if (_playback.error != null)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('再生できませんでした。撮り直すか、別の動画を選んでください。'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppTokens.smallGap),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _playback.pause();
                      await widget.controller.retake();
                    },
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('撮り直す'),
                  ),
                  TextButton(
                    onPressed: () async {
                      await _playback.pause();
                      await widget.controller.chooseAnotherVideo();
                    },
                    child: const Text('別の動画を選ぶ'),
                  ),
                  const SizedBox(height: AppTokens.smallGap),
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
