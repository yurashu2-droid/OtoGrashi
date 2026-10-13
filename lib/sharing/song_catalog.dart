import '../domain/custom_song.dart';
import 'shared_folder_service.dart';

/// What the person posting a song declares about it. Only these two kinds of
/// song may be posted.
enum SongRights {
  /// written by the person posting it
  own('own'),

  /// old enough that its copyright has ended
  publicDomain('public_domain');

  const SongRights(this.wire);
  final String wire;
}

enum SongReportReason { rights, inappropriate, other }

/// A song as the catalogue lists it: everything but its notes.
final class CatalogSong {
  const CatalogSong({
    required this.id,
    required this.title,
    required this.credit,
    required this.author,
    required this.uses,
    this.rights,
    this.createdAt,
    this.status = 'public',
  });

  /// Null unless [json] has at least an id and a title.
  static CatalogSong? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    if (id is! String || id.isEmpty || title is! String || title.isEmpty) {
      return null;
    }
    final credit = json['credit'];
    final author = json['author'];
    final uses = json['uses'];
    final created = json['createdAt'];
    final status = json['status'];
    return CatalogSong(
      id: id,
      title: title,
      credit: credit is String ? credit : '',
      author: author is String ? author : '',
      uses: uses is int && uses > 0 ? uses : 0,
      rights: SongRights.values
          .where((value) => value.wire == json['rights'])
          .firstOrNull,
      createdAt: created is String ? DateTime.tryParse(created) : null,
      status: status is String ? status : 'public',
    );
  }

  final String id;
  final String title;
  final String credit;

  /// The display name of whoever posted it.
  final String author;
  final int uses;
  final SongRights? rights;
  final DateTime? createdAt;

  /// `public`, or `hidden` for the poster's own song under review.
  final String status;
}

/// A problem with the catalogue, already worded for the person. [code] is the
/// server's, plus `server_missing`, `login_required` and `network`.
final class SongCatalogException implements Exception {
  const SongCatalogException(this.message, {this.code});

  final String message;
  final String? code;

  /// Logging in (again) would let the same action succeed.
  bool get needsLogin =>
      code == 'login_required' ||
      code == 'account_required' ||
      code == 'session_expired';

  @override
  String toString() => message;
}

/// The songs everyone posts: listing and fetching need no account; posting,
/// reporting and removing do.
abstract interface class SongCatalog {
  /// False until a server is set up for this build.
  Future<bool> available();

  /// The newest songs; [after] continues from an earlier page's `next`.
  Future<({List<CatalogSong> songs, String? next})> newest({String? after});

  /// The most used songs.
  Future<List<CatalogSong>> popular();

  /// The whole song, ready to play and to keep on the phone.
  Future<CustomSong> fetch(CatalogSong song);

  /// Tells the catalogue that a piece was made with this song.
  Future<void> countUse(String id);

  Future<CatalogSong> post(CustomSong song, SongRights rights);

  Future<void> report(String id, SongReportReason reason, {String note = ''});

  /// The songs this account posted, newest first.
  Future<List<CatalogSong>> mine();

  Future<void> remove(String id);
}

final class ServerSongCatalog implements SongCatalog {
  ServerSongCatalog(this._service);

  final SharedFolderService _service;

  @override
  Future<bool> available() async =>
      await _service.configuredServer() != null;

  @override
  Future<({List<CatalogSong> songs, String? next})> newest({
    String? after,
  }) async {
    final json = await _call(
      'GET',
      after == null
          ? '/v1/songs'
          : '/v1/songs/after/${Uri.encodeComponent(after)}',
    );
    final next = json['next'];
    return (
      songs: _songs(json['songs']),
      next: next is String && next.isNotEmpty ? next : null,
    );
  }

  @override
  Future<List<CatalogSong>> popular() async =>
      _songs((await _call('GET', '/v1/songs/popular'))['songs']);

  @override
  Future<CustomSong> fetch(CatalogSong song) async {
    final json = (await _call('GET', '/v1/songs/${song.id}'))['song'];
    final score = json is Map ? json['score'] : null;
    final fetched = CustomSong.tryFromJson(<String, Object?>{
      // one entry in the phone's song list per catalogue song
      'id': 'catalog-${song.id}',
      'title': json is Map ? json['title'] : null,
      'credit': json is Map ? json['credit'] : null,
      'author': json is Map ? json['author'] : null,
      'remoteId': song.id,
      'origin': SongOrigin.catalog.name,
      'lanes': score is Map ? score['lanes'] : (json is Map ? json['lanes'] : null),
    });
    if (fetched == null) {
      throw const SongCatalogException('この曲を読み込めませんでした。', code: 'invalid_song');
    }
    return fetched;
  }

  @override
  Future<void> countUse(String id) async {
    await _call('POST', '/v1/songs/$id/use', data: const {});
  }

  @override
  Future<CatalogSong> post(CustomSong song, SongRights rights) async {
    final json = await _call(
      'POST',
      '/v1/songs',
      account: true,
      data: <String, dynamic>{
        'title': song.title,
        if (song.credit.isNotEmpty) 'credit': song.credit,
        'rights': rights.wire,
        'score': <String, dynamic>{'v': 1, 'beats': 32, 'lanes': song.lanes},
      },
    );
    final posted = CatalogSong.tryFromJson(json['song']);
    if (posted == null) {
      throw const SongCatalogException('投稿できたか確かめられませんでした。');
    }
    return posted;
  }

  @override
  Future<void> report(
    String id,
    SongReportReason reason, {
    String note = '',
  }) async {
    await _call(
      'POST',
      '/v1/songs/$id/report',
      account: true,
      data: <String, dynamic>{
        'reason': reason.name,
        if (note.trim().isNotEmpty) 'note': note.trim(),
      },
    );
  }

  @override
  Future<List<CatalogSong>> mine() async => _songs(
    (await _call('GET', '/v1/account/songs', account: true))['songs'],
  );

  @override
  Future<void> remove(String id) async {
    await _call('DELETE', '/v1/songs/$id', account: true);
  }

  List<CatalogSong> _songs(Object? json) => [
    if (json is List)
      for (final item in json) ?CatalogSong.tryFromJson(item),
  ];

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, dynamic>? data,
    bool account = false,
  }) async {
    try {
      // a song is a few kilobytes: a slow answer is a lost connection
      return await _service
          .serverJson(method, path, data: data, account: account)
          .timeout(const Duration(seconds: 20));
    } on SharedFolderException catch (error) {
      throw SongCatalogException(_message(error), code: error.code);
    } on SongCatalogException {
      rethrow;
    } catch (_) {
      throw const SongCatalogException(
        '通信できませんでした。電波のよいところで、もう一度お試しください。',
        code: 'network',
      );
    }
  }

  static String _message(SharedFolderException error) => switch (error.code) {
    'server_missing' => 'みんなの曲は、まだ準備中です。',
    'login_required' ||
    'account_required' ||
    'session_expired' => 'ログインが必要です。',
    'song_limit' => '投稿できるのは30曲までです。使わない曲を消してから投稿してください。',
    'post_limit' => '今日は、これ以上投稿できません。また明日お試しください。',
    'song_not_found' => 'この曲は、もう公開されていません。',
    'rate_limited' => '少し待ってから、もう一度お試しください。',
    'body_too_large' => 'この曲は大きすぎて送れませんでした。',
    final code? when code.startsWith('invalid_') =>
      'この曲のデータを送れませんでした。別のMIDIで試してください。',
    _ => error.message,
  };
}
