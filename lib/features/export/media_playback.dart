import 'dart:async';
import 'dart:convert';

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

final class MediaPlaybackController extends ChangeNotifier
    with WidgetsBindingObserver {
  MediaPlaybackController(this.gateway) {
    WidgetsBinding.instance.addObserver(this);
  }

  final MediaPresentationGateway gateway;
  int? _viewId;
  bool _playing = false, _loading = false, _ended = false, _disposed = false;
  bool _busy = false;
  Duration _position = Duration.zero, _duration = Duration.zero;
  Object? _error;
  int _attachmentVersion = 0, _stateRequest = 0;
  Timer? _ticker;
  Future<void>? _pending;

  bool get isPlaying => _playing;
  bool get isReady => _viewId != null && !_loading && _error == null;
  bool get isLoading => _loading;
  bool get ended => _ended;
  Duration get position => _position;
  Duration get duration => _duration;
  Object? get error => _error;

  void attach(int viewId) {
    if (_disposed) {
      unawaited(_silence(viewId));
      return;
    }
    if (_viewId != null) detach(_viewId!);
    _viewId = viewId;
    _attachmentVersion++;
    _playing = false;
    _loading = true;
    _ended = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _error = null;
    _busy = false;
    _pending = null;
    unawaited(_refresh(_attachmentVersion));
    notifyListeners();
  }

  // A platform view may go away while its parent keeps the controller.
  // Invalidate state replies and silence that exact native view, not its replacement.
  void detach(int viewId) {
    if (_viewId != viewId) return;
    _viewId = null;
    _attachmentVersion++;
    _stateRequest++;
    _ticker?.cancel();
    _playing = false;
    _loading = false;
    unawaited(_silence(viewId));
  }

  Future<void> toggle() {
    if (!isReady) return Future<void>.value();
    return _schedule((id) async {
      if (_playing) {
        await gateway.pause(id);
      } else {
        await gateway.play(id);
      }
    });
  }

  Future<void> seek(Duration position) => _schedule((id) async {
    final maximum = _duration > Duration.zero
        ? _duration.inMicroseconds
        : position.inMicroseconds;
    final bounded = position.inMicroseconds.clamp(0, maximum < 0 ? 0 : maximum);
    await gateway.seek(id, Duration(microseconds: bounded.toInt()));
  });

  Future<void> pause() => _schedule(gateway.pause);

  Future<void> _schedule(Future<void> Function(int) action) {
    final id = _viewId;
    final version = _attachmentVersion;
    if (_disposed || id == null) return Future<void>.value();
    final previous = _pending;
    Future<void> run() async {
      if (previous != null) await previous;
      if (_disposed || version != _attachmentVersion) return;
      _busy = true;
      _stateRequest++;
      try {
        await action(id);
        if (_disposed || version != _attachmentVersion) {
          // A delayed play/seek completion must never resurrect an offscreen player.
          await _silence(id);
          return;
        }
        await _refresh(version, force: true);
      } catch (error) {
        if (!_disposed && version == _attachmentVersion) {
          _error = error;
          _playing = false;
          _ticker?.cancel();
          notifyListeners();
        }
      } finally {
        if (version == _attachmentVersion) _busy = false;
      }
    }

    final future = run();
    _pending = future;
    return future.whenComplete(() {
      if (identical(_pending, future)) _pending = null;
    });
  }

  Future<void> _silence(int id) async {
    try {
      await gateway.pause(id);
    } catch (_) {
      /* The native view may already be gone. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(pause());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_viewId case final id?) detach(id);
    _disposed = true;
    _ticker?.cancel();
    super.dispose();
  }

  void _startTicker(int version) {
    if (_ticker?.isActive == true) return;
    _ticker = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => unawaited(_refresh(version)),
    );
  }

  Future<void> _refresh(int version, {bool force = false}) async {
    final id = _viewId;
    if (id == null ||
        _disposed ||
        version != _attachmentVersion ||
        (_busy && !force)) {
      return;
    }
    final request = ++_stateRequest;
    try {
      final state = await gateway.playbackState(id);
      if (_disposed ||
          version != _attachmentVersion ||
          request != _stateRequest) {
        return;
      }
      _position = state.position;
      if (state.duration > Duration.zero) _duration = state.duration;
      _playing = state.isPlaying;
      _loading = state.loading;
      _ended = state.ended;
      _error = null;
      if (_loading || _playing) {
        _startTicker(version);
      } else {
        _ticker?.cancel();
      }
      notifyListeners();
    } catch (error) {
      if (_disposed ||
          version != _attachmentVersion ||
          request != _stateRequest) {
        return;
      }
      _ticker?.cancel();
      _playing = false;
      _loading = false;
      _error = error;
      notifyListeners();
    }
  }
}

class NativeMovieView extends StatefulWidget {
  const NativeMovieView({
    required this.relativePath,
    required this.gateway,
    required this.controller,
    this.segments = const <PlaybackSegment>[],
    this.fallback,
    this.aspectFitVideo = false,
    super.key,
  });

  final String relativePath;
  final MediaPresentationGateway gateway;
  final MediaPlaybackController controller;
  final List<PlaybackSegment> segments;
  final Widget? fallback;
  final bool aspectFitVideo;

  String get mediaIdentity => jsonEncode([
    relativePath,
    aspectFitVideo,
    segments.map((segment) => segment.toNativeMap()).toList(),
  ]);

  @override
  State<NativeMovieView> createState() => _NativeMovieViewState();
}

class _NativeMovieViewState extends State<NativeMovieView> {
  int? _attached;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant NativeMovieView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mediaIdentity != widget.mediaIdentity ||
        oldWidget.controller != widget.controller ||
        oldWidget.gateway != widget.gateway) {
      if (_attached case final id?) oldWidget.controller.detach(id);
      _attached = null;
      _generation++;
    }
  }

  @override
  void dispose() {
    if (_attached case final id?) widget.controller.detach(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return widget.fallback ?? const ColoredBox(color: Colors.black);
    }
    final generation = _generation;
    final creationParams = <String, Object?>{
      'relativePath': widget.relativePath,
      'aspectFitVideo': widget.aspectFitVideo,
      if (widget.segments.isNotEmpty)
        'segments': widget.segments
            .map((segment) => segment.toNativeMap())
            .toList(),
    };
    return UiKitView(
      // creationParams are only read once by UIKit: trim changes need a new view.
      key: ValueKey('${widget.mediaIdentity}:$_generation'),
      viewType: widget.gateway.playbackViewType,
      creationParams: creationParams,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: (id) {
        if (!mounted || generation != _generation) return;
        _attached = id;
        widget.controller.attach(id);
      },
    );
  }
}
