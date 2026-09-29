import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../design/shutter_ball.dart';
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
  // Recording time is counted here: the native side does not stream progress.
  DateTime? _recordingSince;
  Timer? _recordingTick;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_trackRecording);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_trackRecording);
    _recordingTick?.cancel();
    _playback.dispose();
    super.dispose();
  }

  void _trackRecording() {
    final recording = widget.controller.state.phase == CapturePhase.recording;
    if (recording && _recordingSince == null) {
      _recordingSince = DateTime.now();
      _recordingTick = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) setState(() {});
      });
    } else if (!recording && _recordingSince != null) {
      _recordingSince = null;
      _recordingTick?.cancel();
      _recordingTick = null;
    }
  }

  double _recordingProgress(CaptureState state) {
    final since = _recordingSince;
    final counted = since == null
        ? 0.0
        : DateTime.now().difference(since).inMicroseconds / _durationUs;
    return math.max(state.progress, counted).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final state = widget.controller.state;
        final captured = state.capturedMedia;
        final completed = state.phase == CapturePhase.completed;
        final padding = MediaQuery.paddingOf(context);
        return Scaffold(
          backgroundColor: AppTokens.surfaceColor,
          body: Padding(
            padding: EdgeInsets.fromLTRB(
              8,
              padding.top + 4,
              8,
              padding.bottom + 8,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: ColoredBox(
                color: const Color(0xFF252126),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (captured != null &&
                        (completed || state.phase == CapturePhase.importing))
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
                    // soft scrims keep the floating controls readable
                    const Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: 110,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x40000000), Color(0x00000000)],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 220,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [Color(0x59000000), Color(0x00000000)],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (completed && captured != null)
                      _reviewPlayback(captured),
                    Positioned(
                      left: 10,
                      right: 10,
                      top: 10,
                      child: Row(
                        children: [
                          _GlassIconButton(
                            icon: Icons.close_rounded,
                            tooltip: '閉じる',
                            onPressed: () => Navigator.maybePop(context),
                          ),
                          const Spacer(),
                          if (!state.isBusy &&
                              state.phase != CapturePhase.recording &&
                              !completed) ...[
                            _GlassIconButton(
                              icon: Icons.photo_library_outlined,
                              tooltip: '写真から動画を選ぶ',
                              onPressed: widget.controller.importVideo,
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (state.phase == CapturePhase.ready)
                            _GlassPill(
                              onPressed: widget.controller.isSwitchingCamera
                                  ? null
                                  : widget.controller.switchCamera,
                              icon: Icons.flip_camera_ios_outlined,
                              label: state.cameraFacing == CameraFacing.back
                                  ? 'インカメ'
                                  : '外カメ',
                            ),
                        ],
                      ),
                    ),
                    if (_notice(state) case final notice?)
                      Positioned(
                        left: 20,
                        right: 20,
                        top: 66,
                        child: Center(child: _GlassPill(label: notice)),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: completed
                          ? _reviewActions()
                          : _shutterActions(state),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Only what needs attention: errors, and playback trouble after capture.
  /// Everyday states are told by the shutter's own caption.
  String? _notice(CaptureState state) {
    if (state.message case final message?) return message;
    if (state.phase == CapturePhase.completed && _playback.error != null) {
      return '再生できませんでした。撮り直すか、別の動画を選んでください。';
    }
    return null;
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
          bottom: 150,
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
    type: MaterialType.transparency,
    child: SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.isAdding) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text(
                '音を追加しています',
                style: TextStyle(color: Colors.white),
              ),
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
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      side: BorderSide.none,
                    ),
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('撮り直す'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: widget.isAdding ? null : widget.onMediaReady,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.blush,
                      foregroundColor: Colors.white,
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
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('別の動画を選ぶ'),
            ),
          ],
        ),
      ),
    ),
  );

  /// One round shutter that stays put through every capture phase, so the
  /// tab bar's mic ball can fly straight into it.
  Widget _shutterActions(CaptureState state) {
    final phase = state.phase;
    final ready = phase == CapturePhase.ready;
    final recording = phase == CapturePhase.recording;
    final canPrepare = phase == CapturePhase.idle || state.canRetry;
    final seconds = _durationUs ~/ 1000000;
    final progress = _recordingProgress(state);
    final VoidCallback? onTap = ready
        ? () => widget.controller.record(maxDurationUs: _durationUs)
        : recording
        ? widget.controller.stop
        : canPrepare
        ? widget.controller.prepare
        : null;
    final caption = ready
        ? '♪  $seconds秒撮る'
        : recording
        ? '録音中  ${(seconds * progress).toStringAsFixed(1)} / $seconds.0秒'
        : canPrepare
        ? 'カメラとマイクを準備'
        : _statusText(state);
    final mode = recording
        ? ShutterMode.stop
        : ready || canPrepare
        ? ShutterMode.mic
        : ShutterMode.busy;
    Widget side(int durationUs) => SizedBox(
      width: 84,
      child: ready
          ? _DurationChoice(
              label: durationUs == 3000000 ? '3秒' : '6秒',
              selected: _durationUs == durationUs,
              onPressed: () => setState(() => _durationUs = durationUs),
            )
          : null,
    );
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Row(
          children: [
              side(3000000),
              Expanded(
                child: Semantics(
                  button: onTap != null,
                  label: recording ? '録音を止める' : null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 92,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (recording)
                                SizedBox.square(
                                  dimension: 92,
                                  child: CircularProgressIndicator(
                                    value: progress,
                                    strokeWidth: 4,
                                    color: AppTokens.blush,
                                    backgroundColor: const Color(0x40FFFFFF),
                                  ),
                                ),
                              SizedBox.square(
                                dimension: 76,
                                child: Hero(
                                  tag: captureShutterTag,
                                  child: ShutterBall(mode: mode),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            shadows: [
                              Shadow(color: Color(0x66000000), blurRadius: 6),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              side(6000000),
          ],
        ),
      ),
    );
  }

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
    child: GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : const Color(0x4D000000),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppTokens.ink : Colors.white,
            fontWeight: FontWeight.w800,
          ),
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

final class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    style: IconButton.styleFrom(
      backgroundColor: const Color(0x4D000000),
      foregroundColor: Colors.white,
      minimumSize: const Size.square(44),
    ),
    icon: Icon(icon, size: 22),
  );
}

/// Small translucent label or button floating on the camera view.
final class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.label, this.icon, this.onPressed});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x4D000000),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon case final icon?) ...[
            Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (onPressed == null && icon == null) return body;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: GestureDetector(onTap: onPressed, child: body),
    );
  }
}
