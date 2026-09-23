import 'package:flutter/services.dart';

import 'media_gateway.dart';
import 'media_messages.dart';

final class PlatformMediaGateway implements MediaGateway {
  PlatformMediaGateway({MethodChannel? channel, EventChannel? eventChannel})
    : _channel = channel ?? const MethodChannel(channelName),
      _eventChannel = eventChannel ?? const EventChannel(eventChannelName);

  static const String channelName = 'dev.otogurashi/media';
  static const String eventChannelName = 'dev.otogurashi/media/events';
  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<MediaEvent>? _events;

  @override
  Stream<MediaEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map(
        (event) => MediaEvent.fromJson(
          (event as Map<Object?, Object?>).cast<String, Object?>(),
        ),
      )
      .asBroadcastStream();

  Future<String> managedRoot() async {
    final path = await _channel.invokeMethod<String>('managedRoot');
    if (path == null || path.isEmpty) {
      throw const MediaContractException('Managed media root is unavailable.');
    }
    return path;
  }

  @override
  Future<CaptureHandle> prepareCapture() => _capture(
    () async => CaptureHandle.fromJson(
      await _invokeMap('prepareCapture', const <String, Object?>{}),
    ),
  );

  @override
  Future<CameraFacing> switchCamera() => _capture(() async {
    final facing = await _channel.invokeMethod<String>('switchCamera');
    if (facing == null) {
      throw const MediaContractException('Camera position is unavailable.');
    }
    return CameraFacing.values.byName(facing);
  });

  @override
  Future<void> suspendCaptureForReview() =>
      _capture(() => _channel.invokeMethod<void>('suspendCaptureForReview'));

  @override
  Future<void> discardStaged(String relativePath) => _capture(
    () => _channel.invokeMethod<void>('discardStaged', <String, Object?>{
      'relativePath': relativePath,
    }),
  );

  @override
  Future<void> startCapture(String operationId, {required int maxDurationUs}) =>
      _capture(
        () => _channel.invokeMethod<void>('startCapture', <String, Object?>{
          'operationId': operationId,
          'maxDurationUs': maxDurationUs,
        }),
      );

  @override
  Future<CapturedMedia> stopCapture(String operationId) => _capture(
    () async => CapturedMedia.fromJson(
      await _invokeMap('stopCapture', <String, Object?>{
        'operationId': operationId,
      }),
    ),
  );

  @override
  Future<CapturedMedia?> pickVideo(String operationId) async {
    return _capture(() async {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'pickVideo',
        <String, Object?>{'operationId': operationId},
      );
      return result == null
          ? null
          : CapturedMedia.fromJson(result.cast<String, Object?>());
    });
  }

  @override
  Future<InspectedMedia> inspectStaged(String path) => _capture(
    () async => InspectedMedia.fromJson(
      await _invokeMap('inspectStaged', <String, Object?>{'path': path}),
    ),
  );

  @override
  Future<void> disposeCapture() =>
      _capture(() => _channel.invokeMethod<void>('disposeCapture'));

  @override
  Future<AnalyzedClip> analyze(MediaAnalysisRequest request) async {
    final result = await _invokeMap('analyze', request.toJson());
    return AnalyzedClip.fromJson(result);
  }

  @override
  Future<RenderedMedia> render(RenderRequest request) async {
    final result = await _invokeMap('render', request.toJson());
    return RenderedMedia.fromJson(result);
  }

  @override
  Future<void> cancel(String operationId) {
    if (operationId.isEmpty) {
      throw const MediaContractException('Operation id cannot be empty.');
    }
    return _channel.invokeMethod<void>('cancel', <String, Object?>{
      'operationId': operationId,
    });
  }

  Future<Map<String, Object?>> _invokeMap(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (result == null) {
      throw MediaContractException('$method returned no result.');
    }
    return result.cast<String, Object?>();
  }

  Future<T> _capture<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PlatformException catch (error) {
      final code = MediaCaptureErrorCode.values
          .where((candidate) => candidate.name == error.code)
          .firstOrNull;
      throw MediaCaptureException(
        code ?? MediaCaptureErrorCode.unavailable,
        error.message ?? 'The media operation failed.',
      );
    }
  }
}
