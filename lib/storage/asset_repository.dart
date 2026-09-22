import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/clip_asset.dart';
import 'project_database.dart';

/// Persists immutable shared originals and their import metadata.
///
/// Selection fields are import defaults. Per-project trim, gain, and later
/// selection edits belong to that project's versioned recipe, so this boundary
/// deliberately has no shared-global selection update method.
abstract interface class AssetRepository {
  Future<ClipAsset> importFile(String sourcePath);
  Future<ClipAsset?> load(String id);
  Future<List<ClipAsset>> list();
  Future<String> resolvePath(String assetId);
  Future<List<String>> referencingProjectIds(String assetId);
  Future<void> deleteUnreferenced(String assetId);
}

abstract interface class AssetInspector {
  Future<InspectedAsset> inspect(String path);
}

final class InspectedAsset {
  const InspectedAsset({
    required this.durationUs,
    required this.width,
    required this.height,
    required this.rotation,
  });

  final int durationUs;
  final int width;
  final int height;
  final int rotation;
}

final class RejectingAssetInspector implements AssetInspector {
  const RejectingAssetInspector();

  @override
  Future<InspectedAsset> inspect(String path) {
    throw const AssetInspectionUnavailable(
      'A native media inspector must validate imports.',
    );
  }
}

final class SqliteAssetRepository implements AssetRepository {
  SqliteAssetRepository(
    this._database, {
    this._inspector = const RejectingAssetInspector(),
  });

  final ProjectDatabase _database;
  final AssetInspector _inspector;

  @override
  Future<ClipAsset> importFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw InvalidAsset('Source file does not exist: $sourcePath');
    }
    final id = _newUuid();
    final extension = _safeExtension(sourcePath);
    final relativePath = 'originals/$id$extension';
    final staged = File(
      p.join(_database.stagingDirectory.path, '$id.partial$extension'),
    );
    final destination = _resolveRelative(relativePath);
    var committed = false;
    try {
      await source.copy(staged.path);
      final inspection = await _inspector.inspect(staged.path);
      _validateInspection(inspection);
      final digest = await sha256.bind(staged.openRead()).first;
      final sourceLength = await source.length();
      if (await staged.length() != sourceLength) {
        throw const InvalidAsset('The managed copy is incomplete.');
      }
      await staged.rename(destination.path);
      final asset = ClipAsset(
        id: id,
        relativePath: relativePath,
        durationUs: inspection.durationUs,
        selectionStartUs: 0,
        selectionDurationUs: min(inspection.durationUs, 6000000),
        width: inspection.width,
        height: inspection.height,
        rotation: inspection.rotation,
        sha256: digest.toString(),
        label: p.basenameWithoutExtension(sourcePath),
      );
      _database.transaction(() {
        _database.connection.execute(
          '''
          INSERT INTO assets (
            id, relative_path, duration_us, selection_start_us,
            selection_duration_us, width, height, rotation, sha256, label
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          <Object?>[
            asset.id,
            asset.relativePath,
            asset.durationUs,
            asset.selectionStartUs,
            asset.selectionDurationUs,
            asset.width,
            asset.height,
            asset.rotation,
            asset.sha256,
            asset.label,
          ],
        );
      });
      committed = true;
      return asset;
    } finally {
      if (await staged.exists()) {
        await staged.delete();
      }
      if (!committed && await destination.exists()) {
        await destination.delete();
      }
    }
  }

  @override
  Future<ClipAsset?> load(String id) async {
    final rows = _database.connection.select(
      'SELECT * FROM assets WHERE id = ?',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _decodeAsset(rows.single);
  }

  @override
  Future<List<ClipAsset>> list() async {
    return _database.connection
        .select('SELECT * FROM assets ORDER BY label COLLATE NOCASE, id')
        .map(_decodeAsset)
        .toList(growable: false);
  }

  @override
  Future<String> resolvePath(String assetId) async {
    final rows = _database.connection.select(
      'SELECT relative_path FROM assets WHERE id = ?',
      <Object?>[assetId],
    );
    if (rows.isEmpty) {
      throw AssetNotFound(assetId);
    }
    final file = _resolveRelative(rows.single['relative_path'] as String);
    if (!await file.exists()) {
      throw AssetFileMissing(assetId);
    }
    return file.path;
  }

  @override
  Future<List<String>> referencingProjectIds(String assetId) async {
    return _database.connection
        .select(
          '''
          SELECT project_id FROM project_assets
          WHERE asset_id = ? ORDER BY project_id
          ''',
          <Object?>[assetId],
        )
        .map((row) => row['project_id'] as String)
        .toList(growable: false);
  }

  @override
  Future<void> deleteUnreferenced(String assetId) async {
    String? relativePath;
    _database.transaction(() {
      final rows = _database.connection.select(
        '''
        SELECT relative_path FROM assets
        WHERE id = ? AND NOT EXISTS (
          SELECT 1 FROM project_assets WHERE asset_id = ?
        )
        ''',
        <Object?>[assetId, assetId],
      );
      if (rows.isEmpty) {
        return;
      }
      relativePath = rows.single['relative_path'] as String;
      _database.connection.execute(
        '''
        DELETE FROM assets
        WHERE id = ? AND NOT EXISTS (
          SELECT 1 FROM project_assets WHERE asset_id = ?
        )
        ''',
        <Object?>[assetId, assetId],
      );
    });
    if (relativePath != null) {
      final file = _resolveRelative(relativePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  File _resolveRelative(String relativePath) {
    if (p.url.isAbsolute(relativePath) || relativePath.contains('\\')) {
      throw InvalidAsset('Unsafe managed path: $relativePath');
    }
    final resolved = p.normalize(
      p.joinAll(<String>[
        _database.rootDirectory.path,
        ...p.url.split(relativePath),
      ]),
    );
    if (!p.isWithin(_database.rootDirectory.path, resolved)) {
      throw InvalidAsset('Unsafe managed path: $relativePath');
    }
    return File(resolved);
  }
}

ClipAsset _decodeAsset(Map<String, Object?> row) {
  return ClipAsset(
    id: row['id'] as String,
    relativePath: row['relative_path'] as String,
    durationUs: row['duration_us'] as int,
    selectionStartUs: row['selection_start_us'] as int,
    selectionDurationUs: row['selection_duration_us'] as int,
    width: row['width'] as int,
    height: row['height'] as int,
    rotation: row['rotation'] as int,
    sha256: row['sha256'] as String,
    label: row['label'] as String,
  );
}

String _safeExtension(String sourcePath) {
  final extension = p.extension(sourcePath).toLowerCase();
  if (RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension)) {
    return extension;
  }
  return '.media';
}

void _validateInspection(InspectedAsset inspection) {
  if (inspection.durationUs <= 0 ||
      inspection.width <= 0 ||
      inspection.height <= 0 ||
      !const <int>{0, 90, 180, 270}.contains(inspection.rotation)) {
    throw const InvalidAsset('Media metadata is invalid.');
  }
}

String _newUuid() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class InvalidAsset implements Exception {
  const InvalidAsset(this.message);
  final String message;

  @override
  String toString() => 'InvalidAsset: $message';
}

final class AssetInspectionUnavailable extends InvalidAsset {
  const AssetInspectionUnavailable(super.message);
}

final class AssetNotFound implements Exception {
  const AssetNotFound(this.assetId);
  final String assetId;
}

final class AssetFileMissing implements Exception {
  const AssetFileMissing(this.assetId);
  final String assetId;
}
