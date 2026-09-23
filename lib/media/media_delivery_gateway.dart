import 'package:flutter/services.dart';

import 'platform_media_gateway.dart';

abstract interface class MediaDeliveryGateway {
  Future<void> saveToPhotos(String relativePath);
  Future<bool> share(String relativePath);
}

final class PlatformMediaDeliveryGateway implements MediaDeliveryGateway {
  PlatformMediaDeliveryGateway({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(PlatformMediaGateway.channelName);

  final MethodChannel _channel;

  @override
  Future<void> saveToPhotos(String relativePath) => _channel.invokeMethod<void>(
    'saveRendered',
    <String, Object?>{'relativePath': relativePath},
  );

  @override
  Future<bool> share(String relativePath) async =>
      await _channel.invokeMethod<bool>('shareRendered', <String, Object?>{
        'relativePath': relativePath,
      }) ??
      false;
}
