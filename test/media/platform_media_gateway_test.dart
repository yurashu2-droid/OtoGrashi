import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/video_recipe.dart';
import 'package:otogurashi/media/media_gateway.dart';
import 'package:otogurashi/media/platform_media_gateway.dart';

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
            'managedRoot' => '/application-support/OtoGrashi',
            'prepareCapture' => <String, Object?>{
              'previewViewType': 'dev.otogurashi/capture-preview',
            },
            'startCapture' => null,
            'stopCapture' => <String, Object?>{
              'operationId': 'capture-1',
              'assetId': 'asset-1',
              'relativePath': 'staging/asset-1.mov',
              'durationUs': 3000000,
              'audioTrackStartUs': 120000,
              'width': 1080,
              'height': 1920,
              'rotation': 90,
            },
            'inspectStaged' => <String, Object?>{
              'durationUs': 3000000,
              'audioTrackStartUs': 120000,
              'width': 1080,
              'height': 1920,
              'rotation': 90,
            },
            'disposeCapture' => null,
            'render' => <String, Object?>{
              'operationId': 'render-1',
              'projectId': 'project',
              'revision': 2,
              'relativePath': 'renders/project/2/render-1.mp4',
              'durationUs': 15000000,
              'width': 360,
              'height': 640,
            },
            'cancel' => null,
            _ => throw PlatformException(code: 'unimplemented'),
          };
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'render sends one versioned recipe and receives a relative path',
    () async {
      final gateway = PlatformMediaGateway(channel: channel);

      final media = await gateway.render(_request());

      final arguments = (calls.single.arguments as Map<Object?, Object?>)
          .cast<String, Object?>();
      expect(calls.single.method, 'render');
      expect(arguments['schemaVersion'], 1);
      expect(arguments['quality'], 'preview');
      expect(
        (arguments['video'] as Map<Object?, Object?>)['layout'],
        'stacked',
      );
      expect(media.relativePath, 'renders/project/2/render-1.mp4');
    },
  );

  test('managed root and cancellation use the shared media plugin', () async {
    final gateway = PlatformMediaGateway(channel: channel);

    expect(await gateway.managedRoot(), '/application-support/OtoGrashi');
    await gateway.cancel('render-1');

    expect(calls.map((call) => call.method), <String>['managedRoot', 'cancel']);
    expect(calls.last.arguments, <String, Object?>{'operationId': 'render-1'});
  });

  test('capture and inspection stay on the shared media plugin', () async {
    final gateway = PlatformMediaGateway(channel: channel);

    final handle = await gateway.prepareCapture();
    await gateway.startCapture('capture-1', maxDurationUs: 3000000);
    final media = await gateway.stopCapture('capture-1');
    final inspected = await gateway.inspectStaged(
      r'C:\Application Support\OtoGrashi\staging\copy.partial.mov',
    );
    await gateway.disposeCapture();

    expect(handle.previewViewType, 'dev.otogurashi/capture-preview');
    expect(media.operationId, 'capture-1');
    expect(media.audioTrackStartUs, 120000);
    expect(inspected.audioTrackStartUs, 120000);
    expect(calls.map((call) => call.method), <String>[
      'prepareCapture',
      'startCapture',
      'stopCapture',
      'inspectStaged',
      'disposeCapture',
    ]);
    expect(calls[1].arguments, <String, Object?>{
      'operationId': 'capture-1',
      'maxDurationUs': 3000000,
    });
  });
}

RenderRequest _request() {
  final arrangement = Arrangement(
    templateId: 'fixture',
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: 1,
    style: ArrangementStyle.sparse,
    sourceAssetIds: const <String>['one', 'two', 'three'],
    unusableAssetIds: const <String>[],
    events: const <SoundEvent>[],
    videoEvents: const <VideoEvent>[],
  );
  return RenderRequest(
    operationId: 'render-1',
    projectId: 'project',
    revision: 2,
    arrangement: arrangement,
    video: VideoRecipe.fromArrangement(
      arrangement: arrangement,
      layout: VideoLayout.stacked,
    ),
    quality: RenderQuality.preview,
  );
}
