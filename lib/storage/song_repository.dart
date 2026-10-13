import 'dart:convert';

import '../domain/custom_song.dart';
import 'project_database.dart';

/// The songs a person has added to this phone: read from a MIDI file, or
/// taken from the catalogue. The built-in songs are not kept here.
abstract interface class SongRepository {
  /// Newest first.
  Future<List<CustomSong>> list();

  /// Adds the song, or replaces the one with the same id.
  Future<void> save(CustomSong song);

  Future<void> delete(String id);
}

final class SqliteSongRepository implements SongRepository {
  SqliteSongRepository(this._database) {
    _database.connection.execute('''
      CREATE TABLE IF NOT EXISTS songs (
        id TEXT NOT NULL PRIMARY KEY,
        data TEXT NOT NULL,
        created_at TEXT NOT NULL
      ) STRICT
    ''');
  }

  final ProjectDatabase _database;

  @override
  Future<List<CustomSong>> list() async {
    final rows = _database.connection.select(
      'SELECT data FROM songs ORDER BY created_at DESC, rowid DESC',
    );
    final songs = <CustomSong>[];
    for (final row in rows) {
      try {
        final song = CustomSong.tryFromJson(jsonDecode(row['data'] as String));
        if (song != null) songs.add(song);
      } on FormatException {
        // a row that cannot be read is left out rather than failing the list
      }
    }
    return songs;
  }

  @override
  Future<void> save(CustomSong song) async {
    _database.connection.execute(
      'INSERT INTO songs (id, data, created_at) VALUES (?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET data = excluded.data',
      <Object?>[
        song.id,
        jsonEncode(song.toJson()),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<void> delete(String id) async {
    _database.connection.execute(
      'DELETE FROM songs WHERE id = ?',
      <Object?>[id],
    );
  }
}
