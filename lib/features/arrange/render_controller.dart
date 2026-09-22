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
  var _fallbackId = 0;

  RenderState get state =>
      _stateValue ?? (throw StateError('Open a project before rendering.'));

  void open(Project project) {
    final previous = _stateValue;
    final previousId = previous?.operationId;
    if (previousId != null && previous!.phase == RenderPhase.rendering) {
      unawaited(gateway.cancel(previousId));
    }
    _stateValue = RenderState(project: project, phase: RenderPhase.idle);
  }

  String generate(RenderQuality quality) {
    final current = state;
    final project = current.project;
    final previousId = current.operationId;
    final cancelFirst =
        previousId != null && current.phase == RenderPhase.rendering
        ? previousId
        : null;
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
    unawaited(_complete(request, cancelFirst: cancelFirst));
    return operationId;
  }

  Future<void> cancel() async {
    final current = state;
    final operationId = current.operationId;
    if (operationId == null || current.phase != RenderPhase.rendering) return;
    await gateway.cancel(operationId);
    if (state.operationId == operationId) {
      _stateValue = RenderState(
        project: state.project,
        phase: RenderPhase.cancelled,
        operationId: operationId,
      );
    }
  }

  Future<void> _complete(
    RenderRequest request, {
    required String? cancelFirst,
  }) async {
    try {
      if (cancelFirst != null) {
        await gateway.cancel(cancelFirst);
        if (!_isCurrent(request)) return;
      }
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
      state.operationId == request.operationId &&
      state.project.id == request.projectId &&
      state.project.revision == request.revision;

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
