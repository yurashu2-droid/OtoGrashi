import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/tokens.dart';
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
    this.isAdding = false,
    this.addError,
    this.recordedClipCount = 0,
    this.testFixture = false,
    super.key,
  });

  final CaptureController controller;
  final MediaPresentationGateway? presentation;
  final VoidCallback? onMediaReady;
  final bool isAdding;
  final String? addError;
  final int recordedClipCount;
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
        final screenSize = MediaQuery.sizeOf(context);
        final previewHeight = (screenSize.height * 0.46).clamp(
          280.0,
          MediaQuery.textScalerOf(context).scale(16) > 21 ? 360.0 : 400.0,
        ).toDouble();
        return Scaffold(
          appBar: AppBar(title: const Text('音を録る'), toolbarHeight: 52),
          bottomNavigationBar: state.phase == CapturePhase.completed
              ? _reviewActions()
              : null,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                _CollectionHeader(recordedClipCount: widget.recordedClipCount),
                const SizedBox(height: 12),
                SizedBox(
                  height: previewHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFE5DBD0),
                        border: Border.all(color: Colors.white, width: 3),
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x14211C1A),
                            blurRadius: 14,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(21),
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
                            Positioned(
                              left: 12,
                              bottom: 12,
                              child: _PreviewSticker(
                                label: state.phase == CapturePhase.completed
                                    ? '音が録れました'
                                    : state.phase == CapturePhase.recording
                                    ? '音を録っています'
                                    : '気になる音を探そう',
                              ),
                            ),
                            if (state.phase == CapturePhase.completed &&
                                captured != null)
                              _reviewPlayback(captured),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (state.phase == CapturePhase.recording)
                  _RecordingProgress(progress: state.progress)
                else ...[
                  const SizedBox(height: 8),
                  _CaptureStatus(text: _statusText(state)),
                ],
                if (state.message case final message?) ...[
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
                const SizedBox(height: 10),
                if (state.phase == CapturePhase.idle || state.canRetry)
                  FilledButton(
                    onPressed: state.isBusy ? null : widget.controller.prepare,
                    child: const Text('カメラとマイクを準備'),
                  ),
                if (state.phase == CapturePhase.ready) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '録音する長さ',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTokens.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
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
                            foregroundColor: AppTokens.ink,
                            minimumSize: const Size.fromHeight(62),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          child: Text(
                            _durationUs == 3000000 ? '♪  3秒撮る' : '♪  6秒撮る',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: widget.controller.isSwitchingCamera
                            ? null
                            : widget.controller.switchCamera,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 56),
                        ),
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
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.ink,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('録音を止める'),
                  ),
                if (!state.isBusy &&
                    state.phase != CapturePhase.recording &&
                    state.phase != CapturePhase.completed) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: widget.controller.importVideo,
                    icon: const Icon(Icons.photo_library_outlined, size: 19),
                    label: const Text('写真から動画を選ぶ'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      foregroundColor: AppTokens.mutedInk,
                    ),
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
                '${(_playback.position.inMilliseconds / 1000).toStringAsFixed(1)} / ${(captured.durationUs / 1000000).toStringAsFixed(1)}秒',
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
            if (widget.isAdding) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('音を追加しています'),
              const SizedBox(height: 8),
            ],
            if (widget.addError != null) ...[
              Text(
                widget.addError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.isAdding
                        ? null
                        : () async {
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
                    onPressed: widget.isAdding ? null : widget.onMediaReady,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.coral,
                      foregroundColor: AppTokens.ink,
                    ),
                    child: Text(widget.isAdding ? '追加中' : 'この音を使う'),
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: widget.isAdding
                  ? null
                  : () async {
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
    CapturePhase.idle => '身近な音を、3秒から録ってみよう',
    CapturePhase.preparing => 'カメラとマイクを準備しています',
    CapturePhase.ready => '撮ったあとに音を聴いて、撮り直せます',
    CapturePhase.starting => '録音を始めています',
    CapturePhase.recording => '録音中',
    CapturePhase.stopping => '動画を確定しています',
    CapturePhase.importing => '動画を読み込んでいます',
    CapturePhase.completed => '録れた音を確認してください',
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
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 46,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFE0D7) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppTokens.coral : const Color(0xFFE9DFD4),
            width: selected ? 1.5 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D211C1A),
              blurRadius: 5,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 17,
              color: selected ? AppTokens.coral : AppTokens.mutedInk,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                color: AppTokens.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
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
      color: const Color(0xFF554B50),
      child: Center(
        child: Text(
          testFixture ? 'TEST カメラプレビュー' : 'カメラ映像',
          style: const TextStyle(
            color: Color(0xFFF8EFE6),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

final class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({required this.recordedClipCount});

  final int recordedClipCount;

  @override
  Widget build(BuildContext context) {
    final completeCount = recordedClipCount.clamp(0, 3);
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    completeCount == 3
                        ? '音をもうひとつ集めよう'
                        : '音を集めて、曲にしよう',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    completeCount == 3
                        ? '音はいつでも追加できます'
                        : '身近な音を3つ。気になる音から。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTokens.mutedInk,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE0D7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFF4B5A9)),
              ),
              child: Text(
                '$completeCount / 3',
                style: const TextStyle(
                  color: AppTokens.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Row(
          children: [
            for (var index = 0; index < 3; index++) ...[
              _CollectionStep(
                number: index + 1,
                isComplete: index < completeCount,
                isCurrent: index == completeCount && completeCount < 3,
              ),
              if (index < 2)
                Expanded(
                  child: Container(
                    height: 2,
                    color: index < completeCount
                        ? AppTokens.coral
                        : const Color(0xFFE5DAD0),
                  ),
                ),
            ],
          ],
        ),
      ],
    );
  }
}

final class _CollectionStep extends StatelessWidget {
  const _CollectionStep({
    required this.number,
    required this.isComplete,
    required this.isCurrent,
  });

  final int number;
  final bool isComplete;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 180),
    width: 22,
    height: 22,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: isComplete
          ? AppTokens.coral
          : isCurrent
          ? const Color(0xFFFFE0D7)
          : Colors.white,
      border: Border.all(
        color: isComplete || isCurrent
            ? AppTokens.coral
            : const Color(0xFFD9CEC3),
        width: isCurrent ? 1.5 : 1,
      ),
    ),
    child: isComplete
        ? const Icon(Icons.check_rounded, size: 14, color: AppTokens.ink)
        : Text(
            '$number',
            style: TextStyle(
              color: isCurrent ? AppTokens.ink : AppTokens.mutedInk,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
  );
}

final class _PreviewSticker extends StatelessWidget {
  const _PreviewSticker({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppTokens.paper,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.white, width: 1.5),
      boxShadow: const [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 6,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.graphic_eq_rounded, size: 17, color: AppTokens.coral),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: AppTokens.ink,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    ),
  );
}

final class _CaptureStatus extends StatelessWidget {
  const _CaptureStatus({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('capture-status'),
    alignment: Alignment.center,
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: AppTokens.mutedInk,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

final class _RecordingProgress extends StatelessWidget {
  const _RecordingProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          const Icon(Icons.graphic_eq_rounded, color: AppTokens.coral, size: 18),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '録音中',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Text('${(progress.clamp(0, 1) * 100).round()}%'),
        ],
      ),
      const SizedBox(height: 5),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: progress.clamp(0, 1).toDouble(),
          minHeight: 6,
          color: AppTokens.coral,
          backgroundColor: const Color(0xFFE9DFD4),
        ),
      ),
    ],
  );
}
