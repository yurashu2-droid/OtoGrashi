import '../../media/media_messages.dart';

enum CapturePhase {
  idle,
  preparing,
  ready,
  starting,
  recording,
  stopping,
  importing,
  completed,
  permissionDenied,
  interrupted,
  failed,
}

final class CaptureState {
  const CaptureState({
    this.phase = CapturePhase.idle,
    this.handle,
    this.cameraFacing = CameraFacing.back,
    this.operationId,
    this.progress = 0,
    this.savedAssetId,
    this.capturedMedia,
    this.errorCode,
    this.message,
    this.requiresExplicitResume = false,
  });

  final CapturePhase phase;
  final CaptureHandle? handle;
  final CameraFacing cameraFacing;
  final String? operationId;
  final double progress;
  final String? savedAssetId;
  final CapturedMedia? capturedMedia;
  final MediaCaptureErrorCode? errorCode;
  final String? message;
  final bool requiresExplicitResume;

  bool get canRetry => switch (phase) {
    CapturePhase.permissionDenied ||
    CapturePhase.interrupted ||
    CapturePhase.failed => true,
    _ => false,
  };

  bool get isBusy => switch (phase) {
    CapturePhase.preparing ||
    CapturePhase.starting ||
    CapturePhase.stopping ||
    CapturePhase.importing => true,
    _ => false,
  };

  CaptureState copyWith({
    CapturePhase? phase,
    CaptureHandle? handle,
    CameraFacing? cameraFacing,
    String? operationId,
    double? progress,
    String? savedAssetId,
    CapturedMedia? capturedMedia,
    MediaCaptureErrorCode? errorCode,
    String? message,
    bool? requiresExplicitResume,
    bool clearResult = false,
    bool clearHandle = false,
    bool clearOperation = false,
    bool clearError = false,
  }) => CaptureState(
    phase: phase ?? this.phase,
    handle: clearHandle ? null : handle ?? this.handle,
    cameraFacing: cameraFacing ?? this.cameraFacing,
    operationId: clearOperation ? null : operationId ?? this.operationId,
    progress: progress ?? this.progress,
    savedAssetId: clearResult ? null : savedAssetId ?? this.savedAssetId,
    capturedMedia: clearResult ? null : capturedMedia ?? this.capturedMedia,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    message: clearError ? null : message ?? this.message,
    requiresExplicitResume:
        requiresExplicitResume ?? this.requiresExplicitResume,
  );
}
