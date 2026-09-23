import 'dart:async';

import 'package:flutter/material.dart';

import '../../media/media_presentation_gateway.dart';
import '../../design/tokens.dart';
import 'media_playback.dart';

/// A distraction-free way to hear the captured moments turn into the song.
class ComparisonPlayer extends StatefulWidget {
  const ComparisonPlayer({
    required this.songPath,
    required this.originalSegments,
    required this.presentation,
    required this.fallback,
    super.key,
  });

  final String songPath;
  final List<PlaybackSegment> originalSegments;
  final MediaPresentationGateway presentation;
  final Widget fallback;

  @override
  State<ComparisonPlayer> createState() => _ComparisonPlayerState();
}

class _ComparisonPlayerState extends State<ComparisonPlayer> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.presentation,
  )..addListener(_playWhenReady);
  bool _original = false;
  bool _autoplayRequested = false;

  void _playWhenReady() {
    if (!playback.isReady || _autoplayRequested || !mounted) return;
    _autoplayRequested = true;
    unawaited(playback.toggle());
  }

  Future<void> _showOriginal(bool original) async {
    if (_original == original) return;
    await playback.pause();
    if (!mounted) return;
    setState(() {
      _original = original;
      _autoplayRequested = false;
    });
  }

  @override
  void dispose() {
    playback.removeListener(_playWhenReady);
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final path = _original
        ? widget.originalSegments.first.relativePath
        : widget.songPath;
    return Scaffold(
      backgroundColor: const Color(0xFF1D191B),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 18, 10),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: '閉じる',
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                  const Expanded(
                    child: Text(
                      'いつもの音 → できた曲',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: NativeMovieView(
                        key: ValueKey(
                          '${_original ? 'original' : 'song'}:$path',
                        ),
                        relativePath: path,
                        segments: _original
                            ? widget.originalSegments
                            : const [],
                        gateway: widget.presentation,
                        controller: playback,
                        fallback: widget.fallback,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: AnimatedBuilder(
                animation: playback,
                builder: (context, _) {
                  final durationUs = playback.duration.inMicroseconds.clamp(
                    1,
                    1 << 53,
                  );
                  final positionUs = playback.position.inMicroseconds.clamp(
                    0,
                    durationUs,
                  );
                  return Column(
                    children: [
                      Row(
                        children: [
                          IconButton.filled(
                            onPressed: playback.isReady
                                ? playback.toggle
                                : null,
                            tooltip: playback.isLoading
                                ? '動画を読み込み中'
                                : playback.isPlaying
                                ? '一時停止'
                                : '再生',
                            style: IconButton.styleFrom(
                              backgroundColor: AppTokens.coral,
                              foregroundColor: AppTokens.ink,
                            ),
                            icon: Icon(
                              playback.isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: positionUs.toDouble(),
                              max: durationUs.toDouble(),
                              activeColor: AppTokens.coral,
                              inactiveColor: Colors.white38,
                              onChanged: playback.isReady
                                  ? (value) => unawaited(
                                      playback.seek(
                                        Duration(microseconds: value.round()),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                          Text(
                            '${_seconds(playback.position)} / ${_seconds(playback.duration)}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                      if (playback.error != null)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: Text(
                            '動画を再生できませんでした',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _modeButton('元の音', true),
                          const SizedBox(width: 10),
                          _modeButton('できた曲', false),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeButton(String label, bool original) => Expanded(
    child: FilledButton(
      onPressed: _original == original ? null : () => _showOriginal(original),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: _original == original
            ? AppTokens.paper
            : const Color(0xFF403B3D),
        foregroundColor: _original == original ? AppTokens.ink : Colors.white,
        disabledBackgroundColor: AppTokens.paper,
        disabledForegroundColor: AppTokens.ink,
      ),
      child: Text(label),
    ),
  );

  String _seconds(Duration value) {
    final seconds = value.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
