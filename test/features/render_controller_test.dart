import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/project.dart';
import 'package:otogurashi/domain/video_recipe.dart';
import 'package:otogurashi/features/arrange/render_controller.dart';
import 'package:otogurashi/media/media_gateway.dart';

void main() {
  test('render state changes are observable', () async {
    final gateway = _FakeMediaGateway();
    final controller = RenderController(
      gateway: gateway,
      operationIds: _ids(<String>['render']),
    )..open(_projectAtRevision(3));
    var notifications = 0;
    controller.addListener(() => notifications++);

    final operationId = controller.generate(RenderQuality.preview);
    gateway.complete(operationId, revision: 3);
    await pumpEventQueue();

    expect(controller.state.phase, RenderPhase.ready);
    expect(notifications, greaterThanOrEqualTo(2));
  });

  test(
    'completion after disposal is ignored and native work is cancelled',
    () async {
      final gateway = _FakeMediaGateway();
      final controller = RenderController(
        gateway: gateway,
        operationIds: _ids(<String>['render']),
      )..open(_projectAtRevision(3));
      final operationId = controller.generate(RenderQuality.preview);

      controller.dispose();
      gateway.complete(operationId, revision: 3);
      await pumpEventQueue();

      expect(gateway.cancelledOperationIds, contains(operationId));
    },
  );

  test('late render cannot replace current revision', () async {
    final gateway = _FakeMediaGateway();
    final controller = RenderController(
      gateway: gateway,
      operationIds: _ids(<String>['old']),
    );
    controller.open(_projectAtRevision(1));
    final oldId = controller.generate(RenderQuality.preview);

    controller.open(_projectAtRevision(2));
    gateway.complete(oldId, revision: 1);
    await pumpEventQueue();

    expect(controller.state.project.revision, 2);
    expect(controller.state.readyMedia, isNull);
    expect(gateway.cancelledOperationIds, contains(oldId));
  });

  test('starting a new render cancels the previous native job', () async {
    final gateway = _FakeMediaGateway();
    final controller = RenderController(
      gateway: gateway,
      operationIds: _ids(<String>['first', 'second']),
    )..open(_projectAtRevision(3));

    final first = controller.generate(RenderQuality.preview);
    final second = controller.generate(RenderQuality.full);
    await pumpEventQueue();

    expect(first, 'first');
    expect(second, 'second');
    expect(gateway.cancelledOperationIds, contains(first));
    expect(controller.state.operationId, second);
  });

  test(
    'replacement render waits until native cancellation is registered',
    () async {
      final gateway = _FakeMediaGateway()..cancelGate = Completer<void>();
      final controller = RenderController(
        gateway: gateway,
        operationIds: _ids(<String>['first', 'second']),
      )..open(_projectAtRevision(3));
      controller.generate(RenderQuality.preview);

      controller.generate(RenderQuality.full);
      await pumpEventQueue();

      expect(gateway.requests.map((request) => request.operationId), <String>[
        'first',
      ]);
      gateway.cancelGate!.complete();
      await pumpEventQueue();
      expect(gateway.requests.map((request) => request.operationId), <String>[
        'first',
        'second',
      ]);
    },
  );

  test(
    'manual cancellation rejects a completion while native drain is pending',
    () async {
      final gateway = _FakeMediaGateway()..cancelGate = Completer<void>();
      final controller = RenderController(
        gateway: gateway,
        operationIds: _ids(<String>['render']),
      )..open(_projectAtRevision(3));
      final operationId = controller.generate(RenderQuality.preview);

      final cancellation = controller.cancel();
      gateway.complete(operationId, revision: 3);
      await pumpEventQueue();

      expect(controller.state.phase, RenderPhase.cancelled);
      expect(controller.state.readyMedia, isNull);
      gateway.cancelGate!.complete();
      await cancellation;
    },
  );

  test(
    'opening a new project drains the old job before its first render',
    () async {
      final gateway = _FakeMediaGateway()..cancelGate = Completer<void>();
      final controller = RenderController(
        gateway: gateway,
        operationIds: _ids(<String>['old', 'new']),
      )..open(_projectAtRevision(1));
      controller.generate(RenderQuality.preview);

      controller.open(_projectAtRevision(2));
      controller.generate(RenderQuality.preview);
      await pumpEventQueue();

      expect(gateway.requests.map((request) => request.operationId), <String>[
        'old',
      ]);
      gateway.cancelGate!.complete();
      await pumpEventQueue();
      expect(gateway.requests.map((request) => request.operationId), <String>[
        'old',
        'new',
      ]);
    },
  );

  test('cancelling after completion leaves ready media published', () async {
    final gateway = _FakeMediaGateway();
    final controller = RenderController(
      gateway: gateway,
      operationIds: _ids(<String>['render']),
    )..open(_projectAtRevision(3));
    final operationId = controller.generate(RenderQuality.preview);
    gateway.complete(operationId, revision: 3);
    await pumpEventQueue();

    await controller.cancel();

    expect(controller.state.phase, RenderPhase.ready);
    expect(controller.state.readyMedia?.operationId, operationId);
    expect(gateway.cancelledOperationIds, isEmpty);
  });

  test(
    'open handles a failed drain and the next generate retries it',
    () async {
      final gateway = _FakeMediaGateway()..cancelFailuresRemaining = 1;
      final errors = <Object>[];
      final bodyComplete = Completer<void>();

      runZonedGuarded(
        () async {
          try {
            final controller = RenderController(
              gateway: gateway,
              operationIds: _ids(<String>['old', 'new']),
            )..open(_projectAtRevision(1));
            controller.generate(RenderQuality.preview);
            await pumpEventQueue();

            controller.open(_projectAtRevision(2));
            await pumpEventQueue();
            controller.generate(RenderQuality.preview);
            await pumpEventQueue();

            expect(gateway.cancelledOperationIds, <String>['old', 'old']);
            expect(
              gateway.requests.map((request) => request.operationId),
              <String>['old', 'new'],
            );
          } finally {
            bodyComplete.complete();
          }
        },
        (error, stackTrace) {
          errors.add(error);
        },
      );

      await bodyComplete.future;
      expect(errors, isEmpty);
    },
  );

  test(
    'replacement reports a failed drain and a later generate retries it',
    () async {
      final gateway = _FakeMediaGateway()..cancelFailuresRemaining = 1;
      final controller = RenderController(
        gateway: gateway,
        operationIds: _ids(<String>['old', 'blocked', 'recovered']),
      )..open(_projectAtRevision(3));
      controller.generate(RenderQuality.preview);

      controller.generate(RenderQuality.preview);
      await pumpEventQueue();

      expect(controller.state.phase, RenderPhase.failed);
      expect(gateway.cancelledOperationIds, <String>['old']);
      expect(gateway.requests.map((request) => request.operationId), <String>[
        'old',
      ]);

      controller.generate(RenderQuality.preview);
      await pumpEventQueue();

      expect(gateway.cancelledOperationIds, <String>['old', 'old']);
      expect(gateway.requests.map((request) => request.operationId), <String>[
        'old',
        'recovered',
      ]);
    },
  );

  test('preview and full send identical recipes and arrangements', () async {
    final gateway = _FakeMediaGateway();
    final controller = RenderController(
      gateway: gateway,
      operationIds: _ids(<String>['preview', 'full']),
    )..open(_projectAtRevision(4));

    final previewId = controller.generate(RenderQuality.preview);
    gateway.complete(previewId, revision: 4, width: 360, height: 640);
    await pumpEventQueue();
    final fullId = controller.generate(RenderQuality.full);

    final preview = gateway.requests[0];
    final full = gateway.requests[1];
    expect(preview.arrangement.toJson(), full.arrangement.toJson());
    expect(preview.video.toJson(), full.video.toJson());
    expect(preview.quality, RenderQuality.preview);
    expect(full.quality, RenderQuality.full);
    expect(fullId, 'full');
  });
}

Iterator<String> _ids(List<String> values) => values.iterator;

Project _projectAtRevision(int revision) {
  final arrangement = Arrangement(
    templateId: 'fixture',
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: 7,
    style: ArrangementStyle.sparse,
    sourceAssetIds: const <String>['one', 'two', 'three'],
    unusableAssetIds: const <String>[],
    events: const <SoundEvent>[],
    videoEvents: const <VideoEvent>[],
  );
  final recipe = VideoRecipe.fromArrangement(
    arrangement: arrangement,
    layout: VideoLayout.stacked,
  );
  return Project(
    id: 'project',
    title: 'fixture',
    revision: revision,
    clipIds: const <String>['one', 'two', 'three'],
    arrangement: arrangement.toJson(),
    videoRecipe: recipe.toJson(),
    createdAt: DateTime.utc(2026, 9, 22),
    updatedAt: DateTime.utc(2026, 9, 22),
  );
}

final class _FakeMediaGateway implements MediaGateway {
  final List<RenderRequest> requests = <RenderRequest>[];
  final List<String> cancelledOperationIds = <String>[];
  final Map<String, Completer<RenderedMedia>> _renders =
      <String, Completer<RenderedMedia>>{};
  Completer<void>? cancelGate;
  var cancelFailuresRemaining = 0;

  @override
  Stream<MediaEvent> get events => const Stream<MediaEvent>.empty();

  @override
  Future<CaptureHandle> prepareCapture() => throw UnimplementedError();

  @override
  Future<void> startCapture(String operationId, {required int maxDurationUs}) =>
      throw UnimplementedError();

  @override
  Future<CapturedMedia> stopCapture(String operationId) =>
      throw UnimplementedError();

  @override
  Future<CapturedMedia?> pickVideo(String operationId) =>
      throw UnimplementedError();

  @override
  Future<InspectedMedia> inspectStaged(String path) =>
      throw UnimplementedError();

  @override
  Future<void> disposeCapture() async {}

  @override
  Future<AnalyzedClip> analyze(MediaAnalysisRequest request) =>
      throw UnimplementedError();

  @override
  Future<void> cancel(String operationId) async {
    cancelledOperationIds.add(operationId);
    if (cancelFailuresRemaining > 0) {
      cancelFailuresRemaining -= 1;
      throw StateError('cancel failed');
    }
    await cancelGate?.future;
  }

  @override
  Future<RenderedMedia> render(RenderRequest request) {
    requests.add(request);
    final completer = Completer<RenderedMedia>();
    _renders[request.operationId] = completer;
    return completer.future;
  }

  void complete(
    String operationId, {
    required int revision,
    int width = 360,
    int height = 640,
  }) {
    _renders[operationId]!.complete(
      RenderedMedia(
        operationId: operationId,
        projectId: 'project',
        revision: revision,
        relativePath: 'renders/project/$revision/$operationId.mp4',
        durationUs: 15000000,
        width: width,
        height: height,
      ),
    );
  }
}
