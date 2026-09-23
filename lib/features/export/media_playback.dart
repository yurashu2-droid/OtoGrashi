import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../media/media_presentation_gateway.dart';

final class PlaybackSegment {
  const PlaybackSegment({
    required this.relativePath,
    required this.startUs,
    required this.durationUs,
  });

  final String relativePath;
  final int startUs;
  final int durationUs;

  Map<String, Object> toNativeMap() => <String, Object>{
    'relativePath': relativePath,
    'startUs': startUs,
    'durationUs': durationUs,
  };
}

final class MediaPlaybackController extends ChangeNotifier {
  MediaPlaybackController(this.gateway);

  final MediaPresentationGateway gateway;
  int? _viewId;
  bool _playing = false;
  bool _loading = false;
  bool _ended = false;
  Duration _position = Duration.zero;
  Duration _duration = const Duration(seconds: 15);
  Object? _error;
  bool _disposed = false;
  int _attachmentVersion = 0;
  Timer? _ticker;

  bool get isPlaying => _playing;
  bool get isReady => _viewId != null && !_loading && _error == null;
  bool get isLoading => _loading;
  bool get ended => _ended;
  Duration get position => _position;
  Duration get duration => _duration;
  Object? get error => _error;

  void attach(int viewId) {
    if (_disposed) return;
    _viewId = viewId;
    _attachmentVersion += 1;
    _playing = false;
    _loading = true;
    _ended = false;
    _position = Duration.zero;
    _error = null;
    _ticker?.cancel();
    unawaited(_refresh(_attachmentVersion));
    notifyListeners();
  }

  Future<void> toggle() async {
    final viewId = _viewId;
    if (viewId == null || !isReady) return;
    final version = _attachmentVersion;
    final wasPlaying = _playing;
    try {
      if (wasPlaying) {
        await gateway.pause(viewId);
      } else {
        await gateway.play(viewId);
      }
      if (_disposed || version != _attachmentVersion) return;
      _playing = !wasPlaying;
      _error = null;
      if (_playing) _startTicker(version);
      await _refresh(version);
    } catch (error) {
      if (_disposed || version != _attachmentVersion) return;
      _ticker?.cancel();
      _playing = false;
      _error = error;
      notifyListeners();
    }
  }

  Future<void> seek(Duration position) async {
    final viewId = _viewId;
    if (viewId == null) return;
    final version = _attachmentVersion;
    try {
      await gateway.seek(viewId, position);
      await _refresh(version);
    } catch (error) {
      if (_disposed || version != _attachmentVersion) return;
      _error = error;
      notifyListeners();
    }
  }

  Future<void> pause() async {
    final viewId = _viewId;
    _ticker?.cancel();
    if (viewId != null) {
      try {
        await gateway.pause(viewId);
      } catch (error) {
        if (!_disposed) _error = error;
      }
    }
    if (_disposed) return;
    _playing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _attachmentVersion += 1;
    _ticker?.cancel();
    super.dispose();
  }

  void _startTicker(int version) {
    _ticker?.cancel();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_refresh(version)),
    );
  }

  Future<void> _refresh(int version) async {
    final viewId = _viewId;
    if (viewId == null) return;
    try {
      final snapshot = await gateway.playbackState(viewId);
      if (_disposed || version != _attachmentVersion) return;
      _position = snapshot.position;
      if (snapshot.duration > Duration.zero) _duration = snapshot.duration;
      _playing = snapshot.isPlaying;
      _loading = snapshot.loading;
      _ended = snapshot.ended;
      _error = null;
      if (snapshot.loading) {
        _startTicker(version);
      } else if (snapshot.ended || !snapshot.isPlaying) {
        _ticker?.cancel();
      }
      notifyListeners();
    } catch (error) {
      if (_disposed || version != _attachmentVersion) return;
      _ticker?.cancel();
      _playing = false;
      _loading = false;
      _error = error;
      notifyListeners();
    }
  }
}

class NativeMovieView extends StatelessWidget {
  const NativeMovieView({
    required this.relativePath,
    required this.gateway,
    required this.controller,
    this.segments = const <PlaybackSegment>[],
    this.fallback,
    super.key,
  });

  final String relativePath;
  final MediaPresentationGateway gateway;
  final MediaPlaybackController controller;
  final List<PlaybackSegment> segments;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return fallback ?? const ColoredBox(color: Colors.black);
    }
    final creationParams = <String, Object?>{
      'relativePath': relativePath,
      if (segments.isNotEmpty)
        'segments': segments.map((segment) => segment.toNativeMap()).toList(),
    };
    return UiKitView(
      viewType: gateway.playbackViewType,
      creationParams: creationParams,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: controller.attach,
    );
  }
}
