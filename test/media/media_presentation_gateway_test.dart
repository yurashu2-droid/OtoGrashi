import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';
import 'package:otogurashi/media/platform_media_gateway.dart';
import 'package:otogurashi/features/export/media_playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(PlatformMediaGateway.channelName);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'thumbnail' => Uint8List.fromList(<int>[1, 2, 3]),
            'waveform' => <String, Object?>{
              'durationUs': 4000000,
              'levels': <double>[0, 0, 0.8, 1, 0, 0, 0, 0],
            },
            'playbackPosition' => 1250000,
            'playbackState' => <String, Object?>{
              'positionUs': 1250000,
              'durationUs': 15000000,
              'isPlaying': false,
              'ended': true,
            },
            _ => null,
          };
        });
  });

  test('waveform locates a loud moment in the source video', () async {
    final gateway = PlatformMediaPresentationGateway(channel: channel);
    final waveform = await gateway.waveform('originals/clip.mp4');

    expect(waveform.levels.length, 8);
    expect(waveform.strongestWindowStart(1000000), 1000000);
    expect(calls.single.method, 'waveform');
    expect(calls.single.arguments, {'relativePath': 'originals/clip.mp4'});
  });

  test('waveform does not suggest a region in flat audio', () {
    final waveform = AudioWaveform(
      durationUs: 3000000,
      levels: List<double>.filled(96, 0.4),
    );
    expect(waveform.strongestWindowStart(1000000), isNull);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'thumbnail and AVPlayer controls share the existing media channel',
    () async {
      final gateway = PlatformMediaPresentationGateway(channel: channel);

      expect(await gateway.thumbnail('originals/clip.mp4'), <int>[1, 2, 3]);
      await gateway.play(7);
      await gateway.seek(7, const Duration(milliseconds: 750));
      expect(await gateway.position(7), const Duration(milliseconds: 1250));
      final state = await gateway.playbackState(7);
      expect(state.ended, isTrue);
      expect(state.duration, const Duration(seconds: 15));
      await gateway.pause(7);

      expect(calls.map((call) => call.method), <String>[
        'thumbnail',
        'playbackPlay',
        'playbackSeek',
        'playbackPosition',
        'playbackState',
        'playbackPause',
      ]);
      expect(calls[2].arguments, <String, Object?>{
        'viewId': 7,
        'positionUs': 750000,
      });
    },
  );

  test(
    'playback completion after dispose does not publish stale state',
    () async {
      final gateway = _DeferredPresentation();
      final controller = MediaPlaybackController(gateway)..attach(4);

      final toggle = controller.toggle();
      controller.dispose();
      gateway.playCompletion.complete();
      await toggle;

      expect(gateway.playedViewId, 4);
    },
  );

  test('ended playback refreshes and a new play starts from zero', () async {
    final gateway = _ReplayPresentation();
    final controller = MediaPlaybackController(gateway)..attach(9);
    addTearDown(controller.dispose);
    await Future<void>.delayed(Duration.zero);

    expect(controller.isPlaying, isFalse);
    expect(controller.position, const Duration(seconds: 15));
    await controller.toggle();

    expect(gateway.playCount, 1);
    expect(controller.isPlaying, isTrue);
    expect(controller.position, Duration.zero);
  });

  test('a late state from a disposed platform view is ignored', () async {
    final gateway = _StaleViewPresentation();
    final controller = MediaPlaybackController(gateway)..attach(1);
    addTearDown(controller.dispose);
    controller.attach(2);
    await Future<void>.delayed(Duration.zero);
    expect(controller.position, const Duration(seconds: 2));

    gateway.first.complete(
      const PlaybackSnapshot(
        position: Duration(seconds: 12),
        duration: Duration(seconds: 15),
        isPlaying: true,
        ended: false,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.position, const Duration(seconds: 2));
    expect(controller.isPlaying, isFalse);
  });
}

final class _DeferredPresentation implements MediaPresentationGateway {
  @override
  Future<AudioWaveform> waveform(String relativePath) async =>
      AudioWaveform(durationUs: 3000000, levels: List<double>.filled(96, 0.4));
  final playCompletion = Completer<void>();
  int? playedViewId;

  @override
  String get playbackViewType => 'test-playback';
  @override
  Future<void> play(int viewId) {
    playedViewId = viewId;
    return playCompletion.future;
  }

  @override
  Future<void> pause(int viewId) async {}
  @override
  Future<void> seek(int viewId, Duration position) async {}
  @override
  Future<Duration> position(int viewId) async => Duration.zero;
  @override
  Future<PlaybackSnapshot> playbackState(int viewId) async =>
      const PlaybackSnapshot(
        position: Duration.zero,
        duration: Duration(seconds: 15),
        isPlaying: true,
        ended: false,
      );
  @override
  Future<Uint8List> thumbnail(String relativePath) async => Uint8List(0);
}

final class _ReplayPresentation implements MediaPresentationGateway {
  @override
  Future<AudioWaveform> waveform(String relativePath) async =>
      AudioWaveform(durationUs: 3000000, levels: List<double>.filled(96, 0.4));
  var playCount = 0;

  @override
  String get playbackViewType => 'test-playback';
  @override
  Future<void> play(int viewId) async {
    playCount += 1;
  }

  @override
  Future<void> pause(int viewId) async {}
  @override
  Future<void> seek(int viewId, Duration position) async {}
  @override
  Future<Duration> position(int viewId) async => Duration.zero;
  @override
  Future<PlaybackSnapshot> playbackState(int viewId) async => playCount == 0
      ? const PlaybackSnapshot(
          position: Duration(seconds: 15),
          duration: Duration(seconds: 15),
          isPlaying: false,
          ended: true,
        )
      : const PlaybackSnapshot(
          position: Duration.zero,
          duration: Duration(seconds: 15),
          isPlaying: true,
          ended: false,
        );
  @override
  Future<Uint8List> thumbnail(String relativePath) async => Uint8List(0);
}

final class _StaleViewPresentation implements MediaPresentationGateway {
  @override
  Future<AudioWaveform> waveform(String relativePath) async =>
      AudioWaveform(durationUs: 3000000, levels: List<double>.filled(96, 0.4));
  final first = Completer<PlaybackSnapshot>();

  @override
  String get playbackViewType => 'test-playback';
  @override
  Future<PlaybackSnapshot> playbackState(int viewId) => viewId == 1
      ? first.future
      : Future.value(
          const PlaybackSnapshot(
            position: Duration(seconds: 2),
            duration: Duration(seconds: 15),
            isPlaying: false,
            ended: false,
          ),
        );
  @override
  Future<void> play(int viewId) async {}
  @override
  Future<void> pause(int viewId) async {}
  @override
  Future<void> seek(int viewId, Duration position) async {}
  @override
  Future<Duration> position(int viewId) async => Duration.zero;
  @override
  Future<Uint8List> thumbnail(String relativePath) async => Uint8List(0);
}
