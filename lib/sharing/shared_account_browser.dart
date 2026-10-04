import 'package:flutter/services.dart';

abstract interface class SharedAccountBrowser {
  Future<Uri> authenticate(Uri authorizeUrl);
}

final class NativeSharedAccountBrowser implements SharedAccountBrowser {
  const NativeSharedAccountBrowser();
  static const _channel = MethodChannel('dev.otogurashi/media');
  @override
  Future<Uri> authenticate(Uri authorizeUrl) async {
    final callback = await _channel.invokeMethod<String>(
      'authenticateSharedAccount',
      {'url': authorizeUrl.toString()},
    );
    if (callback == null) throw const FormatException('認証を完了できませんでした。');
    try {
      return Uri.parse(callback);
    } on FormatException {
      // Parsing errors can include their input; keep callback codes out of UI.
      throw const FormatException('認証の応答が正しくありません。');
    }
  }
}
