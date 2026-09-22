import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/features/capture/capture_controller.dart';
import 'package:otogurashi/features/capture/capture_state.dart';
import 'package:otogurashi/media/media_gateway.dart';
import 'package:otogurashi/media/media_messages.dart';

void main() {
  late _FakeMediaGateway gateway;
  late CaptureController controller;
  var nextId = 0;

  setUp(() {
    gateway = _FakeMediaGateway();
    controller = CaptureController(
      gateway,
      operationIdFactory: () => 'capture-${++nextId}',
    );
  });

  tearDown(() async {
    await controller.releaseCapture();
    controller.dispose();
    await gateway.close();
  });

  test('recording cannot succeed before native readiness', () async {
    gateway.prepareResult = Completer<CaptureHandle>();

    final preparing = controller.prepare();
    await controller.record();

    expect(controller.state.phase, CapturePhase.preparing);
    expect(controller.state.savedAssetId, isNull);
    expect(gateway.startedOperations, isEmpty);
    gateway.prepareResult!.complete(
      const CaptureHandle(previewViewType: 'capture-preview'),
    );
    await preparing;
    expect(controller.state.phase, CapturePhase.ready);
  });

  test('permission denial remains recoverable and records no asset', () async {
    gateway.prepareError = const MediaCaptureException(
      MediaCaptureErrorCode.permissionDenied,
      'Camera and microphone access was denied.',
    );

    await controller.prepare();

    expect(controller.state.phase, CapturePhase.permissionDenied);
    expect(controller.state.savedAssetId, isNull);
    expect(controller.state.canRetry, isTrue);
  });

  test('repeated prepare while preparing invokes native once', () async {
    gateway.prepareResult = Completer<CaptureHandle>();

    final first = controller.prepare();
    final second = controller.prepare();
    expect(gateway.prepareCalls, 1);
    gateway.prepareResult!.complete(
      const CaptureHandle(previewViewType: 'capture-preview'),
    );
    await Future.wait(<Future<void>>[first, second]);

    expect(controller.state.phase, CapturePhase.ready);
    expect(gateway.prepareCalls, 1);
  });

  test('interruption never becomes a successful capture', () async {
    await controller.prepare();
    await controller.record();
    gateway.emit(
      MediaEvent(
        operationId: controller.operationId!,
        type: MediaEventType.interrupted,
        errorCode: MediaCaptureErrorCode.interrupted.name,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.phase, CapturePhase.interrupted);
    expect(controller.state.savedAssetId, isNull);
    expect(controller.state.requiresExplicitResume, isTrue);

    gateway.completeStop(
      CapturedMedia(
        operationId: controller.operationId!,
        assetId: 'late-asset',
        relativePath: 'staging/late.mov',
        durationUs: 3000000,
        audioTrackStartUs: 0,
        width: 1080,
        height: 1920,
        rotation: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.savedAssetId, isNull);
  });

  test('events from an old operation cannot change current capture', () async {
    await controller.prepare();
    await controller.record();

    gateway.emit(
      const MediaEvent(
        operationId: 'capture-old',
        type: MediaEventType.interrupted,
        errorCode: 'interrupted',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.phase, CapturePhase.recording);
  });

  test('partial output is rejected instead of appearing saved', () async {
    await controller.prepare();
    await controller.record();
    gateway.stopError = const MediaCaptureException(
      MediaCaptureErrorCode.incompleteCapture,
      'The recording did not finalize.',
    );

    await controller.stop();

    expect(controller.state.phase, CapturePhase.failed);
    expect(controller.state.savedAssetId, isNull);
  });

  test('finalized media is accepted only for the active operation', () async {
    await controller.prepare();
    await controller.record(maxDurationUs: 6000000);
    gateway.completeStop(
      CapturedMedia(
        operationId: controller.operationId!,
        assetId: 'asset-1',
        relativePath: 'staging/asset-1.mov',
        durationUs: 3250000,
        audioTrackStartUs: 120000,
        width: 1920,
        height: 1080,
        rotation: 90,
      ),
    );

    await controller.stop();

    expect(controller.state.phase, CapturePhase.completed);
    expect(controller.state.savedAssetId, 'asset-1');
    expect(gateway.maxDurationUs, 6000000);
  });

  test(
    'cancelling the Photos picker does not imply camera readiness',
    () async {
      await controller.importVideo();

      expect(controller.state.phase, CapturePhase.idle);
      expect(controller.state.handle, isNull);
      expect(controller.state.savedAssetId, isNull);
    },
  );
}

final class _FakeMediaGateway implements MediaGateway {
  final _events = StreamController<MediaEvent>.broadcast(sync: true);
  Completer<CaptureHandle>? prepareResult;
  Object? prepareError;
  Object? stopError;
  CapturedMedia? _stopResult;
  int prepareCalls = 0;
  int? maxDurationUs;
  final startedOperations = <String>[];

  void emit(MediaEvent event) => _events.add(event);
  void completeStop(CapturedMedia media) => _stopResult = media;
  Future<void> close() => _events.close();

  @override
  Stream<MediaEvent> get events => _events.stream;

  @override
  Future<CaptureHandle> prepareCapture() async {
    prepareCalls += 1;
    if (prepareError case final error?) throw error;
    return prepareResult == null
        ? const CaptureHandle(previewViewType: 'capture-preview')
        : prepareResult!.future;
  }

  @override
  Future<void> startCapture(
    String operationId, {
    required int maxDurationUs,
  }) async {
    startedOperations.add(operationId);
    this.maxDurationUs = maxDurationUs;
  }

  @override
  Future<CapturedMedia> stopCapture(String operationId) async {
    if (stopError case final error?) throw error;
    return _stopResult ??
        CapturedMedia(
          operationId: operationId,
          assetId: 'asset',
          relativePath: 'staging/asset.mov',
          durationUs: 3000000,
          audioTrackStartUs: 0,
          width: 1080,
          height: 1920,
          rotation: 0,
        );
  }

  @override
  Future<CapturedMedia?> pickVideo(String operationId) async => null;

  @override
  Future<InspectedMedia> inspectStaged(String path) =>
      throw UnimplementedError();

  @override
  Future<void> disposeCapture() async {}

  @override
  Future<AnalyzedClip> analyze(MediaAnalysisRequest request) =>
      throw UnimplementedError();

  @override
  Future<RenderedMedia> render(RenderRequest request) =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String operationId) async {}
}
