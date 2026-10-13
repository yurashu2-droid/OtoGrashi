import 'dart:io';

/// Remembers which song was in progress when the app was last used, so the
/// next launch continues that one and not whichever unfinished song happens
/// to be the newest. A song the person left with 新しくつくる stays in the 曲
/// tab and is not brought back.
final class DraftPointer {
  DraftPointer(this.file);

  final File file;

  /// The project in progress; an empty string when there is none; null when
  /// nothing has been remembered yet (the first launch with this version).
  Future<String?> load() async {
    try {
      return (await file.readAsString()).trim();
    } on FileSystemException {
      return null;
    }
  }

  /// [projectId] null means nothing is in progress.
  Future<void> save(String? projectId) async {
    try {
      await file.writeAsString(projectId ?? '', flush: true);
    } on FileSystemException {
      // only a convenience: the songs themselves are in the database
    }
  }
}
