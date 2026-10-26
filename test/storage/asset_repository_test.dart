import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/project_database.dart';

void main() {
  late Directory root;
  late ProjectDatabase database;
  late SqliteAssetRepository assets;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('otogurashi-assets-');
    database = await ProjectDatabase.open(root);
    assets = SqliteAssetRepository(database, inspector: const _Inspector());
  });

  tearDown(() async {
    database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<String> importSound(String name) async {
    final file = File('${root.path}/$name.mov');
    await file.writeAsBytes(utf8.encode(name));
    return (await assets.importFile(file.path)).id;
  }

  test('the newest sounds come first, whatever they are called', () async {
    expect(await assets.listNewest(), isEmpty);
    // names that sort in another order than the sounds were added
    final first = await importSound('zz-cup');
    final second = await importSound('aa-door');
    final third = await importSound('mm-kettle');

    expect((await assets.list()).map((sound) => sound.id), [
      second,
      third,
      first,
    ]);
    expect((await assets.listNewest()).map((sound) => sound.id), [
      third,
      second,
      first,
    ]);
    expect((await assets.listNewest(limit: 2)).map((sound) => sound.id), [
      third,
      second,
    ]);
    expect(await assets.listNewest(limit: 0), isEmpty);

    // a new name does not make a sound any newer
    await assets.rename(first, 'あさのコップ');
    expect((await assets.listNewest(limit: 1)).single.id, third);
  });

  test('a recording is named after when it was taken, not its file', () async {
    final id = await importSound('ffffffff-0000-4000-8000-000000000001');
    final named = (await assets.list()).singleWhere((sound) => sound.id == id);
    expect(named.label, startsWith('録った音 '));
    expect(named.label, isNot(contains('ffffffff')));
    expect(
      SqliteAssetRepository.recordedLabel(DateTime(2026, 10, 27, 9, 5)),
      '録った音 10/27 09:05',
    );

    // one kept from before gets its name when storage opens again
    database.connection.execute(
      'UPDATE assets SET label = ? WHERE id = ?',
      ['ffffffff-0000-4000-8000-000000000001', id],
    );
    final reopened = SqliteAssetRepository(database, inspector: const _Inspector());
    final renamed = (await reopened.list()).singleWhere((sound) => sound.id == id);
    expect(renamed.label, startsWith('録った音 '));
  });

  test('the order survives deleting a sound and reopening storage', () async {
    final first = await importSound('first');
    final second = await importSound('second');
    final third = await importSound('third');
    await assets.deleteUnreferenced(third);
    final fourth = await importSound('fourth');
    database.close();

    database = await ProjectDatabase.open(root);
    assets = SqliteAssetRepository(database, inspector: const _Inspector());

    expect((await assets.listNewest()).map((sound) => sound.id), [
      fourth,
      second,
      first,
    ]);
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
