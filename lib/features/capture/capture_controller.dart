import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../media/media_gateway.dart';
import '../../media/media_messages.dart';
import 'capture_state.dart';

typedef OperationIdFactory = String Function();

final class CaptureController extends ChangeNotifier {
  CaptureController(this._gateway, {required this.operationIdFactory}) {
    _events = _gateway.events.listen(_onEvent, onError: _onEventError);
  }

  final MediaGateway _gateway;
  final OperationIdFactory operationIdFactory;
  late final StreamSubscription<MediaEvent> _events;
  CaptureState _state = const CaptureState();
  Future<void>? _preparing;
  bool _disposed = false;
  Future<void>? _release;

  CaptureState get state => _state;
  String? get operationId => _state.operationId;

  Future<void> prepare() {
    if (_preparing case final pending?) return pending;
    if (_state.phase == CapturePhase.ready) return Future<void>.value();
    final pending = _prepare();
    _preparing = pending;
    return pending.whenComplete(() => _preparing = null);
  }

  Future<void> _prepare() async {
    _set(
      _state.copyWith(
        phase: CapturePhase.preparing,
        clearResult: true,
        clearError: true,
        requiresExplicitResume: false,
      ),
    );
    try {
      final handle = await _gateway.prepareCapture();
      if (_disposed) return;
      _set(_state.copyWith(phase: CapturePhase.ready, handle: handle));
    } on MediaCaptureException catch (error) {
      _fail(error);
    } catch (error) {
      _fail(
        MediaCaptureException(
          MediaCaptureErrorCode.unavailable,
          error.toString(),
        ),
      );
    }
  }

  Future<void> record({int maxDurationUs = 3000000}) async {
    if (_state.phase != CapturePhase.ready) return;
    if (maxDurationUs != 3000000 && maxDurationUs != 6000000) {
      _fail(
        const MediaCaptureException(
          MediaCaptureErrorCode.invalidMedia,
          'Recording duration must be 3 or 6 seconds.',
        ),
      );
      return;
    }
    final id = operationIdFactory();
    _set(
      _state.copyWith(
        phase: CapturePhase.starting,
        operationId: id,
        progress: 0,
        clearResult: true,
        clearError: true,
      ),
    );
    try {
      await _gateway.startCapture(id, maxDurationUs: maxDurationUs);
      if (_state.operationId == id && _state.phase == CapturePhase.starting) {
        _set(_state.copyWith(phase: CapturePhase.recording));
      }
    } on MediaCaptureException catch (error) {
      if (_state.operationId == id) _fail(error);
    }
  }

  Future<void> stop() async {
    final id = _state.operationId;
    if (id == null || _state.phase != CapturePhase.recording) {
      return;
    }
    _set(_state.copyWith(phase: CapturePhase.stopping));
    try {
      final media = await _gateway.stopCapture(id);
      if (_state.operationId != id ||
          _state.phase == CapturePhase.interrupted) {
        return;
      }
      if (media.operationId != id) {
        throw const MediaCaptureException(
          MediaCaptureErrorCode.incompleteCapture,
          'The finalized recording belongs to another operation.',
        );
      }
      _set(
        _state.copyWith(
          phase: CapturePhase.completed,
          progress: 1,
          savedAssetId: media.assetId,
          capturedMedia: media,
        ),
      );
    } on MediaCaptureException catch (error) {
      if (_state.operationId == id) _fail(error);
    }
  }

  Future<void> importVideo() async {
    if (_state.isBusy || _state.phase == CapturePhase.recording) return;
    final returnPhase = _state.handle == null
        ? CapturePhase.idle
        : CapturePhase.ready;
    final id = operationIdFactory();
    _set(
      _state.copyWith(
        phase: CapturePhase.importing,
        operationId: id,
        clearResult: true,
        clearError: true,
      ),
    );
    try {
      final media = await _gateway.pickVideo(id);
      if (_state.operationId != id) return;
      if (media == null) {
        _set(_state.copyWith(phase: returnPhase));
      } else if (media.operationId != id) {
        _fail(
          const MediaCaptureException(
            MediaCaptureErrorCode.invalidMedia,
            '選んだ動画の操作情報を確認できませんでした。もう一度選んでください。',
          ),
        );
      } else {
        _set(
          _state.copyWith(
            phase: CapturePhase.completed,
            progress: 1,
            savedAssetId: media.assetId,
            capturedMedia: media,
          ),
        );
      }
    } on MediaCaptureException catch (error) {
      if (_state.operationId == id) _fail(error);
    }
  }

  void _onEvent(MediaEvent event) {
    if (event.operationId != _state.operationId) return;
    switch (event.type) {
      case MediaEventType.recording:
        if (_state.phase == CapturePhase.starting) {
          _set(_state.copyWith(phase: CapturePhase.recording));
        }
      case MediaEventType.progress:
        if (_state.phase == CapturePhase.recording && event.progress != null) {
          _set(_state.copyWith(progress: event.progress));
        }
      case MediaEventType.interrupted:
        _set(
          _state.copyWith(
            phase: CapturePhase.interrupted,
            errorCode: MediaCaptureErrorCode.interrupted,
            message: '録画が中断されました。再開するにはもう一度操作してください。',
            requiresExplicitResume: true,
            clearResult: true,
          ),
        );
      case MediaEventType.failed:
        _fail(
          MediaCaptureException(
            _decodeError(event.errorCode),
            '録画を完了できませんでした。',
          ),
        );
      case MediaEventType.completed:
        if (_state.phase == CapturePhase.recording ||
            _state.phase == CapturePhase.starting) {
          unawaited(stop());
        }
    }
  }

  void _onEventError(Object error, StackTrace stackTrace) {
    if (_state.phase == CapturePhase.recording ||
        _state.phase == CapturePhase.starting) {
      _fail(
        const MediaCaptureException(
          MediaCaptureErrorCode.interrupted,
          'The capture event stream ended unexpectedly.',
        ),
      );
    }
  }

  MediaCaptureErrorCode _decodeError(String? value) =>
      MediaCaptureErrorCode.values
          .where((candidate) => candidate.name == value)
          .firstOrNull ??
      MediaCaptureErrorCode.incompleteCapture;

  void _fail(MediaCaptureException error) {
    _set(
      _state.copyWith(
        phase: error.code == MediaCaptureErrorCode.permissionDenied
            ? CapturePhase.permissionDenied
            : error.code == MediaCaptureErrorCode.interrupted
            ? CapturePhase.interrupted
            : CapturePhase.failed,
        errorCode: error.code,
        message: error.message,
        requiresExplicitResume: error.code == MediaCaptureErrorCode.interrupted,
        clearResult: true,
      ),
    );
  }

  void _set(CaptureState state) {
    _state = state;
    if (!_disposed) notifyListeners();
  }

  Future<void> releaseCapture() => _release ??= _releaseCapture();

  Future<void> _releaseCapture() async {
    _disposed = true;
    await _events.cancel();
    await _gateway.disposeCapture();
  }

  @override
  void dispose() {
    if (!_disposed) unawaited(releaseCapture());
    super.dispose();
  }
}
