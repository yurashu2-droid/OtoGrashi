import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/clip_asset.dart';
import 'package:otogurashi/features/create/clip_card.dart';
import 'package:otogurashi/features/create/clip_range_preview.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  var createdViews = 0;

  setUp(() {
    createdViews = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async {
        if (call.method == 'create') createdViews++;
        return null;
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    );
  });

  testWidgets(
    'scrubbing keeps latest target, waveform playhead and source view',
    (tester) async {
      final gateway = _RangePlayer();
      var saves = 0;
      await _openTrim(tester, gateway, onSave: (_, _) async => saves++);
      expect(gateway.currentUs, 500000);
      gateway.seeks.clear();
      final delayedSeek = Completer<void>();
      gateway.nextSeek = delayedSeek;

      await _changeRange(tester, .5, 2.4);
      expect(gateway.seeks, [2400000]);
      await _changeRange(tester, .5, 2.1);
      await _changeRange(tester, .5, 1.8);
      expect(gateway.seeks, [2400000]);
      final preview = tester.widget<ClipRangePreview>(
        find.byType(ClipRangePreview),
      );
      expect(preview.positionNotifier!.value, 1800000);
      final dynamic painter = tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('trim-waveform-playhead')),
          )
          .painter;
      expect(painter.playheadUs, 1800000);

      delayedSeek.complete();
      await tester.pumpAndSettle();
      expect(gateway.seeks, [2400000, 1800000]);
      expect(createdViews, 1);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{TargetPlatform.iOS}),
  );

  testWidgets(
    'range replay seeks to selected start and stops at selected end',
    (tester) async {
      final gateway = _RangePlayer();
      await _openTrim(tester, gateway);
      await _changeRange(tester, .8, 2.5);
      await _changeRange(tester, .8, 2.2);
      await tester.pumpAndSettle();
      expect(gateway.currentUs, 2200000);

      await tester.tap(find.text('選んだ範囲を再生'));
      await tester.pump();
      expect(gateway.seeks.last, 800000);
      expect(gateway.playing, isTrue);
      expect(gateway.commands.last, 'play');

      gateway.currentUs = 2250000;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(gateway.playing, isFalse);
      expect(gateway.seeks.last, 2200000);
      expect(createdViews, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{TargetPlatform.iOS}),
  );

  testWidgets(
    'closing during a pending play silences late native completion',
    (tester) async {
      final gateway = _RangePlayer();
      await _openTrim(tester, gateway);
      final delayedPlay = Completer<void>();
      gateway.nextPlay = delayedPlay;
      await tester.tap(find.text('選んだ範囲を再生'));
      await tester.pump();
      expect(gateway.commands.last, 'play');

      await tester.pumpWidget(const SizedBox.shrink());
      expect(gateway.commands.last, 'pause');
      delayedPlay.complete();
      await tester.pump();
      expect(gateway.playing, isFalse);
      expect(gateway.commands.last, 'pause');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{TargetPlatform.iOS}),
  );
}

Future<void> _openTrim(
  WidgetTester tester,
  _RangePlayer gateway, {
  Future<void> Function(int, int)? onSave,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showClipTrimSheet(
              context,
              clip: _clip,
              waveform: gateway.waveform(_clip.relativePath),
              presentation: gateway,
              selectionStartUs: 500000,
              selectionDurationUs: 2000000,
              onSave: onSave ?? (_, _) async {},
            ),
            child: const Text('範囲を選ぶ'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('範囲を選ぶ'));
  await tester.pumpAndSettle();
}

Future<void> _changeRange(WidgetTester tester, double start, double end) async {
  tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(
    RangeValues(start * 1e6, end * 1e6),
  );
  await tester.pump();
  // The position notifier publishes after build; repaint the waveform next frame.
  await tester.pump();
}

const _clip = ClipAsset(
  id: 'recording',
  relativePath: 'originals/recording.mp4',
  durationUs: 4000000,
  selectionStartUs: 500000,
  selectionDurationUs: 2000000,
  width: 1080,
  height: 1920,
  rotation: 0,
  sha256: 'test',
  label: 'コップの音',
);

class _RangePlayer implements MediaPresentationGateway {
  final seeks = <int>[];
  final commands = <String>[];
  Completer<void>? nextSeek;
  Completer<void>? nextPlay;
  var currentUs = 0;
  var playing = false;

  @override
  String get playbackViewType => 'range-test';

  @override
  Future<void> seek(int id, Duration position) async {
    seeks.add(position.inMicroseconds);
    final pending = nextSeek;
    nextSeek = null;
    if (pending != null) await pending.future;
    currentUs = position.inMicroseconds;
  }

  @override
  Future<void> play(int id) async {
    commands.add('play');
    final pending = nextPlay;
    nextPlay = null;
    if (pending != null) await pending.future;
    playing = true;
  }

  @override
  Future<void> pause(int id) async {
    commands.add('pause');
    playing = false;
  }

  @override
  Future<PlaybackSnapshot> playbackState(int id) async => PlaybackSnapshot(
    position: Duration(microseconds: currentUs),
    duration: const Duration(seconds: 4),
    isPlaying: playing,
    ended: false,
  );

  @override
  Future<Duration> position(int id) async => Duration(microseconds: currentUs);

  @override
  Future<Uint8List> thumbnail(String path) async => Uint8List(0);

  @override
  Future<AudioWaveform> waveform(String path) async =>
      AudioWaveform(durationUs: 4000000, levels: [.2, .2, .2, .2]);
}
