import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../media/platform_media_gateway.dart';

/// Hidden check (long-press the wordmark): can this phone record depth alongside video?
/// Runs a separate 1.5 s session on the native side and shows what it found.
Future<void> runDepthProbe(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(content: Text('奥行きの記録を確認しています…')),
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
      title: const Text('奥行きの確認'),
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
