import 'dart:convert';

Uri sharedOrigin(String input) {
  final uri = Uri.parse(input.trim());
  if (uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('共有サーバーにはHTTPSのアドレスを指定してください。');
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

final class SharedInvitation {
  SharedInvitation._(this.server, this.folderId, this.token);
  final Uri server;
  final String folderId;
  final String token;
  static SharedInvitation parse(String text) {
    var uri = Uri.parse(text.trim());
    if (uri.scheme == 'otograshi' && uri.host == 'invite' && uri.path.isEmpty) {
      uri = Uri.parse(uri.queryParameters['url'] ?? '');
    }
    final parts = uri.pathSegments;
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        parts.length != 2 ||
        parts[0] != 'invite' ||
        !RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(parts[1]) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(uri.fragment)) {
      throw const FormatException('招待リンクが正しくありません。');
    }
    return SharedInvitation._(sharedOrigin(uri.origin), parts[1], uri.fragment);
  }
}

final class SharedFolderMembership {
  const SharedFolderMembership({
    required this.folderId,
    required this.memberId,
    required this.role,
    required this.title,
    required this.server,
    this.accountId,
  });
  final String folderId, memberId, role, title;
  final Uri server;
  final String? accountId;
  bool get isOwner => role == 'owner';
  factory SharedFolderMembership.fromJson(Map<String, dynamic> j, Uri server) =>
      SharedFolderMembership(
        folderId: j['folderId'],
        memberId: j['memberId'],
        role: j['role'],
        title: j['title'],
        server: server,
        accountId: j['accountId'] as String?,
      );
  Map<String, dynamic> toJson() => {
    'folderId': folderId,
    'memberId': memberId,
    'role': role,
    'title': title,
    'server': server.toString(),
    if (accountId != null) 'accountId': accountId,
  };
}

final class SharedMember {
  SharedMember.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      displayName = j['displayName'],
      role = j['role'];
  final String id, displayName, role;
}

final class SharedClip {
  SharedClip.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      label = j['label'],
      memberId = j['memberId'],
      memberName = j['memberName'],
      sha256 = j['sha256'],
      sizeBytes = j['sizeBytes'],
      durationUs = j['durationUs'],
      width = j['width'],
      height = j['height'],
      rotation = j['rotation'],
      selectionStartUs = j['selectionStartUs'],
      selectionDurationUs = j['selectionDurationUs'],
      audioTrackStartUs = j['audioTrackStartUs'],
      extension = j['extension'],
      createdAt = DateTime.parse(j['createdAt']),
      hasThumbnail = j['hasThumbnail'];
  final String id, label, memberId, memberName, sha256, extension;
  final int sizeBytes,
      durationUs,
      width,
      height,
      rotation,
      selectionStartUs,
      selectionDurationUs,
      audioTrackStartUs;
  final DateTime createdAt;
  final bool hasThumbnail;
}

final class SharedFolder {
  SharedFolder.fromJson(Map<String, dynamic> j)
    : id = j['id'],
      title = j['title'],
      createdAt = DateTime.parse(j['createdAt']),
      members = (j['members'] as List)
          .map((v) => SharedMember.fromJson(v))
          .toList(),
      clips = (j['clips'] as List).map((v) => SharedClip.fromJson(v)).toList(),
      limits = Map<String, int>.from(j['limits']);
  final String id, title;
  final DateTime createdAt;
  final List<SharedMember> members;
  final List<SharedClip> clips;
  final Map<String, int> limits;
}

class SharedFolderException implements Exception {
  const SharedFolderException(this.message, {this.code, this.statusCode});
  final String message;
  final String? code;
  final int? statusCode;
  @override
  String toString() => message;
}

Map<String, dynamic> decodeSharedJson(List<int> bytes) =>
    jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

final class SharedAccount {
  const SharedAccount({
    required this.id,
    required this.displayName,
    required this.plan,
    required this.maxOwnedFolders,
  });
  final String id, displayName, plan;
  final int maxOwnedFolders;
  factory SharedAccount.fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final name = j['displayName'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{1,100}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 100 ||
        j['plan'] != 'free' ||
        j['maxOwnedFolders'] != 1) {
      throw const FormatException('アカウント情報が正しくありません。');
    }
    return SharedAccount(
      id: id,
      displayName: name,
      plan: 'free',
      maxOwnedFolders: 1,
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'plan': plan,
    'maxOwnedFolders': maxOwnedFolders,
  };
}
