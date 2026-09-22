import 'package:flutter/services.dart';

import 'media_gateway.dart';
import 'media_messages.dart';

final class PlatformMediaGateway implements MediaGateway {
  const PlatformMediaGateway({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'dev.otogurashi/media';
  final MethodChannel _channel;

  Future<String> managedRoot() async {
    final path = await _channel.invokeMethod<String>('managedRoot');
    if (path == null || path.isEmpty) {
      throw const MediaContractException('Managed media root is unavailable.');
    }
    return path;
  }

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
}
