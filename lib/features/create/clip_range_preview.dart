import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../export/media_playback.dart';

/// Keeps the original recording attached while the selection changes.
class ClipRangePreview extends StatefulWidget {
  const ClipRangePreview({
    required this.clip,
    required this.presentation,
    required this.startUs,
    required this.endUs,
    this.enabled = true,
    this.onAudition,
    this.positionNotifier,
    super.key,
  });

  final ClipAsset clip;
  final MediaPresentationGateway presentation;
  final int startUs;
  final int endUs;
  final bool enabled;
  final Future<void> Function(int startUs, int durationUs)? onAudition;
  final ValueNotifier<int>? positionNotifier;

  @override
  State<ClipRangePreview> createState() => _ClipRangePreviewState();
}

class _ClipRangePreviewState extends State<ClipRangePreview> {
  late final _playback = MediaPlaybackController(widget.presentation)
    ..addListener(_onPlayback);
  bool _initialized = false;
  bool _scrubbing = false;
  bool _commandPending = false;
  bool _rangePlaying = false;
  bool _stopping = false;
  int? _pendingSeekUs;
  late int _shownUs = widget.startUs;
  int _interaction = 0;
  bool _positionFramePending = false;

  void _publishPosition() {
    if (_positionFramePending || widget.positionNotifier == null) return;
    _positionFramePending = true;
    // Range changes arrive during the parent's build. Publish afterwards so
    // the waveform can repaint without marking its builder dirty mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _positionFramePending = false;
      if (mounted) widget.positionNotifier?.value = _shownUs;
    });
  }

  bool get _nativeAvailable =>
      defaultTargetPlatform == TargetPlatform.iOS &&
      !widget.clip.label.startsWith('synthetic-') &&
      !widget.clip.label.startsWith('合成素材');

  @override
  void didUpdateWidget(covariant ClipRangePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startUs != widget.startUs ||
        oldWidget.endUs != widget.endUs) {
      // The moved boundary, including the final end frame, is the scrub target.
      final target = oldWidget.startUs != widget.startUs
          ? widget.startUs
          : widget.endUs;
      _interaction++;
      _rangePlaying = false;
      _shownUs = target;
      _publishPosition();
      unawaited(_scrub(target));
    }
    if (oldWidget.enabled && !widget.enabled) {
      _interaction++;
      _rangePlaying = false;
      unawaited(_playback.pause());
    }
  }

  void _onPlayback() {
    if (!mounted) return;
    if (!_initialized && _playback.isReady) {
      _initialized = true;
      unawaited(_scrub(_shownUs));
    }
    if (!_scrubbing) _shownUs = _playback.position.inMicroseconds;
    _publishPosition();
    if (_rangePlaying &&
        !_stopping &&
        _playback.position.inMicroseconds >= widget.endUs) {
      _rangePlaying = false;
      _stopping = true;
      unawaited(_stopAtEnd());
    }
    setState(() {});
  }

  Future<void> _stopAtEnd() async {
    final interaction = _interaction;
    final endUs = widget.endUs;
    await _playback.pause();
    if (mounted && interaction == _interaction) await _scrub(endUs);
    if (mounted) setState(() => _stopping = false);
  }

  Future<void> _scrub(int targetUs) async {
    _pendingSeekUs = targetUs;
    _shownUs = targetUs;
    _publishPosition();
    if (_scrubbing || !_playback.isReady) return;
    _scrubbing = true;
    try {
      await _playback.pause();
      // At most one native seek is running and one newer target is retained.
      // Do not enqueue every slider event in MediaPlaybackController.
      while (mounted && _pendingSeekUs != null && _playback.isReady) {
        final target = _pendingSeekUs!;
        _pendingSeekUs = null;
        await _playback.seek(Duration(microseconds: target));
      }
    } finally {
      _scrubbing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleRange() async {
    if (_commandPending || _stopping || !widget.enabled) return;
    final interaction = ++_interaction;
    setState(() => _commandPending = true);
    try {
      if (_playback.isPlaying) {
        _rangePlaying = false;
        await _playback.pause();
      } else {
        // Replay always starts at the chosen beginning, even after end scrubbing.
        await _scrub(widget.startUs);
        if (!mounted ||
            interaction != _interaction ||
            _scrubbing ||
            !_playback.isReady ||
            !widget.enabled) {
          return;
        }
        _rangePlaying = true;
        await _playback.toggle();
      }
    } finally {
      if (mounted) setState(() => _commandPending = false);
    }
  }

  @override
  void dispose() {
    _interaction++;
    _playback.removeListener(_onPlayback);
    _playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_nativeAvailable) {
      return Column(
        children: [
          const Text('この素材は波形で範囲を確認できます。'),
          if (widget.onAudition != null)
            OutlinedButton.icon(
              onPressed: widget.enabled
                  ? () => widget.onAudition!(
                      widget.startUs,
                      widget.endUs - widget.startUs,
                    )
                  : null,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('この範囲を聴く'),
            ),
        ],
      );
    }
    final previewHeight = (MediaQuery.sizeOf(context).height * .25).clamp(
      120.0,
      210.0,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            height: previewHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                NativeMovieView(
                  relativePath: widget.clip.relativePath,
                  gateway: widget.presentation,
                  controller: _playback,
                  aspectFitVideo: true,
                ),
                if (_playback.error != null)
                  const ColoredBox(
                    color: Colors.black87,
                    child: Center(
                      child: Text(
                        '動画を読み込めません。波形で範囲を選べます。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  )
                else if (!_playback.isReady)
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: (_shownUs / widget.clip.durationUs).clamp(0.0, 1.0),
          semanticsLabel: '元の動画の再生位置',
          semanticsValue: '${(_shownUs / 1e6).toStringAsFixed(1)}秒',
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '動画の位置 ${(_shownUs / 1e6).toStringAsFixed(1)}秒',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton.icon(
              onPressed:
                  widget.enabled &&
                      _playback.isReady &&
                      !_commandPending &&
                      !_scrubbing &&
                      !_stopping
                  ? () => unawaited(_toggleRange())
                  : null,
              icon: Icon(
                _playback.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(_playback.isPlaying ? '一時停止' : '選んだ範囲を再生'),
            ),
          ],
        ),
      ],
    );
  }
}
