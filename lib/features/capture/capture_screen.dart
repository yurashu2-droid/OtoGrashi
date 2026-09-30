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

/// A folder a recording can be filed into.
typedef CaptureDestination = ({String id, String title});

final class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    required this.controller,
    this.presentation,
    this.onMediaReady,
    this.isAdding = false,
    this.addError,
    this.recordedClipCount = 0,
    this.testFixture = false,
    this.destinations = const [],
    this.destinationId,
    this.onDestination,
    super.key,
  });

  final CaptureController controller;
  final MediaPresentationGateway? presentation;
  final VoidCallback? onMediaReady;
  final bool isAdding;
  final String? addError;
  final int recordedClipCount;
  final bool testFixture;

  /// Folders the recording can go into, shown as chips over the camera.
  final List<CaptureDestination> destinations;
  final String? destinationId;
  final ValueChanged<String>? onDestination;

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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.destinations.isNotEmpty &&
                              state.phase != CapturePhase.recording)
                            _DestinationChips(
                              destinations: widget.destinations,
                              selectedId: widget.destinationId,
                              onSelected: widget.onDestination,
                            ),
                          completed ? _reviewActions() : _shutterActions(state),
                        ],
                      ),
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
              color: const Color(0xDD333333),
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
    final canImport =
        !state.isBusy && !recording && phase != CapturePhase.completed;
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
        child: Row(
          children: [
              SizedBox(
                width: 84,
                child: canImport
                    ? Center(
                        child: _GlassIconButton(
                          icon: Icons.photo_library_outlined,
                          tooltip: '写真から動画を選ぶ',
                          onPressed: widget.controller.importVideo,
                          size: 52,
                        ),
                      )
                    : null,
              ),
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
              SizedBox(
                width: 84,
                child: ready
                    ? Center(
                        child: _DurationDial(
                          durationUs: _durationUs,
                          onChanged: (value) =>
                              setState(() => _durationUs = value),
                        ),
                      )
                    : null,
              ),
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

/// Recording length on a small ring: the chosen length sits at the top and
/// the other waits on the side. Tap or swipe to turn the ring.
class _DurationDial extends StatelessWidget {
  const _DurationDial({required this.durationUs, required this.onChanged});

  final int durationUs;
  final ValueChanged<int> onChanged;

  static const _options = [3000000, 6000000];
  static const _size = 72.0;

  void _turn() =>
      onChanged(durationUs == _options.first ? _options.last : _options.first);

  @override
  Widget build(BuildContext context) {
    final index = _options.indexOf(durationUs).clamp(0, 1);
    // each option sits a quarter turn apart; the ring turns to bring the
    // chosen one to twelve o'clock
    final turns = -index / 4;
    return Semantics(
      button: true,
      label: '録音の長さ ${durationUs ~/ 1000000}秒。タップで切り替え',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: _turn,
        onPanEnd: (details) {
          if (details.velocity.pixelsPerSecond.distance > 80) _turn();
        },
        child: SizedBox.square(
          dimension: _size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0x4D000000),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0x59FFFFFF), width: 1.5),
            ),
            child: AnimatedRotation(
              turns: turns,
              duration: const Duration(milliseconds: 420),
              curve: const Cubic(0.3, 1.35, 0.5, 1),
              child: Stack(
                children: [
                  for (var i = 0; i < _options.length; i++)
                    Align(
                      // a quarter turn apart on the ring, starting at the top
                      alignment: i == 0
                          ? const Alignment(0, -0.62)
                          : const Alignment(0.62, 0),
                      child: AnimatedRotation(
                        turns: -turns,
                        duration: const Duration(milliseconds: 420),
                        curve: const Cubic(0.3, 1.35, 0.5, 1),
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 200),
                          style: TextStyle(
                            color: i == index
                                ? Colors.white
                                : const Color(0x99FFFFFF),
                            fontSize: i == index ? 17 : 11,
                            fontWeight: FontWeight.w800,
                          ),
                          child: Text('${_options[i] ~/ 1000000}秒'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
            color: Color(0xFFF1F1F1),
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
    this.size = 44,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: tooltip,
    style: IconButton.styleFrom(
      backgroundColor: const Color(0x4D000000),
      foregroundColor: Colors.white,
      minimumSize: Size.square(size),
    ),
    icon: Icon(icon, size: size * 0.46),
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

/// Which folder the recording goes into: a row of glass pills.
final class _DestinationChips extends StatelessWidget {
  const _DestinationChips({
    required this.destinations,
    required this.selectedId,
    required this.onSelected,
  });

  final List<CaptureDestination> destinations;
  final String? selectedId;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      itemCount: destinations.length + 1,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.only(right: 2),
              child: Text(
                '入れる先',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(color: Color(0x66000000), blurRadius: 6)],
                ),
              ),
            ),
          );
        }
        final destination = destinations[index - 1];
        final selected = destination.id == selectedId;
        return Semantics(
          button: true,
          selected: selected,
          child: GestureDetector(
            onTap: () => onSelected?.call(destination.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? Colors.white : const Color(0x4D000000),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                destination.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: selected ? AppTokens.ink : Colors.white,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
