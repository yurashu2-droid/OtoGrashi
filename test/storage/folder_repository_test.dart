import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/folder_repository.dart';
import 'package:otogurashi/storage/project_database.dart';

void main() {
  late Directory root;
  late ProjectDatabase database;
  late SqliteAssetRepository assets;
  late SqliteFolderRepository folders;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('otogurashi-folders-');
    database = await ProjectDatabase.open(root);
    assets = SqliteAssetRepository(database, inspector: const _Inspector());
    folders = SqliteFolderRepository(database);
  });

  tearDown(() async {
    database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<String> importSound(String name) async {
    final file = File('${root.path}/$name.mov');
    await file.writeAsBytes([name.length, 1, 2, 3]);
    return (await assets.importFile(file.path)).id;
  }

  test('no sounds means no folders; existing sounds get a starter folder', () async {
    expect(await folders.list(), isEmpty);
    final first = await importSound('cup');
    final second = await importSound('door');

    final listed = await folders.list();
    expect(listed, hasLength(1));
    expect(listed.single.title, SqliteFolderRepository.starterTitle);
    expect(listed.single.assetIds.toSet(), {first, second});
    // the starter is made once
    expect(await folders.list(), hasLength(1));
  });

  test('folders hold any number of sounds, newest first', () async {
    final trip = await folders.create('  沖縄旅行のオトグラシ  ');
    expect(trip.title, '沖縄旅行のオトグラシ');
    final ids = <String>[];
    for (var i = 0; i < 8; i++) {
      final id = await importSound('s$i');
      ids.add(id);
      await folders.addAsset(trip.id, id);
    }
    await folders.addAsset(trip.id, ids.first); // already there
    final listed = (await folders.list()).singleWhere((f) => f.id == trip.id);
    expect(listed.assetIds, ids.reversed.toList());

    await folders.rename(trip.id, 'いつメンのオトグラシ');
    await folders.removeAsset(trip.id, ids.last);
    final renamed = (await folders.list()).singleWhere((f) => f.id == trip.id);
    expect(renamed.title, 'いつメンのオトグラシ');
    expect(renamed.assetIds, hasLength(7));
  });

  test('a sound kept in a folder is not deleted as unreferenced', () async {
    final folder = await folders.create('残す');
    final kept = await importSound('kept');
    final loose = await importSound('loose');
    await folders.addAsset(folder.id, kept);

    await assets.deleteUnreferenced(kept);
    await assets.deleteUnreferenced(loose);

    expect(await assets.load(kept), isNotNull);
    expect(await assets.load(loose), isNull);
    await folders.delete(folder.id);
    expect((await folders.list()).where((f) => f.id == folder.id), isEmpty);
  });
}

final class _Inspector implements AssetInspector {
  const _Inspector();

  @override
  Future<InspectedAsset> inspect(String path) async => const InspectedAsset(
    durationUs: 3000000,
    audioTrackStartUs: 0,
    width: 1080,
    height: 1920,
    rotation: 0,
  );
}
