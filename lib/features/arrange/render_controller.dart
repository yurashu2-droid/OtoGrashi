import 'dart:async';

import '../../domain/arrangement.dart';
import '../../domain/project.dart';
import '../../domain/video_recipe.dart';
import '../../media/media_gateway.dart';

enum RenderPhase { idle, rendering, ready, failed, cancelled }

final class RenderState {
  const RenderState({
    required this.project,
    required this.phase,
    this.operationId,
    this.readyMedia,
    this.error,
  });

  final Project project;
  final RenderPhase phase;
  final String? operationId;
  final RenderedMedia? readyMedia;
  final Object? error;
}

final class RenderController {
  RenderController({required this.gateway, this.operationIds});

  final MediaGateway gateway;
  final Iterator<String>? operationIds;
  RenderState? _stateValue;
  Future<void> _cancellationBarrier = Future<void>.value();
  var _pendingCancellationCount = 0;
  var _fallbackId = 0;

  RenderState get state =>
      _stateValue ?? (throw StateError('Open a project before rendering.'));

  void open(Project project) {
    final previous = _stateValue;
    final previousId = previous?.operationId;
    if (previousId != null && previous!.phase == RenderPhase.rendering) {
      _enqueueCancellation(previousId);
    }
    _stateValue = RenderState(project: project, phase: RenderPhase.idle);
  }

  String generate(RenderQuality quality) {
    final current = state;
    final project = current.project;
    final previousId = current.operationId;
    if (previousId != null && current.phase == RenderPhase.rendering) {
      _enqueueCancellation(previousId);
    }
    final operationId = _nextOperationId();
    final request = RenderRequest(
      operationId: operationId,
      projectId: project.id,
      revision: project.revision,
      arrangement: Arrangement.fromJson(project.arrangement),
      video: VideoRecipe.fromJson(project.videoRecipe),
      quality: quality,
    );
    _stateValue = RenderState(
      project: project,
      phase: RenderPhase.rendering,
      operationId: operationId,
    );
    unawaited(_complete(request));
    return operationId;
  }

  Future<void> cancel() async {
    final current = state;
    final operationId = current.operationId;
    if (operationId == null || current.phase != RenderPhase.rendering) return;
    _stateValue = RenderState(
      project: current.project,
      phase: RenderPhase.cancelled,
      operationId: operationId,
    );
    await _enqueueCancellation(operationId);
  }

  Future<void> _complete(RenderRequest request) async {
    try {
      if (_pendingCancellationCount > 0) {
        await _cancellationBarrier;
      }
      if (!_isCurrent(request)) return;
      final media = await gateway.render(request);
      if (!_isCurrent(request) ||
          media.operationId != request.operationId ||
          media.projectId != request.projectId ||
          media.revision != request.revision) {
        return;
      }
      _stateValue = RenderState(
        project: state.project,
        phase: RenderPhase.ready,
        operationId: request.operationId,
        readyMedia: media,
      );
    } catch (error) {
      if (!_isCurrent(request)) return;
      _stateValue = RenderState(
        project: state.project,
        phase: RenderPhase.failed,
        operationId: request.operationId,
        error: error,
      );
    }
  }

  bool _isCurrent(RenderRequest request) =>
      state.phase == RenderPhase.rendering &&
      state.operationId == request.operationId &&
      state.project.id == request.projectId &&
      state.project.revision == request.revision;

  Future<void> _enqueueCancellation(String operationId) {
    _pendingCancellationCount += 1;
    final next = _cancellationBarrier
        .then((_) => gateway.cancel(operationId))
        .whenComplete(() => _pendingCancellationCount -= 1);
    _cancellationBarrier = next;
    return next;
  }

  String _nextOperationId() {
    final ids = operationIds;
    if (ids != null) {
      if (!ids.moveNext()) {
        throw StateError('Operation id source was exhausted.');
      }
      return ids.current;
    }
    _fallbackId += 1;
    return 'render-${DateTime.now().microsecondsSinceEpoch}-$_fallbackId';
  }
}
