import 'dart:math';

import 'project_database.dart';

/// A named collection of sounds ("沖縄旅行のオトグラシ"). Folders hold any
/// number of sounds; a song picks up to six of them into a project.
final class SoundFolder {
  const SoundFolder({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.assetIds,
  });

  final String id;
  final String title;
  final DateTime createdAt;

  /// Newest first.
  final List<String> assetIds;
}

abstract interface class FolderRepository {
  /// Newest folder first. The first call on an install with sounds but no
  /// folders files every existing sound into a starter folder.
  Future<List<SoundFolder>> list();
  Future<SoundFolder> create(String title);
  Future<void> rename(String folderId, String title);
  Future<void> delete(String folderId);
  Future<void> addAsset(String folderId, String assetId);
  Future<void> removeAsset(String folderId, String assetId);
}

final class SqliteFolderRepository implements FolderRepository {
  SqliteFolderRepository(this._database);

  static const starterTitle = 'はじめてのオトグラシ';

  final ProjectDatabase _database;

  @override
  Future<List<SoundFolder>> list() async {
    final connection = _database.connection;
    final none = connection.select('SELECT 1 FROM folders LIMIT 1').isEmpty;
    if (none &&
        connection.select('SELECT 1 FROM assets LIMIT 1').isNotEmpty) {
      _database.transaction(() {
        final id = _newUuid();
        final now = DateTime.now().toUtc().toIso8601String();
        connection
          ..execute(
            'INSERT INTO folders (id, title, created_at) VALUES (?, ?, ?)',
            <Object?>[id, starterTitle, now],
          )
          ..execute(
            'INSERT INTO folder_assets (folder_id, asset_id, added_at) '
            'SELECT ?, id, ? FROM assets',
            <Object?>[id, now],
          );
      });
    }
    final folders = connection.select(
      'SELECT id, title, created_at FROM folders ORDER BY created_at DESC',
    );
    final members = connection.select(
      'SELECT folder_id, asset_id FROM folder_assets '
      'ORDER BY added_at DESC, rowid DESC',
    );
    final byFolder = <String, List<String>>{};
    for (final row in members) {
      byFolder
          .putIfAbsent(row['folder_id'] as String, () => <String>[])
          .add(row['asset_id'] as String);
    }
    return [
      for (final row in folders)
        SoundFolder(
          id: row['id'] as String,
          title: row['title'] as String,
          createdAt: DateTime.parse(row['created_at'] as String),
          assetIds: List.unmodifiable(byFolder[row['id']] ?? const <String>[]),
        ),
    ];
  }

  @override
  Future<SoundFolder> create(String title) async {
    final cleaned = _clean(title);
    final id = _newUuid();
    final now = DateTime.now().toUtc();
    _database.connection.execute(
      'INSERT INTO folders (id, title, created_at) VALUES (?, ?, ?)',
      <Object?>[id, cleaned, now.toIso8601String()],
    );
    return SoundFolder(id: id, title: cleaned, createdAt: now, assetIds: const []);
  }

  @override
  Future<void> rename(String folderId, String title) async {
    _database.connection.execute(
      'UPDATE folders SET title = ? WHERE id = ?',
      <Object?>[_clean(title), folderId],
    );
  }

  @override
  Future<void> delete(String folderId) async {
    _database.connection.execute(
      'DELETE FROM folders WHERE id = ?',
      <Object?>[folderId],
    );
  }

  @override
  Future<void> addAsset(String folderId, String assetId) async {
    _database.connection.execute(
      'INSERT OR IGNORE INTO folder_assets (folder_id, asset_id, added_at) '
      'VALUES (?, ?, ?)',
      <Object?>[folderId, assetId, DateTime.now().toUtc().toIso8601String()],
    );
  }

  @override
  Future<void> removeAsset(String folderId, String assetId) async {
    _database.connection.execute(
      'DELETE FROM folder_assets WHERE folder_id = ? AND asset_id = ?',
      <Object?>[folderId, assetId],
    );
  }

  static String _clean(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return '新しいオトグラシ';
    return trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
  }
}

String _newUuid() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}
