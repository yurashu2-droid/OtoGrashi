import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/features/export/media_playback.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('rapid taps serialize to play then pause, not two plays', () async {
    final gateway = _Player();
    final controller = MediaPlaybackController(gateway)..attach(1);
    await Future<void>.delayed(Duration.zero);
    final first = controller.toggle();
    final second = controller.toggle();
    gateway.ready.complete();
    await Future.wait([first, second]);
    expect(gateway.commands, ['play:1', 'pause:1']);
    expect(controller.isPlaying, isFalse);
    controller.dispose();
  });
  test('disposing during play completion cannot leave orphan audio', () async {
    final gateway = _Player();
    final controller = MediaPlaybackController(gateway)..attach(2);
    await Future<void>.delayed(Duration.zero);
    final playing = controller.toggle();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    gateway.ready.complete();
    await playing;
    expect(gateway.playing, isFalse);
    expect(gateway.commands.last, 'pause:2');
  });
  test('reattaching stops the old player and resets duration', () async {
    final gateway = _Player()..ready.complete();
    final controller = MediaPlaybackController(gateway)..attach(3);
    await Future<void>.delayed(Duration.zero);
    await controller.toggle();
    controller.attach(4);
    await Future<void>.delayed(Duration.zero);
    expect(gateway.commands, contains('pause:3'));
    expect(controller.isPlaying, isFalse);
    controller.dispose();
  });
}

class _Player implements MediaPresentationGateway {
  final ready = Completer<void>();
  final commands = <String>[];
  bool playing = false;
  @override
  String get playbackViewType => 'test';
  @override
  Future<void> play(int id) async {
    commands.add('play:$id');
    await ready.future;
    playing = true;
  }

  @override
  Future<void> pause(int id) async {
    commands.add('pause:$id');
    playing = false;
  }

  @override
  Future<void> seek(int id, Duration pos) async {}
  @override
  Future<Duration> position(int id) async => Duration.zero;
  @override
  Future<PlaybackSnapshot> playbackState(int id) async => PlaybackSnapshot(
    position: Duration.zero,
    duration: const Duration(seconds: 2),
    isPlaying: playing,
    ended: false,
  );
  @override
  Future<Uint8List> thumbnail(String path) async => Uint8List(0);
  @override
  Future<AudioWaveform> waveform(String path) async =>
      AudioWaveform(durationUs: 1, levels: [0]);
}
