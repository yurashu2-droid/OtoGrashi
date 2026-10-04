import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/sharing/shared_folder_service.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';

class MemoryStore implements SharedSecureStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class FakeTransport implements SharedHttpTransport {
  final requests =
      <
        ({String method, Uri uri, Map<String, String> headers, List<int> bytes})
      >[];
  late Future<SharedHttpResponse> Function(String, Uri) respond;
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

class Inspector implements AssetInspector {
  @override
  Future<InspectedAsset> inspect(String path) async => const InspectedAsset(
    durationUs: 10000000,
    width: 640,
    height: 480,
    rotation: 0,
  );
}

const folderId = '11111111-1111-4111-8111-111111111111';
final token = List.filled(64, 'a').join();
final invite = 'https://share.example/invite/$folderId#$token';
Map<String, dynamic> folder() => {
  'id': folderId,
  'title': 'Friends',
  'createdAt': '2026-10-05T00:00:00Z',
  'members': [
    {'id': 'member', 'displayName': 'Name', 'role': 'member'},
  ],
  'clips': [],
  'limits': {
    'maxClipBytes': 52428800,
    'maxFolderBytes': 1073741824,
    'maxClips': 200,
    'maxMembers': 20,
  },
};
SharedHttpResponse jsonResponse(Object value) =>
    SharedHttpResponse(200, Stream.value(utf8.encode(jsonEncode(value))));
SharedClip clip(List<int> bytes) => SharedClip.fromJson({
  'id': sha256.convert(bytes).toString(),
  'sha256': sha256.convert(bytes).toString(),
  'label': 'Bird',
  'memberId': 'member',
  'memberName': 'Friend',
  'sizeBytes': bytes.length,
  'durationUs': 10000000,
  'width': 640,
  'height': 480,
  'rotation': 0,
  'audioTrackStartUs': 0,
  'selectionStartUs': 1000000,
  'selectionDurationUs': 2000000,
  'extension': 'mp4',
  'createdAt': '2026-10-05T00:00:00Z',
  'hasThumbnail': false,
});
void main() {
  late Directory root;
  late ProjectDatabase db;
  late SqliteAssetRepository assets;
  late MemoryStore store;
  late FakeTransport transport;
  late SharedFolderService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('shared-test-');
    db = await ProjectDatabase.open(root);
    assets = SqliteAssetRepository(db, inspector: Inspector());
  });
  tearDown(() async {
    service.close();
    db.close();
    await root.delete(recursive: true);
  });
  Future<void> join() async {
    store = MemoryStore();
    store.values['shared.server'] = 'https://share.example';
    store.values['shared.session.https%3A%2F%2Fshare.example'] = jsonEncode({
      'server': 'https://share.example',
      'token': token,
      'expiresAt': '2099-01-01T00:00:00Z',
      'account': {
        'id': 'account',
        'displayName': 'Name',
        'plan': 'free',
        'maxOwnedFolders': 1,
      },
    });
    transport = FakeTransport();
    transport.respond = (method, uri) async => jsonResponse({
      'membership': {
        'folderId': folderId,
        'memberId': 'member',
        'role': 'member',
        'title': 'Friends',
        'token': token,
      },
      'folder': folder(),
    });
    service = SharedFolderService(
      database: db,
      assets: assets,
      secureStore: store,
      client: transport,
    );
    await service.joinFolder(invite, 'Name');
  }

  test('membership survives restart without token in database and binds bearer to origin', () async {
    await join();
    expect(
      db.connection
          .select('SELECT metadata FROM shared_memberships')
          .single['metadata'],
      isNot(contains(token)),
    );
    final restarted = SharedFolderService(
      database: db,
      assets: assets,
      secureStore: store,
      client: transport,
    );
    expect(
      (await restarted.listMemberships()).single.server,
      Uri.parse('https://share.example'),
    );
    transport.respond = (method, uri) async =>
        jsonResponse({'folder': folder()});
    await restarted.refresh(folderId);
    expect(transport.requests.last.headers['Authorization'], 'Bearer $token');
    final before = transport.requests.length;
    await expectLater(
      restarted.joinFolder(
        invite.replaceFirst('share.example', 'evil.example'),
        'Name',
      ),
      throwsA(isA<SharedFolderException>()),
    );
    await expectLater(
      restarted.configureServer('https://evil.example'),
      throwsA(isA<SharedFolderException>()),
    );
    expect(transport.requests.length, before);
  });
  test('invitation parsing accepts custom link and rejects unsafe or malformed links', () async {
    await join();
    expect(
      SharedInvitation.parse(
        'otograshi://invite?url=${Uri.encodeComponent(invite)}',
      ).folderId,
      folderId,
    );
    for (final invalid in [
      invite.replaceFirst('https:', 'http:'),
      invite.replaceFirst('#', '#short'),
      invite.replaceFirst('/invite/', '/invite/../'),
      invite.replaceFirst('share.example', 'user:password@share.example'),
    ]) {
      expect(() => SharedInvitation.parse(invalid), throwsFormatException);
    }
  });
  test('truncated and mismatched downloads never import; retry imports then reuses selection', () async {
    await join();
    final bytes = utf8.encode('original video bytes');
    final remote = clip(bytes);
    transport.respond = (method, uri) async =>
        SharedHttpResponse(200, Stream.value(bytes.sublist(1)));
    await expectLater(
      service.download(folderId, remote),
      throwsA(isA<SharedFolderException>()),
    );
    expect(await assets.list(), isEmpty);
    transport.respond = (method, uri) async =>
        SharedHttpResponse(200, Stream.value(List.filled(bytes.length, 0)));
    await expectLater(
      service.download(folderId, remote),
      throwsA(isA<SharedFolderException>()),
    );
    expect(await assets.list(), isEmpty);
    transport.respond = (method, uri) async =>
        SharedHttpResponse(200, Stream.value(bytes));
    final imported = await service.download(folderId, remote);
    expect(imported.selectionStartUs, 1000000);
    expect(imported.label, 'Bird');
    final before = transport.requests.length;
    final reused = await service.download(folderId, remote);
    expect(reused.id, imported.id);
    expect(transport.requests.length, before);
    expect(await assets.list(), hasLength(1));
    transport.respond = (method, uri) async => jsonResponse({'ok': true});
    await service.deleteClip(folderId, remote.id);
    expect(await assets.list(), hasLength(1));
  });
  test('concurrent download requests share one import', () async {
    await join();
    final bytes = utf8.encode('concurrent bytes');
    final remote = clip(bytes);
    final gate = Completer<SharedHttpResponse>();
    transport.respond = (method, uri) => gate.future;
    final first = service.download(folderId, remote);
    final second = service.download(folderId, remote);
    gate.complete(SharedHttpResponse(200, Stream.value(bytes)));
    final results = await Future.wait([first, second]);
    expect(results[0].id, results[1].id);
    expect(await assets.list(), hasLength(1));
    expect(
      transport.requests.where((r) => r.uri.path.endsWith('/file')),
      hasLength(1),
    );
  });
  test(
    'opening an already joined invitation keeps the member credential',
    () async {
      await join();
      final before = await service.listMemberships();
      final calls = transport.requests.length;
      transport.respond = (method, uri) async {
        expect(method, 'GET');
        return jsonResponse({'folder': folder()});
      };
      await service.joinFolder(invite, 'Different name');
      expect(transport.requests.length, calls + 1);
      expect(
        (await service.listMemberships()).single.memberId,
        before.single.memberId,
      );
    },
  );
  test('upload retries use SHA id and streamed original bytes', () async {
    await join();
    final source = File('${root.path}/source.mp4');
    await source.writeAsBytes([1, 2, 3, 4]);
    final asset = await assets.importFile(source.path);
    transport.respond = (method, uri) async => jsonResponse({
      'clip': {'memberId': 'member'},
    });
    await service.upload(folderId, asset);
    await service.upload(folderId, asset);
    final requests = transport.requests
        .where((r) => r.method == 'PUT')
        .toList();
    expect(requests, hasLength(2));
    expect(requests[0].uri, requests[1].uri);
    expect(requests[0].uri.path, endsWith(asset.sha256));
    expect(requests[0].bytes, [1, 2, 3, 4]);
  });
  test('invalid join response persists no credentials or membership', () async {
    await join();
    await service.leaveFolder(folderId);
    final before = Map<String, String>.from(store.values);
    transport.respond = (method, uri) async => jsonResponse({
      'membership': {
        'folderId': folderId,
        'memberId': 'member',
        'role': 'unknown',
        'title': 'Friends',
        'token': token,
      },
      'folder': folder(),
    });
    await expectLater(
      service.joinFolder(invite, 'Name'),
      throwsA(isA<SharedFolderException>()),
    );
    expect(await service.listMemberships(), isEmpty);
    expect(store.values, before);
    transport.respond = (method, uri) async => jsonResponse({
      'membership': {
        'folderId': folderId,
        'memberId': 'member',
        'role': 'member',
        'title': 'Friends',
        'token': token,
      },
      'folder': {...folder(), 'id': 'other-folder'},
    });
    await expectLater(
      service.joinFolder(invite, 'Name'),
      throwsA(isA<SharedFolderException>()),
    );
    expect(await service.listMemberships(), isEmpty);
    expect(store.values, before);
  });
  test('leave forgets revoked or closed memberships but retains forbidden membership', () async {
    await join();
    for (final status in [401, 404]) {
      transport.respond = (method, uri) async => SharedHttpResponse(
        status,
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': {'code': 'gone', 'message': 'gone'},
            }),
          ),
        ),
      );
      await service.leaveFolder(folderId);
      expect(await service.listMemberships(), isEmpty);
      expect(
        store.values.keys.where((key) => key.startsWith('shared.token.')),
        isEmpty,
      );
      await join();
    }
    transport.respond = (method, uri) async => SharedHttpResponse(
      403,
      Stream.value(
        utf8.encode(
          jsonEncode({
            'error': {'code': 'owner_cannot_leave', 'message': 'close first'},
          }),
        ),
      ),
    );
    await expectLater(
      service.leaveFolder(folderId),
      throwsA(isA<SharedFolderException>()),
    );
    expect(await service.listMemberships(), hasLength(1));
  });
  test('missing local original triggers download again', () async {
    await join();
    final bytes = utf8.encode('missing original');
    final remote = clip(bytes);
    transport.respond = (method, uri) async =>
        SharedHttpResponse(200, Stream.value(bytes));
    final first = await service.download(folderId, remote);
    await File(await assets.resolvePath(first.id)).delete();
    final replacement = await service.download(folderId, remote);
    expect(replacement.id, isNot(first.id));
    expect(
      await File(await assets.resolvePath(replacement.id)).readAsBytes(),
      bytes,
    );
  });
  test('thumbnail failures report uploaded video and duplicates retain uploader thumbnail', () async {
    await join();
    final source = File('${root.path}/source.mp4');
    await source.writeAsBytes([1, 2, 3, 4]);
    final asset = await assets.importFile(source.path);
    final before = transport.requests.length;
    await expectLater(
      service.upload(folderId, asset, thumbnail: Uint8List(524289)),
      throwsA(isA<SharedFolderException>()),
    );
    expect(transport.requests.length, before);
    transport.respond = (method, uri) async => jsonResponse({
      'clip': {'memberId': 'another-member'},
    });
    await service.upload(
      folderId,
      asset,
      thumbnail: Uint8List.fromList([255, 216, 255]),
    );
    expect(
      transport.requests.where((r) => r.uri.path.endsWith('/thumbnail')),
      isEmpty,
    );
    transport.respond = (method, uri) async => uri.path.endsWith('/thumbnail')
        ? SharedHttpResponse(
            500,
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'error': {'code': 'failed', 'message': 'failed'},
                }),
              ),
            ),
          )
        : jsonResponse({
            'clip': {'memberId': 'member'},
          });
    await expectLater(
      service.upload(
        folderId,
        asset,
        thumbnail: Uint8List.fromList([255, 216, 255]),
      ),
      throwsA(
        isA<SharedFolderException>().having(
          (error) => error.code,
          'code',
          'thumbnail_failed_after_upload',
        ),
      ),
    );
  });
}
