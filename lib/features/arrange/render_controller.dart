import 'dart:async';

import 'package:flutter/foundation.dart';

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

final class RenderController extends ChangeNotifier {
  RenderController({required this.gateway, this.operationIds});

  final MediaGateway gateway;
  final Iterator<String>? operationIds;
  RenderState? _stateValue;
  Future<void> _cancellationQueueTail = Future<void>.value();
  String? _undrainedOperationId;
  Future<void>? _drainAttempt;
  var _fallbackId = 0;
  var _disposed = false;

  RenderState get state =>
      _stateValue ?? (throw StateError('Open a project before rendering.'));

  void open(Project project) {
    final previous = _stateValue;
    final previousId = previous?.operationId;
    final drain = _requiredDrain(
      previous?.phase == RenderPhase.rendering ? previousId : null,
    );
    if (drain != null) {
      unawaited(drain.catchError((Object _, StackTrace _) {}));
    }
    _setState(RenderState(project: project, phase: RenderPhase.idle));
  }

  String generate(RenderQuality quality) {
    final current = state;
    final project = current.project;
    final previousId = current.operationId;
    final drain = _requiredDrain(
      current.phase == RenderPhase.rendering ? previousId : null,
    );
    final operationId = _nextOperationId();
    final request = RenderRequest(
      operationId: operationId,
      projectId: project.id,
      revision: project.revision,
      arrangement: Arrangement.fromJson(project.arrangement),
      video: VideoRecipe.fromJson(project.videoRecipe),
      quality: quality,
    );
    _setState(
      RenderState(
        project: project,
        phase: RenderPhase.rendering,
        operationId: operationId,
      ),
    );
    unawaited(_complete(request, requiredDrain: drain));
    return operationId;
  }

  Future<void> cancel() async {
    final current = state;
    final operationId = current.operationId;
    if (operationId == null || current.phase != RenderPhase.rendering) return;
    _setState(
      RenderState(
        project: current.project,
        phase: RenderPhase.cancelled,
        operationId: operationId,
      ),
    );
    await _requiredDrain(operationId);
  }

  Future<void> _complete(
    RenderRequest request, {
    required Future<void>? requiredDrain,
  }) async {
    try {
      if (requiredDrain != null) {
        await requiredDrain;
      }
      if (!_isCurrent(request)) return;
      final media = await gateway.render(request);
      if (!_isCurrent(request) ||
          media.operationId != request.operationId ||
          media.projectId != request.projectId ||
          media.revision != request.revision) {
        return;
      }
      _setState(
        RenderState(
          project: state.project,
          phase: RenderPhase.ready,
          operationId: request.operationId,
          readyMedia: media,
        ),
      );
    } catch (error) {
      if (!_isCurrent(request)) return;
      _setState(
        RenderState(
          project: state.project,
          phase: RenderPhase.failed,
          operationId: request.operationId,
          error: error,
        ),
      );
    }
  }

  bool _isCurrent(RenderRequest request) =>
      state.phase == RenderPhase.rendering &&
      state.operationId == request.operationId &&
      state.project.id == request.projectId &&
      state.project.revision == request.revision;

  void _setState(RenderState value) {
    if (_disposed) return;
    _stateValue = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final operationId = _stateValue?.phase == RenderPhase.rendering
        ? _stateValue?.operationId
        : null;
    if (operationId != null) {
      unawaited(
        _enqueueCancellation(operationId)
            .catchError((Object _, StackTrace _) {}),
      );
    }
    super.dispose();
  }

  Future<void>? _requiredDrain(String? candidateOperationId) {
    final operationId = _undrainedOperationId ?? candidateOperationId;
    if (operationId == null) return null;
    final currentAttempt = _drainAttempt;
    if (currentAttempt != null) return currentAttempt;

    _undrainedOperationId = operationId;
    final cancellation = _enqueueCancellation(operationId);
    late final Future<void> attempt;
    attempt = cancellation.then<void>(
      (_) {
        if (identical(_drainAttempt, attempt)) {
          _drainAttempt = null;
          if (_undrainedOperationId == operationId) {
            _undrainedOperationId = null;
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_drainAttempt, attempt)) {
          _drainAttempt = null;
        }
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    _drainAttempt = attempt;
    return attempt;
  }

  Future<void> _enqueueCancellation(String operationId) {
    final cancellation = _cancellationQueueTail.then(
      (_) => gateway.cancel(operationId),
    );
    _cancellationQueueTail = cancellation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return cancellation;
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
