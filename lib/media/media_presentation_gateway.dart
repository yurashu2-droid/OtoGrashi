import 'package:flutter/services.dart';

import 'platform_media_gateway.dart';

abstract interface class MediaPresentationGateway {
  String get playbackViewType;
  Future<Uint8List> thumbnail(String relativePath);
  Future<AudioWaveform> waveform(String relativePath);
  Future<void> play(int viewId);
  Future<void> pause(int viewId);
  Future<void> seek(int viewId, Duration position);
  Future<Duration> position(int viewId);
  Future<PlaybackSnapshot> playbackState(int viewId);
}

final class AudioWaveform {
  AudioWaveform({required this.durationUs, required List<double> levels})
    : levels = List<double>.unmodifiable(levels) {
    if (durationUs <= 0 ||
        levels.isEmpty ||
        levels.any((level) => !level.isFinite || level < 0 || level > 1)) {
      throw const FormatException('Invalid audio waveform.');
    }
  }

  final int durationUs;
  final List<double> levels;

  factory AudioWaveform.fromJson(Map<String, Object?> value) {
    final duration = value['durationUs'];
    final rawLevels = value['levels'];
    if (duration is! num || rawLevels is! List) {
      throw const FormatException('Malformed audio waveform.');
    }
    return AudioWaveform(
      durationUs: duration.toInt(),
      levels: rawLevels.map((value) => (value as num).toDouble()).toList(),
    );
  }

  int? strongestWindowStart(int windowUs) {
    if (windowUs <= 0 || windowUs > durationUs) return null;
    final count = (windowUs * levels.length / durationUs).ceil().clamp(
      1,
      levels.length,
    );
    var total = 0.0;
    for (var index = 0; index < count; index++) {
      total += levels[index] * levels[index];
    }
    var strongest = total;
    var strongestIndex = 0;
    var windowTotal = total;
    var windowCount = 1;
    for (var index = count; index < levels.length; index++) {
      total +=
          levels[index] * levels[index] -
          levels[index - count] * levels[index - count];
      windowTotal += total;
      windowCount += 1;
      if (total > strongest) {
        strongest = total;
        strongestIndex = index - count + 1;
      }
    }
    if (strongest <= 0 || strongest < windowTotal / windowCount * 1.15) {
      return null;
    }
    return (strongestIndex * durationUs ~/ levels.length).clamp(
      0,
      durationUs - windowUs,
    );
  }
}

final class PlaybackSnapshot {
  const PlaybackSnapshot({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.ended,
    this.loading = false,
  });

  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool ended;
  final bool loading;
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
  Future<AudioWaveform> waveform(String relativePath) async {
    final value = await _channel.invokeMapMethod<String, Object?>(
      'waveform',
      <String, Object?>{'relativePath': relativePath},
    );
    if (value == null) throw const FormatException('Audio waveform is empty.');
    return AudioWaveform.fromJson(value);
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
      loading: value['loading'] as bool? ?? false,
    );
  }
}
