import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/custom_song.dart';
import '../../media/midi_file_picker.dart';
import '../../sharing/song_catalog.dart';
import '../../storage/song_repository.dart';

/// Turns a chosen MIDI file into a song, or says in the person's words why
/// it cannot ([MidiSongProblem]).
typedef MidiSongReader = CustomSong Function(PickedMidiFile file, String id);

/// A MIDI file that could not become a song; [message] is ready to show.
final class MidiSongProblem implements Exception {
  const MidiSongProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

enum CatalogPhase {
  /// no server is set up for this build
  unavailable,
  loading,
  failed,
  loaded,
}

/// The songs a new piece can be made with beyond the built-in ones: those on
/// this phone (read from MIDI files or taken from the catalogue) and those
/// everyone has posted.
final class SongLibrary extends ChangeNotifier {
  SongLibrary({
    required this._songs,
    this._catalog,
    this._picker,
    this._reader,
    this._signIn,
  });

  final SongRepository _songs;
  final SongCatalog? _catalog;
  final MidiFilePicker? _picker;
  final MidiSongReader? _reader;
  final Future<void> Function()? _signIn;
  var _disposed = false;
  var _loadedOnce = false;

  /// The songs kept on this phone, newest first.
  List<CustomSong> local = const [];

  CatalogPhase catalogPhase = CatalogPhase.loading;
  String? catalogMessage;
  List<CatalogSong> newest = const [];
  List<CatalogSong> popular = const [];

  /// More of [newest] can be fetched with [loadMore].
  bool get hasMore => _next != null;
  String? _next;
  var _loadingMore = false;

  bool get canImport => _picker != null && _reader != null;
  bool get canPost => _catalog != null && catalogPhase != CatalogPhase.unavailable;

  /// Loads both lists the first time the songs are shown.
  Future<void> ensureLoaded() async {
    if (_loadedOnce) return;
    _loadedOnce = true;
    await refresh();
  }

  Future<void> refresh() async {
    await _loadLocal();
    await _loadCatalog();
  }

  Future<void> _loadLocal() async {
    try {
      local = await _songs.list();
    } catch (_) {
      local = const [];
    }
    _changed();
  }

  Future<void> _loadCatalog() async {
    final catalog = _catalog;
    if (catalog == null) {
      catalogPhase = CatalogPhase.unavailable;
      return _changed();
    }
    catalogPhase = CatalogPhase.loading;
    catalogMessage = null;
    _changed();
    try {
      if (!await catalog.available()) {
        catalogPhase = CatalogPhase.unavailable;
        return _changed();
      }
      final page = await catalog.newest();
      final most = await catalog.popular();
      newest = page.songs;
      _next = page.next;
      popular = most;
      catalogPhase = CatalogPhase.loaded;
    } on SongCatalogException catch (error) {
      catalogPhase = error.code == 'server_missing'
          ? CatalogPhase.unavailable
          : CatalogPhase.failed;
      catalogMessage = error.message;
    } catch (_) {
      catalogPhase = CatalogPhase.failed;
      catalogMessage = 'みんなの曲を読み込めませんでした。';
    }
    _changed();
  }

  Future<void> loadMore() async {
    final catalog = _catalog;
    final after = _next;
    if (catalog == null || after == null || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = await catalog.newest(after: after);
      final known = newest.map((song) => song.id).toSet();
      newest = [
        ...newest,
        for (final song in page.songs)
          if (known.add(song.id)) song,
      ];
      _next = page.next;
    } on SongCatalogException {
      // the list stays as it is; the button can be pressed again
    } finally {
      _loadingMore = false;
      _changed();
    }
  }

  /// Opens Files for a MIDI file and reads it. Null when the person cancels;
  /// throws [MidiSongProblem] when the file cannot become a song. The song is
  /// not kept until [keep].
  Future<CustomSong?> pickMidi() async {
    final picker = _picker;
    final reader = _reader;
    if (picker == null || reader == null) return null;
    final PickedMidiFile? file;
    try {
      file = await picker.pick();
    } catch (_) {
      throw const MidiSongProblem('このファイルを開けませんでした。別のMIDIで試してください。');
    }
    if (file == null) return null;
    return reader(file, newSongId());
  }

  /// Keeps the song on this phone (under a new [title] or [credit] if given).
  Future<CustomSong> keep(
    CustomSong song, {
    String? title,
    String? credit,
  }) async {
    final kept = title == null && credit == null
        ? song
        : CustomSong(
            id: song.id,
            title: title ?? song.title,
            credit: credit ?? song.credit,
            lanes: song.lanes,
            author: song.author,
            remoteId: song.remoteId,
            origin: song.origin,
          );
    await _songs.save(kept);
    await _loadLocal();
    return kept;
  }

  Future<void> forget(String id) async {
    await _songs.delete(id);
    await _loadLocal();
  }

  /// A catalogue song, fetched whole and kept on this phone so a piece can be
  /// made with it; the catalogue is told it was used.
  Future<CustomSong> take(CatalogSong song) async {
    final catalog = _catalog;
    if (catalog == null) {
      throw const SongCatalogException('みんなの曲は、まだ準備中です。');
    }
    final fetched = await catalog.fetch(song);
    await _songs.save(fetched);
    await _loadLocal();
    try {
      await catalog.countUse(song.id);
    } on SongCatalogException {
      // the count is a nicety; the song itself is already here
    }
    return fetched;
  }

  /// Posts a song for everyone, logging in first when that is needed.
  Future<CatalogSong> post(CustomSong song, SongRights rights) =>
      _withLogin((catalog) => catalog.post(song, rights), reload: true);

  Future<void> report(
    CatalogSong song,
    SongReportReason reason, {
    String note = '',
  }) async {
    await _withLogin(
      (catalog) => catalog.report(song.id, reason, note: note),
    );
    // whoever reported a song does not have to keep seeing it
    newest = [
      for (final other in newest)
        if (other.id != song.id) other,
    ];
    popular = [
      for (final other in popular)
        if (other.id != song.id) other,
    ];
    _changed();
  }

  Future<List<CatalogSong>> mine() =>
      _withLogin((catalog) => catalog.mine());

  Future<void> removePosted(String id) =>
      _withLogin((catalog) => catalog.remove(id), reload: true);

  Future<T> _withLogin<T>(
    Future<T> Function(SongCatalog catalog) action, {
    bool reload = false,
  }) async {
    final catalog = _catalog;
    if (catalog == null) {
      throw const SongCatalogException('みんなの曲は、まだ準備中です。');
    }
    T result;
    try {
      result = await action(catalog);
    } on SongCatalogException catch (error) {
      final signIn = _signIn;
      if (!error.needsLogin || signIn == null) rethrow;
      try {
        await signIn();
      } catch (_) {
        throw const SongCatalogException(
          'ログインできませんでした。もう一度お試しください。',
          code: 'login_failed',
        );
      }
      result = await action(catalog);
    }
    if (reload) await _loadCatalog();
    return result;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final _random = math.Random.secure();

/// An id for a song added on this phone.
String newSongId() => [
  'song',
  for (var i = 0; i < 4; i++)
    _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'),
].join('-');
