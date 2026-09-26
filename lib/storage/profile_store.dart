import 'dart:io';

/// The creator's name, shown as "〇〇の日常" on the cover of every video. It
/// stays on this device like everything else.
final class ProfileStore {
  ProfileStore(this.file);

  final File file;

  static const int maxNameLength = 12;

  Future<String?> loadName() async {
    try {
      return clean(await file.readAsString());
    } on FileSystemException {
      return null;
    }
  }

  /// Saves the name; an empty one clears it (the cover then says わたし).
  Future<String?> saveName(String name) async {
    final value = clean(name);
    if (value == null) {
      if (await file.exists()) await file.delete();
      return null;
    }
    await file.writeAsString(value, flush: true);
    return value;
  }

  static String? clean(String raw) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) return null;
    return String.fromCharCodes(line.runes.take(maxNameLength));
  }
}
