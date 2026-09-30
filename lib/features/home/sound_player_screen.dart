import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/clip_asset.dart';
import '../../media/media_presentation_gateway.dart';
import '../export/media_playback.dart';

/// One sound's whole recording, full screen on black; tap to pause/play.
final class SoundPlayerScreen extends StatefulWidget {
  const SoundPlayerScreen({
    required this.asset,
    required this.title,
    required this.presentation,
    super.key,
  });

  final ClipAsset asset;
  final String title;
  final MediaPresentationGateway presentation;

  @override
  State<SoundPlayerScreen> createState() => _SoundPlayerScreenState();
}

class _SoundPlayerScreenState extends State<SoundPlayerScreen> {
  late final MediaPlaybackController _playback = MediaPlaybackController(
    widget.presentation,
  )..addListener(_autoplay);
  var _started = false;

  void _autoplay() {
    if (_started || !_playback.isReady) return;
    _started = true;
    unawaited(_playback.toggle());
  }

  @override
  void dispose() {
    _playback.removeListener(_autoplay);
    unawaited(_playback.pause());
    _playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: () => unawaited(_playback.toggle()),
          child: NativeMovieView(
            relativePath: widget.asset.relativePath,
            gateway: widget.presentation,
            controller: _playback,
            aspectFitVideo: true,
            fallback: const ColoredBox(color: Colors.black),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.maybePop(context),
                  tooltip: '閉じる',
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0x4D000000),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _playback,
          builder: (context, _) => IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _playback.isReady && !_playback.isPlaying ? 1 : 0,
              child: const Center(
                child: Icon(
                  Icons.play_circle_fill_rounded,
                  size: 72,
                  color: Color(0xCCFFFFFF),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
