import 'package:flutter/services.dart';

import 'platform_media_gateway.dart';

abstract interface class MediaPresentationGateway {
  String get playbackViewType;
  Future<Uint8List> thumbnail(String relativePath);
  Future<void> play(int viewId);
  Future<void> pause(int viewId);
  Future<void> seek(int viewId, Duration position);
  Future<Duration> position(int viewId);
  Future<PlaybackSnapshot> playbackState(int viewId);
}

final class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.ended,
  });

  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool ended;
}

final class PlatformMediaPresentationGateway
    implements MediaPresentationGateway {
  PlatformMediaPresentationGateway({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(PlatformMediaGateway.channelName);

  final MethodChannel _channel;

  @override
  String get playbackViewType => 'dev.otogurashi/playback-view';

  @override
  Future<Uint8List> thumbnail(String relativePath) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'thumbnail',
      <String, Object?>{'relativePath': relativePath},
    );
    if (bytes == null || bytes.isEmpty) {
      throw const FormatException('Thumbnail data is empty.');
    }
    return bytes;
  }

  @override
  Future<void> play(int viewId) => _channel.invokeMethod<void>(
    'playbackPlay',
    <String, Object?>{'viewId': viewId},
  );

  @override
  Future<void> pause(int viewId) => _channel.invokeMethod<void>(
    'playbackPause',
    <String, Object?>{'viewId': viewId},
  );

  @override
  Future<void> seek(int viewId, Duration position) =>
      _channel.invokeMethod<void>('playbackSeek', <String, Object?>{
        'viewId': viewId,
        'positionUs': position.inMicroseconds,
      });

  @override
  Future<Duration> position(int viewId) async {
    final value = await _channel.invokeMethod<int>(
      'playbackPosition',
      <String, Object?>{'viewId': viewId},
    );
    return Duration(microseconds: value ?? 0);
  }

  @override
  Future<PlaybackSnapshot> playbackState(int viewId) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'playbackState',
      <String, Object?>{'viewId': viewId},
    );
    if (value == null) throw const FormatException('Playback state is empty.');
    return PlaybackSnapshot(
      position: Duration(microseconds: (value['positionUs'] as num).toInt()),
      duration: Duration(microseconds: (value['durationUs'] as num).toInt()),
      isPlaying: value['isPlaying'] as bool,
      ended: value['ended'] as bool,
    );
  }
}
