import 'project_database.dart';

/// Someone whose catalogue songs this phone no longer shows. [poster] is the
/// catalogue's opaque key for them; [name] is how they were shown then.
final class BlockedPoster {
  const BlockedPoster({required this.poster, required this.name});

  final String poster;
  final String name;
}

/// The people the person chose not to see in the song catalogue. Kept on the
/// phone, so it needs no account and works for everyone.
abstract interface class PosterBlocks {
  /// Newest first.
  Future<List<BlockedPoster>> list();

  Future<void> block(BlockedPoster poster);

  Future<void> unblock(String poster);
}

final class SqlitePosterBlocks implements PosterBlocks {
  SqlitePosterBlocks(this._database) {
    _database.connection.execute('''
      CREATE TABLE IF NOT EXISTS blocked_posters (
        poster TEXT NOT NULL PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL
      ) STRICT
    ''');
  }

  final ProjectDatabase _database;

  @override
  Future<List<BlockedPoster>> list() async => [
    for (final row in _database.connection.select(
      'SELECT poster, name FROM blocked_posters '
      'ORDER BY created_at DESC, rowid DESC',
    ))
      BlockedPoster(
        poster: row['poster'] as String,
        name: row['name'] as String,
      ),
  ];

  @override
  Future<void> block(BlockedPoster poster) async {
    _database.connection.execute(
      'INSERT INTO blocked_posters (poster, name, created_at) VALUES (?, ?, ?) '
      'ON CONFLICT(poster) DO UPDATE SET name = excluded.name',
      <Object?>[
        poster.poster,
        poster.name,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }

  @override
  Future<void> unblock(String poster) async {
    _database.connection.execute(
      'DELETE FROM blocked_posters WHERE poster = ?',
      <Object?>[poster],
    );
  }
}

/// For a library that keeps nothing between launches (tests, previews).
final class MemoryPosterBlocks implements PosterBlocks {
  final _blocked = <BlockedPoster>[];

  @override
  Future<List<BlockedPoster>> list() async => List.of(_blocked.reversed);

  @override
  Future<void> block(BlockedPoster poster) async {
    _blocked
      ..removeWhere((other) => other.poster == poster.poster)
      ..add(poster);
  }

  @override
  Future<void> unblock(String poster) async =>
      _blocked.removeWhere((other) => other.poster == poster);
}
