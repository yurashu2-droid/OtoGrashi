import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/features/sharing/shared_folders_screen.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';
import 'package:otogurashi/sharing/shared_folder_service.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';

class _Store implements SharedSecureStore {
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

class _Presentation extends Fake implements MediaPresentationGateway {}

class _Browser implements SharedAccountBrowser {
  String? state;
  @override
  Future<Uri> authenticate(Uri authorizeUrl) async => Uri(
    scheme: 'otograshi',
    host: 'auth',
    queryParameters: {'state': state!, 'code': 'c' * 64},
  );
}

const _folderId = '11111111-1111-4111-8111-111111111111';
const _memberId = '22222222-2222-4222-8222-222222222222';

Map<String, Object> _folder() => {
  'id': _folderId,
  'title': 'みんなの音',
  'createdAt': '2026-10-05T00:00:00Z',
  'members': [
    {'id': _memberId, 'displayName': 'ゆら', 'role': 'owner'},
  ],
  'clips': <Object>[],
  'limits': {
    'maxClipBytes': 52428800,
    'maxFolderBytes': 1073741824,
    'maxClips': 200,
    'maxMembers': 20,
  },
};

class _Transport implements SharedHttpTransport {
  _Transport(this.browser);
  final _Browser browser;
  final requests =
      <
        ({
          String method,
          Uri uri,
          Map<String, String> headers,
          Map<String, dynamic> data,
        })
      >[];
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
    final data = bytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    requests.add((method: method, uri: uri, headers: headers, data: data));
    final Object response;
    switch (uri.path) {
      case '/v1/auth/start':
        browser.state = data['state'] as String;
        response = {
          'authorizeUrl': 'https://share.example/auth#request=${'b' * 64}',
        };
      case '/v1/auth/exchange':
        response = {
          'token': 'd' * 64,
          'expiresAt': '2099-01-01T00:00:00Z',
          'account': {
            'id': '33333333-3333-4333-8333-333333333333',
            'displayName': 'ゆら',
            'plan': 'free',
            'maxOwnedFolders': 1,
          },
        };
      case '/v1/account/folders':
        response = {'folders': <Object>[]};
      case '/v1/folders':
        response = {
          'folder': _folder(),
          'membership': {
            'folderId': _folderId,
            'memberId': _memberId,
            'role': 'owner',
            'title': 'みんなの音',
            'token': 'e' * 64,
          },
        };
      case '/v1/folders/$_folderId':
        response = {'folder': _folder()};
      default:
        throw StateError('Unexpected request: $method ${uri.path}');
    }
    return SharedHttpResponse(
      200,
      Stream.value(utf8.encode(jsonEncode(response))),
    );
  }

  @override
  void close() {}
}

void main() {
  testWidgets('passkey login does not create a folder until the user submits', (
    tester,
  ) async {
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('shared-screen-');
      final database = await ProjectDatabase.open(root);
      final assets = SqliteAssetRepository(database);
      final browser = _Browser();
      final transport = _Transport(browser);
      final service = SharedFolderService(
        database: database,
        assets: assets,
        secureStore: _Store(),
        client: transport,
        browser: browser,
        initialServer: Uri.parse('https://share.example'),
      );
      return (root, database, assets, transport, service);
    });
    final (root, database, assets, transport, service) = setup!;
    addTearDown(() async {
      service.close();
      database.close();
      await root.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: SharedFoldersScreen(
          service: service,
          assets: assets,
          presentation: _Presentation(),
          onMakeSong: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(transport.requests, isEmpty);
    await tester.tap(find.text('共有フォルダをつくる'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'フォルダ名',
      ),
      'みんなの音',
    );
    final loginButton = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('パスキーで続ける'),
    );
    await tester.tap(loginButton);
    // Re-enabling the focused text field starts its repeating cursor animation.
    // Wait for the requested state, rather than waiting for every animation to stop.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      transport.requests.where((r) => r.uri.path == '/v1/folders'),
      isEmpty,
    );
    expect(
      find.text('つくる'),
      findsOneWidget,
      reason:
          'Login requests: ${transport.requests.map((r) => r.uri.path).join(', ')}',
    );
    await tester.tap(find.text('つくる'));
    await tester.pumpAndSettle();
    final create = transport.requests.singleWhere(
      (r) => r.uri.path == '/v1/folders',
    );
    expect(create.headers['X-Oto-Session'], 'd' * 64);
    expect(create.data['displayName'], 'ゆら');
    expect(
      create.data['creationId'],
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(find.text('みんなが見つけた音'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
