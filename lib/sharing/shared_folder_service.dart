import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/clip_asset.dart';
import '../storage/asset_repository.dart';
import '../storage/project_database.dart';
import 'shared_models.dart';
export 'shared_models.dart';

abstract interface class SharedSecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class PluginSharedSecureStore implements SharedSecureStore {
  final FlutterSecureStorage storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

final class SharedHttpResponse {
  SharedHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final Stream<List<int>> body;
}

abstract interface class SharedHttpTransport {
  Future<SharedHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
  });
  void close();
}

final class IoSharedHttpTransport implements SharedHttpTransport {
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  @override
  Future<SharedHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? contentLength,
  }) async {
    final request = await _http
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (contentLength != null) request.contentLength = contentLength;
    try {
      if (body != null) {
        await request
            .addStream(body.timeout(const Duration(seconds: 30)))
            .timeout(const Duration(minutes: 5));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      return SharedHttpResponse(
        response.statusCode,
        response.timeout(const Duration(seconds: 30)),
      );
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  @override
  void close() => _http.close(force: true);
}

final class SharedFolderService {
  SharedFolderService({
    required ProjectDatabase database,
    required this._assets,
    SharedSecureStore? secureStore,
    SharedHttpTransport? client,
    this._initialServer,
  }) : _database = database,
       _store = secureStore ?? PluginSharedSecureStore(),
       _client = client ?? IoSharedHttpTransport() {
    database.connection.execute(
      'CREATE TABLE IF NOT EXISTS shared_memberships (folder_id TEXT PRIMARY KEY, metadata TEXT NOT NULL)',
    );
  }
  final ProjectDatabase _database;
  final AssetRepository _assets;
  final SharedSecureStore _store;
  final SharedHttpTransport _client;
  final Uri? _initialServer;
  final Map<String, Future<ClipAsset>> _downloads = {};
  static const _environment = String.fromEnvironment('OTO_SHARED_API_URL');
  Future<Uri?> configuredServer() async {
    final value =
        _initialServer?.toString() ??
        (_environment.isNotEmpty
            ? _environment
            : await _store.read('shared.server'));
    return value == null ? null : sharedOrigin(value);
  }

  Future<void> configureServer(String url) async {
    final server = sharedOrigin(url);
    final memberships = await listMemberships();
    if (memberships.any((m) => m.server != server)) {
      throw const SharedFolderException('参加中のフォルダと異なるサーバーには変更できません。');
    }
    await _store.write('shared.server', server.toString());
  }

  Future<List<SharedFolderMembership>> listMemberships() async => _database
      .connection
      .select('SELECT metadata FROM shared_memberships')
      .map((r) {
        final j = jsonDecode(r['metadata'] as String) as Map<String, dynamic>;
        return SharedFolderMembership.fromJson(j, sharedOrigin(j['server']));
      })
      .toList();
  Future<SharedFolderMembership> _membership(String id) async {
    _id(id);
    final values = await listMemberships();
    for (final m in values) {
      if (m.folderId == id) return m;
    }
    throw const SharedFolderException('このフォルダには参加していません。');
  }

  String _key(SharedFolderMembership m) =>
      'shared.token.${Uri.encodeComponent(m.server.toString())}.${m.folderId}.${m.memberId}';
  Future<SharedFolder> _save(
    Map<String, dynamic> j,
    Uri server, {
    String? expectedFolderId,
    String? expectedRole,
  }) async {
    late SharedFolderMembership m;
    late SharedFolder folder;
    late String token;
    try {
      m = SharedFolderMembership.fromJson(j['membership'], server);
      folder = SharedFolder.fromJson(j['folder']);
      token = j['membership']['token'] as String;
      _id(m.folderId);
      _id(m.memberId);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ||
          m.folderId != folder.id ||
          (expectedFolderId != null && folder.id != expectedFolderId) ||
          !const {'owner', 'member'}.contains(m.role) ||
          (expectedRole != null && m.role != expectedRole) ||
          !folder.members.any(
            (member) => member.id == m.memberId && member.role == m.role,
          )) {
        throw const FormatException();
      }
    } catch (_) {
      throw const SharedFolderException('サーバーの応答が正しくありません。');
    }
    await _store.write(_key(m), token);
    _database.connection.execute(
      'INSERT OR REPLACE INTO shared_memberships VALUES (?,?)',
      [m.folderId, jsonEncode(m.toJson())],
    );
    return folder;
  }

  Future<SharedFolder> createFolder(String title, String displayName) async {
    final server = await configuredServer();
    if (server == null) throw const SharedFolderException('共有サーバーを設定してください。');
    return _save(
      await _json(
        'POST',
        server.resolve('/v1/folders'),
        data: {'title': title, 'displayName': displayName},
      ),
      server,
      expectedRole: 'owner',
    );
  }

  Future<SharedFolder> joinFolder(String invitation, String displayName) async {
    final link = SharedInvitation.parse(invitation);
    final current = await configuredServer();
    if (current != null && current != link.server) {
      throw const SharedFolderException('招待リンクのサーバーが設定と異なります。');
    }
    if ((await listMemberships()).any((m) => m.server != link.server)) {
      throw const SharedFolderException('招待リンクのサーバーが参加中のフォルダと異なります。');
    }
    final joined = (await listMemberships()).where(
      (m) => m.folderId == link.folderId && m.server == link.server,
    );
    if (joined.isNotEmpty) {
      try {
        // Opening one's own invitation must not replace the owner credential
        // with a fresh member or consume another participant slot.
        return await refresh(link.folderId);
      } on SharedFolderException catch (error) {
        if (error.statusCode != 401 && error.statusCode != 404) rethrow;
        await _forget(joined.first);
      }
    }
    final j = await _json(
      'POST',
      link.server.resolve('/v1/folders/${link.folderId}/join'),
      data: {'inviteToken': link.token, 'displayName': displayName},
    );
    final folder = await _save(j, link.server, expectedFolderId: link.folderId);
    if (current == null) await configureServer(link.server.toString());
    return folder;
  }

  Future<SharedHttpResponse> _request(
    String method,
    Uri uri, {
    SharedFolderMembership? membership,
    Map<String, String> headers = const {},
    Stream<List<int>>? body,
    int? length,
  }) async {
    final actual = {...headers};
    if (membership != null) {
      if (uri.origin != membership.server.origin) {
        throw const SharedFolderException('共有サーバーが一致しません。');
      }
      final token = await _store.read(_key(membership));
      if (token == null) throw const SharedFolderException('参加情報が見つかりません。');
      actual['Authorization'] = 'Bearer $token';
    }
    final response = await _client
        .send(method, uri, headers: actual, body: body, contentLength: length)
        .timeout(const Duration(minutes: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final bytes = await _collect(response.body, 1024 * 1024);
      String message = '共有処理に失敗しました。再試行してください。';
      String? code;
      try {
        final error = decodeSharedJson(bytes)['error'];
        code = error['code'];
      } catch (_) {}
      message = switch (code) {
        'unauthorized' => '参加情報が無効になりました。新しい招待リンクで参加し直してください。',
        'folder_not_found' => 'この共有フォルダは閉じられたか、見つかりません。',
        'invalid_invite' => '招待リンクの期限が切れたか、更新されています。新しいリンクを受け取ってください。',
        'member_limit' => 'このフォルダの参加人数が上限に達しました。',
        'rate_limited' => '操作が続いています。少し待ってから再試行してください。',
        'owner_required' => 'フォルダをつくった人だけが使える操作です。',
        'uploader_required' => 'この音を追加した人か、フォルダをつくった人だけが使える操作です。',
        'owner_cannot_leave' => 'フォルダをつくった人は、フォルダを閉じて退出してください。',
        'folder_limit' => '共有フォルダの容量か素材数が上限に達しました。',
        'clip_too_large' => '動画は50MB以内にしてください。',
        'body_too_large' => '送信するデータが大きすぎます。',
        'upload_pending' => 'この音は送信中です。少し待ってから更新してください。',
        'upload_timeout' ||
        'upload_integrity' ||
        'invalid_length' => '動画を正しく送信できませんでした。通信を確認して再試行してください。',
        'clip_not_found' ||
        'file_not_found' => 'この音は共有フォルダから削除されています。更新してください。',
        'member_not_found' => 'この参加者はすでに退出しています。更新してください。',
        'clip_conflict' => '同じ音の送信情報が一致しません。更新して再試行してください。',
        'invalid_text' => 'フォルダ名・表示名・音の名前の長さを確認してください。',
        'invalid_metadata' ||
        'invalid_media_type' ||
        'invalid_hash' => 'この素材の情報を確認できませんでした。別の素材で試してください。',
        _ => message,
      };
      throw SharedFolderException(
        message,
        code: code,
        statusCode: response.statusCode,
      );
    }
    return response;
  }

  Future<Map<String, dynamic>> _json(
    String method,
    Uri uri, {
    SharedFolderMembership? membership,
    Map<String, dynamic>? data,
  }) async {
    final bytes = data == null ? null : utf8.encode(jsonEncode(data));
    final r = await _request(
      method,
      uri,
      membership: membership,
      headers: bytes == null ? {} : {'Content-Type': 'application/json'},
      body: bytes == null ? null : Stream.value(bytes),
      length: bytes?.length,
    );
    return decodeSharedJson(await _collect(r.body, 1024 * 1024));
  }

  Uri _url(SharedFolderMembership m, String suffix) =>
      m.server.resolve('/v1/folders/${m.folderId}$suffix');
  Future<SharedFolder> refresh(String folderId) async {
    final m = await _membership(folderId);
    final folder = SharedFolder.fromJson(
      (await _json('GET', _url(m, ''), membership: m))['folder'],
    );
    _database.connection.execute(
      'UPDATE shared_memberships SET metadata=? WHERE folder_id=?',
      [
        jsonEncode({...m.toJson(), 'title': folder.title}),
        folderId,
      ],
    );
    return folder;
  }

  Future<Uri> invite(String folderId) async {
    final m = await _membership(folderId);
    final value =
        (await _json('POST', _url(m, '/invite'), membership: m))['inviteUrl']
            as String;
    final parsed = SharedInvitation.parse(value);
    if (parsed.server != m.server || parsed.folderId != folderId) {
      throw const SharedFolderException('招待リンクの応答が正しくありません。');
    }
    return Uri.parse(value);
  }

  Future<void> renameFolder(String folderId, String title) async {
    final m = await _membership(folderId);
    await _json('PATCH', _url(m, ''), membership: m, data: {'title': title});
    await refresh(folderId);
  }

  Future<void> upload(
    String folderId,
    ClipAsset asset, {
    Uint8List? thumbnail,
    void Function(double)? onProgress,
  }) async {
    if (thumbnail != null && thumbnail.length > 524288) {
      throw const SharedFolderException('サムネイルが大きすぎます。動画はまだ送信していません。');
    }
    final m = await _membership(folderId);
    _hash(asset.sha256);
    final file = File(await _assets.resolvePath(asset.id));
    final size = await file.length();
    if (size > 52428800) throw const SharedFolderException('動画は50MB以内にしてください。');
    final extension = file.path.toLowerCase().endsWith('.mov') ? 'mov' : 'mp4';
    final metadata = {
      'label': asset.label,
      'sha256': asset.sha256,
      'sizeBytes': size,
      'durationUs': asset.durationUs,
      'width': asset.width,
      'height': asset.height,
      'rotation': asset.rotation,
      'audioTrackStartUs': asset.audioTrackStartUs,
      'selectionStartUs': asset.selectionStartUs,
      'selectionDurationUs': asset.selectionDurationUs,
      'extension': extension,
    };
    var sent = 0;
    final r = await _request(
      'PUT',
      _url(m, '/clips/${asset.sha256}'),
      membership: m,
      headers: {
        'Content-Type': extension == 'mov' ? 'video/quicktime' : 'video/mp4',
        'X-Clip-Metadata': base64Url
            .encode(utf8.encode(jsonEncode(metadata)))
            .replaceAll('=', ''),
      },
      body: file.openRead().map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent / size);
        return chunk;
      }),
      length: size,
    );
    final uploaded =
        decodeSharedJson(await _collect(r.body, 1024 * 1024))['clip']
            as Map<String, dynamic>;
    // An idempotent duplicate may belong to someone else; keep their thumbnail.
    if (thumbnail != null && uploaded['memberId'] == m.memberId) {
      try {
        final response = await _request(
          'PUT',
          _url(m, '/clips/${asset.sha256}/thumbnail'),
          membership: m,
          headers: {
            'Content-Type': thumbnail.length > 3 && thumbnail[0] == 137
                ? 'image/png'
                : 'image/jpeg',
          },
          body: Stream.value(thumbnail),
          length: thumbnail.length,
        );
        await _collect(response.body, 1024 * 1024);
      } catch (_) {
        throw const SharedFolderException(
          '動画は共有済みですが、サムネイルを送信できませんでした。更新して共有内容を確認してください。',
          code: 'thumbnail_failed_after_upload',
        );
      }
    }
  }

  Future<Uint8List?> thumbnail(String folderId, String clipId) async {
    final m = await _membership(folderId);
    _hash(clipId);
    try {
      final r = await _request(
        'GET',
        _url(m, '/clips/$clipId/thumbnail'),
        membership: m,
      );
      return Uint8List.fromList(await _collect(r.body, 524288));
    } on SharedFolderException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<ClipAsset> download(
    String folderId,
    SharedClip clip, {
    void Function(double)? onProgress,
  }) {
    final key = '$folderId/${clip.sha256}';
    return _downloads.putIfAbsent(
      key,
      () => _download(folderId, clip, onProgress).whenComplete(() {
        // Returning remove(key) returns this pending Future itself. Cleanup must
        // complete synchronously, otherwise success and failure both self-await.
        _downloads.remove(key);
      }),
    );
  }

  Future<ClipAsset> _download(
    String folderId,
    SharedClip clip,
    void Function(double)? onProgress,
  ) async {
    final m = await _membership(folderId);
    _hash(clip.id);
    _hash(clip.sha256);
    if (clip.id != clip.sha256 ||
        clip.sizeBytes <= 0 ||
        clip.sizeBytes > 52428800 ||
        !const {'mp4', 'mov', '.mp4', '.mov'}.contains(clip.extension)) {
      throw const SharedFolderException('動画情報が正しくありません。');
    }
    for (final asset in await _assets.list()) {
      if (asset.sha256 == clip.sha256) {
        try {
          await _assets.resolvePath(asset.id);
          return asset;
        } on AssetFileMissing {
          // Missing originals cannot satisfy the download; fetch a fresh copy.
        } on AssetNotFound {
          // The asset may have been deleted since listing it.
        }
      }
    }
    final temporary = await Directory.systemTemp.createTemp(
      'otograshi-shared-',
    );
    final file = File(
      '${temporary.path}/download.${clip.extension.replaceAll('.', '')}',
    );
    try {
      final r = await _request(
        'GET',
        _url(m, '/clips/${clip.id}/file'),
        membership: m,
      );
      final sink = file.openWrite();
      var count = 0;
      try {
        await sink.addStream(
          _bounded(r.body).map((bytes) {
            count += bytes.length;
            if (count > clip.sizeBytes) {
              throw const SharedFolderException('ダウンロードした動画のサイズが一致しません。');
            }
            onProgress?.call(count / clip.sizeBytes);
            return bytes;
          }),
        );
      } finally {
        await sink.close();
      }
      if (count != clip.sizeBytes ||
          (await sha256.bind(file.openRead()).first).toString() !=
              clip.sha256) {
        throw const SharedFolderException('動画を正しく取得できませんでした。再試行してください。');
      }
      final imported = await _assets.importFile(file.path);
      if (clip.selectionStartUs >= 0 &&
          clip.selectionDurationUs > 0 &&
          clip.selectionStartUs + clip.selectionDurationUs <=
              imported.durationUs) {
        _database.connection.execute(
          'UPDATE assets SET selection_start_us=?,selection_duration_us=?,label=? WHERE id=?',
          [
            clip.selectionStartUs,
            clip.selectionDurationUs,
            clip.label,
            imported.id,
          ],
        );
        return (await _assets.load(imported.id))!;
      }
      return imported;
    } finally {
      await temporary.delete(recursive: true);
    }
  }

  Future<void> deleteClip(String folderId, String clipId) async {
    _hash(clipId);
    final m = await _membership(folderId);
    await _json('DELETE', _url(m, '/clips/$clipId'), membership: m);
  }

  Future<void> removeMember(String folderId, String memberId) async {
    _id(memberId);
    final m = await _membership(folderId);
    await _json('DELETE', _url(m, '/members/$memberId'), membership: m);
    if (memberId == m.memberId) await _forget(m);
  }

  Future<void> leaveFolder(String folderId) async {
    final m = await _membership(folderId);
    try {
      await removeMember(folderId, m.memberId);
    } on SharedFolderException catch (error) {
      if (error.statusCode != 401 && error.statusCode != 404) rethrow;
      await _forget(m);
    }
  }

  Future<void> deleteFolder(String folderId) async {
    final m = await _membership(folderId);
    await _json('DELETE', _url(m, ''), membership: m);
    await _forget(m);
  }

  Future<void> _forget(SharedFolderMembership m) async {
    await _store.delete(_key(m));
    _database.connection.execute(
      'DELETE FROM shared_memberships WHERE folder_id=?',
      [m.folderId],
    );
  }

  void close() => _client.close();
}

void _id(String value) {
  if (!RegExp(r'^[a-zA-Z0-9-]{1,100}$').hasMatch(value)) {
    throw const FormatException('IDが正しくありません。');
  }
}

void _hash(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw const FormatException('動画IDが正しくありません。');
  }
}

Stream<List<int>> _bounded(Stream<List<int>> stream) async* {
  final clock = Stopwatch()..start();
  await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
    if (clock.elapsed > const Duration(minutes: 5)) {
      throw const SharedFolderException('通信がタイムアウトしました。再試行してください。');
    }
    yield chunk;
  }
}

Future<List<int>> _collect(Stream<List<int>> stream, int limit) async {
  final bytes = <int>[];
  await for (final chunk in _bounded(stream)) {
    if (bytes.length + chunk.length > limit) {
      throw const SharedFolderException('サーバーの応答が大きすぎます。');
    }
    bytes.addAll(chunk);
  }
  return bytes;
}
