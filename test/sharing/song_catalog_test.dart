import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/custom_song.dart';
import 'package:otogurashi/sharing/shared_folder_service.dart';
import 'package:otogurashi/sharing/song_catalog.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';

void main() {
  late Directory root;
  late ProjectDatabase db;
  late _Store store;
  late _Transport transport;
  late SharedFolderService service;
  late ServerSongCatalog catalog;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('song-catalog-test-');
    db = await ProjectDatabase.open(root);
    store = _Store()..values['shared.server'] = _server;
    transport = _Transport();
    service = SharedFolderService(
      database: db,
      assets: SqliteAssetRepository(db, inspector: const _Inspector()),
      secureStore: store,
      client: transport,
    );
    catalog = ServerSongCatalog(service);
  });

  tearDown(() async {
    service.close();
    db.close();
    await root.delete(recursive: true);
  });

  void logIn() {
    store.values['shared.session.${Uri.encodeComponent(_server)}'] =
        jsonEncode({
          'server': _server,
          'token': _token,
          'expiresAt': '2099-01-01T00:00:00Z',
          'account': {
            'id': 'account',
            'displayName': 'はる',
            'plan': 'free',
            'maxOwnedFolders': 1,
          },
        });
  }

  test('the catalogue is unavailable until a server is set up', () async {
    expect(await catalog.available(), isTrue);
    store.values.remove('shared.server');
    expect(await catalog.available(), isFalse);
    await expectLater(
      catalog.popular(),
      throwsA(
        isA<SongCatalogException>().having(
          (error) => error.code,
          'code',
          'server_missing',
        ),
      ),
    );
    expect(transport.requests, isEmpty);
  });

  test('listing needs no account and pages with the server cursor', () async {
    transport.respond = (method, uri) => _json({
      'songs': [
        _listed('s1', 'ゆうがたのうた', uses: 12),
        {'id': '', 'title': 'broken'},
        'not a song',
      ],
      if (uri.path == '/v1/songs') 'next': '2a',
    });
    final first = await catalog.newest();
    expect(first.songs.single.title, 'ゆうがたのうた');
    expect(first.songs.single.uses, 12);
    expect(first.songs.single.rights, SongRights.publicDomain);
    expect(first.next, '2a');
    final second = await catalog.newest(after: first.next);
    expect(second.next, isNull);
    await catalog.popular();
    expect(transport.requests.map((r) => '${r.method} ${r.uri.path}'), [
      'GET /v1/songs',
      'GET /v1/songs/after/2a',
      'GET /v1/songs/popular',
    ]);
    expect(
      transport.requests.every((r) => !r.headers.containsKey('X-Oto-Session')),
      isTrue,
    );
  });

  test('a fetched song is ready to play and to keep', () async {
    transport.respond = (method, uri) => _json({
      'song': {
        ..._listed(_id, 'ゆうがたのうた'),
        'credit': 'むかしのうた',
        'lanes': _lanes,
      },
    });
    final song = await catalog.fetch(_summary);
    expect(song.id, 'catalog-$_id');
    expect(song.remoteId, _id);
    expect(song.origin, SongOrigin.catalog);
    expect(song.title, 'ゆうがたのうた');
    expect(song.credit, 'むかしのうた');
    expect(song.author, 'はる');
    expect(song.lanes.first, _lanes.first);

    // a song without a melody is not a song
    transport.respond = (method, uri) => _json({
      'song': {..._listed(_id, 'からっぽ'), 'lanes': <Object>[[], [], []]},
    });
    await expectLater(
      catalog.fetch(_summary),
      throwsA(isA<SongCatalogException>()),
    );
  });

  test('posting sends the score with the account, and needs one', () async {
    final song = CustomSong(
      id: 'local',
      title: 'じぶんのうた',
      credit: 'じぶん',
      lanes: _lanes,
    );
    await expectLater(
      catalog.post(song, SongRights.own),
      throwsA(
        isA<SongCatalogException>().having(
          (error) => error.needsLogin,
          'needsLogin',
          isTrue,
        ),
      ),
    );
    expect(transport.requests, isEmpty);

    logIn();
    transport.respond = (method, uri) => _json({
      'song': {..._listed(_id, 'じぶんのうた'), 'status': 'public'},
    }, 201);
    final posted = await catalog.post(song, SongRights.own);
    expect(posted.id, _id);
    final request = transport.requests.single;
    expect('${request.method} ${request.uri.path}', 'POST /v1/songs');
    expect(request.headers['X-Oto-Session'], _token);
    expect(jsonDecode(utf8.decode(request.bytes)), {
      'title': 'じぶんのうた',
      'credit': 'じぶん',
      'rights': 'own',
      'score': {
        'v': 1,
        'beats': 32,
        'lanes': [..._lanes, <Object>[], <Object>[]],
      },
    });
  });

  test('using, reporting and removing go to the right place', () async {
    logIn();
    transport.respond = (method, uri) => _json({'ok': true, 'uses': 3});
    await catalog.countUse(_id);
    await catalog.report(_id, SongReportReason.rights, note: ' そっくりです ');
    await catalog.remove(_id);
    expect(transport.requests.map((r) => '${r.method} ${r.uri.path}'), [
      'POST /v1/songs/$_id/use',
      'POST /v1/songs/$_id/report',
      'DELETE /v1/songs/$_id',
    ]);
    expect(transport.requests[0].headers.containsKey('X-Oto-Session'), isFalse);
    expect(jsonDecode(utf8.decode(transport.requests[1].bytes)), {
      'reason': 'rights',
      'note': 'そっくりです',
    });
    expect(transport.requests[2].headers['X-Oto-Session'], _token);
  });

  test('what the server refuses is told in plain words', () async {
    logIn();
    Future<SongCatalogException> refused(int status, String code) async {
      transport.respond = (method, uri) => _json({
        'error': {'code': code, 'message': 'English from the server'},
      }, status);
      try {
        await catalog.mine();
      } on SongCatalogException catch (error) {
        return error;
      }
      fail('expected a refusal for $code');
    }

    expect((await refused(409, 'song_limit')).message, contains('30曲'));
    expect((await refused(429, 'post_limit')).message, contains('明日'));
    expect((await refused(404, 'song_not_found')).message, contains('公開されていません'));
    expect((await refused(400, 'invalid_lanes')).message, contains('別のMIDI'));
    expect((await refused(429, 'rate_limited')).message, contains('少し待って'));
    // an expired login asks for a new one
    logIn();
    expect((await refused(401, 'session_expired')).needsLogin, isTrue);

    logIn();
    transport.respond = (method, uri) => throw const SocketException('down');
    await expectLater(
      catalog.popular(),
      throwsA(
        isA<SongCatalogException>().having(
          (error) => error.code,
          'code',
          'network',
        ),
      ),
    );
  });
}

const _server = 'https://share.example';
const _id = '11111111-1111-4111-8111-111111111111';
final _token = List.filled(64, 'a').join();
const _lanes = [
  [
    [0, 480, 60],
    [480, 480, 62],
  ],
];
const _summary = CatalogSong(
  id: _id,
  title: 'ゆうがたのうた',
  credit: '',
  author: 'はる',
  uses: 0,
);

Map<String, Object?> _listed(String id, String title, {int uses = 0}) => {
  'id': id,
  'title': title,
  'credit': '',
  'rights': 'public_domain',
  'author': 'はる',
  'beats': 32,
  'uses': uses,
  'createdAt': '2026-10-14T00:00:00.000Z',
};

Future<SharedHttpResponse> _json(Object body, [int status = 200]) async =>
    SharedHttpResponse(status, Stream.value(utf8.encode(jsonEncode(body))));

final class _Store implements SharedSecureStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

final class _Transport implements SharedHttpTransport {
  final requests =
      <
        ({String method, Uri uri, Map<String, String> headers, List<int> bytes})
      >[];
  late Future<SharedHttpResponse> Function(String method, Uri uri) respond;

  @override
  Future<SharedHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
  }) async {
    final bytes = body == null
        ? <int>[]
        : await body.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    requests.add((method: method, uri: uri, headers: headers, bytes: bytes));
    return respond(method, uri);
  }

  @override
  void close() {}
}

final class _Inspector implements AssetInspector {
  const _Inspector();

  @override
  Future<InspectedAsset> inspect(String path) async => const InspectedAsset(
    durationUs: 1000000,
    width: 640,
    height: 480,
    rotation: 0,
  );
}
