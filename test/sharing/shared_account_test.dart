import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/sharing/shared_folder_service.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';

import 'shared_folder_service_test.dart'
    show
        MemoryStore,
        FakeTransport,
        Inspector,
        jsonResponse,
        folder,
        folderId,
        token,
        invite;

class Browser implements SharedAccountBrowser {
  late Future<Uri> Function(Uri) respond;
  int calls = 0;
  @override
  Future<Uri> authenticate(Uri url) {
    calls++;
    return respond(url);
  }
}

const origin = 'https://share.example';
const sessionKey = 'shared.session.https%3A%2F%2Fshare.example';
Map<String, dynamic> accountJson([String id = 'account']) => {
  'id': id,
  'displayName': 'Name',
  'plan': 'free',
  'maxOwnedFolders': 1,
};
Map<String, dynamic> entry() => {
  'folder': folder(),
  'membership': {
    'folderId': folderId,
    'memberId': 'member',
    'title': 'Friends',
    'role': 'member',
    'token': token,
  },
};
void main() {
  late Directory root;
  late ProjectDatabase db;
  late SqliteAssetRepository assets;
  late MemoryStore store;
  late FakeTransport transport;
  late Browser browser;
  late SharedFolderService service;
  void seed([String id = 'account']) {
    store.values[sessionKey] = jsonEncode({
      'server': origin,
      'token': token,
      'expiresAt': '2099-01-01T00:00:00Z',
      'account': accountJson(id),
    });
  }

  void authFlow({
    String id = 'account',
    String? authorizeOrigin,
    bool wrongState = false,
  }) {
    transport.respond = (method, uri) async {
      switch (uri.path) {
        case '/v1/auth/start':
          return jsonResponse({
            'authorizeUrl': '${authorizeOrigin ?? origin}/auth#request=$token',
          });
        case '/v1/auth/exchange':
          return jsonResponse({
            'token': token,
            'expiresAt': '2099-01-01T00:00:00Z',
            'account': accountJson(id),
          });
        case '/v1/account/folders':
          return jsonResponse({
            'folders': [entry()],
          });
        default:
          return jsonResponse({'ok': true});
      }
    };
    browser.respond = (_) async {
      final start = jsonDecode(utf8.decode(transport.requests.first.bytes));
      return Uri.parse(
        'otograshi://auth?state=${wrongState ? token : start['state']}&code=$token',
      );
    };
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('shared-account-test-');
    db = await ProjectDatabase.open(root);
    assets = SqliteAssetRepository(db, inspector: Inspector());
    store = MemoryStore();
    store.values['shared.server'] = origin;
    transport = FakeTransport();
    browser = Browser();
    service = SharedFolderService(
      database: db,
      assets: assets,
      secureStore: store,
      client: transport,
      browser: browser,
    );
  });
  tearDown(() async {
    service.close();
    db.close();
    await root.delete(recursive: true);
  });
  test(
    'create and join require explicit login without launching browser',
    () async {
      for (final call in [
        () => service.createFolder('Folder', 'Name'),
        () => service.joinFolder(invite, 'Name'),
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<SharedFolderException>().having(
              (e) => e.code,
              'code',
              'login_required',
            ),
          ),
        );
      }
      expect(browser.calls, 0);
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'PKCE exchange restores membership with origin scoped secure secrets',
    () async {
      authFlow();
      expect((await service.signIn()).id, 'account');
      final start = jsonDecode(utf8.decode(transport.requests[0].bytes));
      final exchange = jsonDecode(utf8.decode(transport.requests[1].bytes));
      expect(exchange['state'], start['state']);
      expect(
        start['codeChallenge'],
        sha256
            .convert(utf8.encode(exchange['codeVerifier'] as String))
            .toString(),
      );
      expect(exchange['codeVerifier'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(transport.requests.last.headers['X-Oto-Session'], token);
      expect(transport.requests.last.headers['Authorization'], isNull);
      expect((await service.listMemberships()).single.accountId, 'account');
      expect(
        db.connection
            .select('SELECT metadata FROM shared_memberships')
            .single['metadata'],
        isNot(contains(token)),
      );
    },
  );
  test(
    'wrong origin never opens browser and callback state never exchanges',
    () async {
      authFlow(authorizeOrigin: 'https://evil.example');
      await expectLater(
        service.signIn(),
        throwsA(isA<SharedFolderException>()),
      );
      expect(browser.calls, 0);
      transport.requests.clear();
      authFlow(wrongState: true);
      await expectLater(
        service.signIn(),
        throwsA(isA<SharedFolderException>()),
      );
      expect(transport.requests, hasLength(1));
      expect(await service.account(), isNull);
    },
  );
  test('malformed expired and wrong origin sessions are removed', () async {
    seed();
    final value = jsonDecode(store.values[sessionKey]!);
    value['server'] = 'https://evil.example';
    store.values[sessionKey] = jsonEncode(value);
    expect(await service.account(), isNull);
    expect(store.values[sessionKey], isNull);
    seed();
    final expired = jsonDecode(store.values[sessionKey]!);
    expired['expiresAt'] = '2000-01-01T00:00:00Z';
    store.values[sessionKey] = jsonEncode(expired);
    expect(await service.account(), isNull);
    store.values[sessionKey] = '{}';
    expect(await service.account(), isNull);
  });
  test(
    'sign out removes account credentials and retains legacy membership',
    () async {
      authFlow();
      await service.signIn();
      db.connection.execute('INSERT INTO shared_memberships VALUES (?,?)', [
        'legacy',
        jsonEncode({
          'folderId': 'legacy',
          'memberId': 'old',
          'role': 'member',
          'title': 'Old',
          'server': origin,
        }),
      ]);
      store.values['shared.token.https%3A%2F%2Fshare.example.legacy.old'] =
          token;
      await service.signOut();
      expect(await service.account(), isNull);
      expect((await service.listMemberships()).single.folderId, 'legacy');
      expect(store.values.keys.where((k) => k.contains(folderId)), isEmpty);
      expect(
        store.values['shared.token.https%3A%2F%2Fshare.example.legacy.old'],
        token,
      );
    },
  );
  test('switching account clears old memberships before restoration', () async {
    seed('previous');
    db.connection.execute('INSERT INTO shared_memberships VALUES (?,?)', [
      'old-folder',
      jsonEncode({
        'folderId': 'old-folder',
        'memberId': 'old',
        'role': 'member',
        'title': 'Old',
        'server': origin,
        'accountId': 'previous',
      }),
    ]);
    store.values['shared.token.https%3A%2F%2Fshare.example.old-folder.old'] =
        token;
    authFlow(id: 'next');
    await service.signIn();
    expect((await service.listMemberships()).single.accountId, 'next');
    expect(store.values.keys.where((k) => k.contains('old-folder')), isEmpty);
  });
  test(
    '401 account response clears session and asks to log in again',
    () async {
      seed();
      transport.respond = (_, _) async => SharedHttpResponse(
        401,
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': {'code': 'session_expired'},
            }),
          ),
        ),
      );
      await expectLater(
        service.restoreMemberships(),
        throwsA(
          isA<SharedFolderException>().having(
            (e) => e.code,
            'code',
            'session_expired',
          ),
        ),
      );
      expect(await service.account(), isNull);
    },
  );
  test('restore validates all entries before changing credentials and removes missing rows', () async {
    authFlow();
    await service.signIn();
    final before = Map<String, String>.from(store.values);
    transport.respond = (_, _) async => jsonResponse({
      'folders': [
        entry(),
        {'folder': {}},
      ],
    });
    await expectLater(
      service.restoreMemberships(),
      throwsA(isA<SharedFolderException>()),
    );
    expect(store.values, before);
    expect((await service.listMemberships()).single.folderId, folderId);
    transport.respond = (_, _) async => jsonResponse({'folders': []});
    await service.restoreMemberships();
    expect(await service.listMemberships(), isEmpty);
    expect(store.values.keys.where((k) => k.contains(folderId)), isEmpty);
  });
  test(
    'retry after restore failure reuses saved login across service restart',
    () async {
      authFlow();
      final normal = transport.respond;
      transport.respond = (method, uri) async {
        if (uri.path == '/v1/account/folders') {
          throw const SocketException('offline');
        }
        return normal(method, uri);
      };
      await expectLater(service.signIn(), throwsA(isA<SocketException>()));
      expect((await service.account())!.id, 'account');
      expect(browser.calls, 1);
      service.close();
      service = SharedFolderService(
        database: db,
        assets: assets,
        secureStore: store,
        client: transport,
        browser: browser,
      );
      transport.respond = normal;
      expect((await service.signIn()).id, 'account');
      expect(browser.calls, 1);
    },
  );
  test(
    'owned folder quota error is actionable and retains retry UUID',
    () async {
      seed();
      transport.respond = (_, _) async => SharedHttpResponse(
        409,
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': {'code': 'owned_folder_limit'},
            }),
          ),
        ),
      );
      await expectLater(
        service.createFolder('Folder', 'Name'),
        throwsA(
          isA<SharedFolderException>()
              .having((e) => e.code, 'code', 'owned_folder_limit')
              .having((e) => e.message, 'message', contains('1つ')),
        ),
      );
      expect(
        store.values.keys.where((k) => k.startsWith('shared.creation.')),
        hasLength(1),
      );
    },
  );
  test(
    'failed creation reuses secure UUID after restart then clears on success',
    () async {
      seed();
      transport.respond = (_, _) async =>
          throw const SocketException('lost response');
      await expectLater(
        service.createFolder('Folder', 'Name'),
        throwsA(isA<SocketException>()),
      );
      final first = jsonDecode(utf8.decode(transport.requests.last.bytes));
      expect(
        first['creationId'],
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      service.close();
      service = SharedFolderService(
        database: db,
        assets: assets,
        secureStore: store,
        client: transport,
        browser: browser,
      );
      transport.respond = (_, _) async {
        final j = entry();
        j['membership']['role'] = 'owner';
        j['folder']['members'][0]['role'] = 'owner';
        return jsonResponse(j);
      };
      await service.createFolder('Folder', 'Name');
      final retry = jsonDecode(utf8.decode(transport.requests.last.bytes));
      expect(retry['creationId'], first['creationId']);
      expect(
        store.values.keys.where((k) => k.startsWith('shared.creation.')),
        isEmpty,
      );
    },
  );
}
