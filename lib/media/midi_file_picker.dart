import 'package:flutter/services.dart';

import 'platform_media_gateway.dart';

/// A MIDI file the person chose in Files: its name without the extension and
/// its bytes, not yet read.
final class PickedMidiFile {
  const PickedMidiFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

abstract interface class MidiFilePicker {
  /// Opens Files for one MIDI file; null when the person cancels.
  Future<PickedMidiFile?> pick();
}

final class PlatformMidiFilePicker implements MidiFilePicker {
  const PlatformMidiFilePicker({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(PlatformMediaGateway.channelName);

  final MethodChannel _channel;

  @override
  Future<PickedMidiFile?> pick() async {
    final file = await _channel.invokeMapMethod<String, Object?>(
      'pickMidiFile',
    );
    if (file == null) return null;
    final bytes = file['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) {
      throw PlatformException(
        code: 'midi_file_unreadable',
        message: 'The chosen file has no data.',
      );
    }
    final name = file['name'];
    return PickedMidiFile(name: name is String ? name : '', bytes: bytes);
  }
}
