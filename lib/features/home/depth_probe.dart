import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../media/platform_media_gateway.dart';

/// Hidden measurement (long-press the wordmark): how long the depth model takes to
/// download, compile and run over the newest clip on this phone.
Future<void> runDepthProbe(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      duration: Duration(minutes: 2),
      content: Text('奥行き推定を計測しています…（初回はモデル約50MBをダウンロード）'),
    ),
  );
  String report;
  try {
    final value = await const MethodChannel(
      PlatformMediaGateway.channelName,
    ).invokeMapMethod<String, Object?>('probeDepth');
    final entries = (value ?? const {}).entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    report = entries.map((e) => '${e.key}: ${e.value}').join('\n');
  } on PlatformException catch (error) {
    report = 'error: ${error.code} ${error.message ?? ''}';
  } on MissingPluginException {
    report = 'この端末では使えません';
  }
  if (!context.mounted) return;
  messenger.hideCurrentSnackBar();
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('奥行き推定の計測'),
      content: SelectableText(report),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}
