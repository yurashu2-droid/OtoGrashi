import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/clip_asset.dart';
import 'package:otogurashi/domain/project.dart';
import 'package:otogurashi/features/home/folder_screen.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/folder_repository.dart';
import 'package:otogurashi/storage/project_database.dart';
import 'package:otogurashi/storage/project_repository.dart';

void main() {
  testWidgets('a sound that no song uses is deleted for good', (tester) async {
    final store = await _Store.open(tester);
    final trip = await store.folders.create('旅');
    final cup = await store.record(tester, 'コップ', trip);
    await store.record(tester, 'ドア', trip);
    await _openFolder(tester, store, trip);
    expect(find.textContaining('2個の音'), findsOneWidget);

    await _askToDelete(tester, 'コップ');
    expect(find.text('この音を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('削除する'));
    await _letFilesFinish(tester, until: find.text('削除する'));

    expect(find.text('コップ'), findsNothing);
    expect(find.text('ドア'), findsOneWidget);
    expect(find.textContaining('1個の音'), findsOneWidget);
    expect(await store.assets.load(cup.id), isNull);
    expect(cup.file.existsSync(), isFalse);
  });

  testWidgets('a sound that songs still use stays, and the screen says why', (
    tester,
  ) async {
    final store = await _Store.open(tester);
    final trip = await store.folders.create('旅');
    final cup = await store.record(tester, 'コップ', trip);
    final finished = await store.song([cup.id]);
    final draft = await store.song([cup.id]);
    await _openFolder(tester, store, trip);

    await _askToDelete(tester, 'コップ');
    expect(find.text('この音はまだ消せません'), findsOneWidget);
    expect(find.textContaining('2曲で使われています'), findsOneWidget);
    expect(find.textContaining('曲タブでその曲を削除すると'), findsOneWidget);
    expect(find.text('削除する'), findsNothing);
    expect((await store.folders.list()).single.assetIds, [cup.id]);
    expect(await store.assets.load(cup.id), isNotNull);
    expect(cup.file.existsSync(), isTrue);

    // one song fewer, and it says so
    await _closePanel(tester);
    expect(find.text('コップ'), findsOneWidget);
    await store.projects.deleteProject(finished.id);
    await _askToDelete(tester, 'コップ');
    expect(find.textContaining('1曲で使われています'), findsOneWidget);
    expect(find.text('削除する'), findsNothing);

    // with the last song gone it can be deleted after all
    await _closePanel(tester);
    await store.projects.deleteProject(draft.id);
    await _askToDelete(tester, 'コップ');
    expect(find.text('この音を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('削除する'));
    await _letFilesFinish(tester, until: find.text('削除する'));

    expect(find.text('コップ'), findsNothing);
    expect(await store.assets.load(cup.id), isNull);
    expect(cup.file.existsSync(), isFalse);
  });

  testWidgets('a song that takes the sound up at the last moment keeps it', (
    tester,
  ) async {
    final store = await _Store.open(tester);
    final friends = await store.folders.create('いつメン');
    final trip = await store.folders.create('旅');
    final cup = await store.record(tester, 'コップ', trip);
    await store.folders.addAsset(friends.id, cup.id);
    await _openFolder(tester, store, trip);

    await _askToDelete(tester, 'コップ');
    expect(find.text('この音を削除しますか？'), findsOneWidget);
    await store.song([cup.id]);
    await tester.tap(find.text('削除する'));
    await tester.pumpAndSettle();

    expect(find.text('この音はまだ消せません'), findsOneWidget);
    expect(find.textContaining('1曲で使われています'), findsOneWidget);
    expect(find.text('削除する'), findsNothing);
    // it was not taken out of any folder on the way
    expect(await store.soundsIn(trip), {cup.id});
    expect(await store.soundsIn(friends), {cup.id});
    expect(cup.file.existsSync(), isTrue);
  });

  testWidgets('a sound found to be in use is never left in no folder', (
    tester,
  ) async {
    final store = await _Store.open(tester);
    final trip = await store.folders.create('旅');
    final cup = await store.record(tester, 'コップ', trip);
    await _openFolder(tester, store, trip, assets: _LateSong(store));

    await _askToDelete(tester, 'コップ');
    await tester.tap(find.text('削除する'));
    await tester.pumpAndSettle();

    expect(find.text('この音はまだ消せません'), findsOneWidget);
    expect((await store.folders.list()).single.assetIds, [cup.id]);
    expect(await store.assets.load(cup.id), isNotNull);
    expect(cup.file.existsSync(), isTrue);
    await _closePanel(tester);
    expect(find.text('コップ'), findsOneWidget);
  });

  testWidgets('the sound lifted out of the list is drawn like the rest', (
    tester,
  ) async {
    final store = await _Store.open(tester);
    final trip = await store.folders.create('旅');
    await store.record(tester, 'コップ', trip);
    await _openFolder(tester, store, trip);

    await tester.longPress(find.text('コップ'));
    await tester.pumpAndSettle();

    // its row under the blur, and the copy lifted over it: neither may fall
    // back to the underlined style Flutter gives text outside a Material
    final names = find.text('コップ').evaluate();
    expect(names, hasLength(2));
    for (final name in names) {
      expect(
        DefaultTextStyle.of(name).style.decoration,
        isNot(TextDecoration.underline),
      );
    }
  });

  testWidgets('a folder waits for the sounds that songs still use', (
    tester,
  ) async {
    final store = await _Store.open(tester);
    final friends = await store.folders.create('いつメン');
    final trip = await store.folders.create('旅');
    final cup = await store.record(tester, 'コップ', trip);
    final door = await store.record(tester, 'ドア', trip);
    final wave = await store.record(tester, 'なみ', trip);
    await store.folders.addAsset(friends.id, wave.id);
    // なみ is in another folder as well, so only ドア holds this one back
    final song = await store.song([door.id, wave.id]);
    await _openFolder(tester, store, trip);

    await tester.tap(find.byTooltip('フォルダを削除'));
    await tester.pumpAndSettle();
    expect(find.text('このフォルダはまだ削除できません'), findsOneWidget);
    expect(find.textContaining('曲で使われている音が1個入っています'), findsOneWidget);
    expect(find.textContaining('ほかのフォルダへ移動するか'), findsOneWidget);
    expect(find.text('削除する'), findsNothing);
    await tester.tap(find.text('閉じる'));
    await tester.pumpAndSettle();

    expect(find.byType(FolderScreen), findsOneWidget);
    expect(await store.soundsIn(trip), {cup.id, door.id, wave.id});
    expect(cup.file.existsSync(), isTrue);

    // without the song the folder goes, with the sounds only it held
    await store.projects.deleteProject(song.id);
    await tester.tap(find.byTooltip('フォルダを削除'));
    await tester.pumpAndSettle();
    expect(find.text('「旅」を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('削除する'));
    await _letFilesFinish(tester, until: find.byType(FolderScreen));

    expect(find.text('ホーム'), findsOneWidget);
    final left = await store.folders.list();
    expect(left.map((folder) => folder.id), [friends.id]);
    expect(left.single.assetIds, [wave.id]);
    expect(await store.assets.load(cup.id), isNull);
    expect(await store.assets.load(door.id), isNull);
    expect(cup.file.existsSync(), isFalse);
    expect(door.file.existsSync(), isFalse);
    expect(wave.file.existsSync(), isTrue);
  });

  testWidgets('a folder is not deleted when one of its sounds cannot be', (
    tester,
  ) async {
    final store = await _Store.open(tester);
    final trip = await store.folders.create('旅');
    final cup = await store.record(tester, 'コップ', trip);
    await _openFolder(tester, store, trip, assets: _LateSong(store));

    await tester.tap(find.byTooltip('フォルダを削除'));
    await tester.pumpAndSettle();
    expect(find.text('「旅」を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('削除する'));
    await tester.pumpAndSettle();

    expect(find.text('このフォルダはまだ削除できません'), findsOneWidget);
    expect(find.byType(FolderScreen), findsOneWidget);
    expect(await store.soundsIn(trip), {cup.id});
    expect(cup.file.existsSync(), isTrue);
  });
}

/// Long-presses a sound and picks この音を削除 from its actions.
Future<void> _askToDelete(WidgetTester tester, String name) async {
  await tester.longPress(find.text(name));
  await tester.pumpAndSettle();
  await tester.tap(find.text('この音を削除'));
  await tester.pumpAndSettle();
}

Future<void> _closePanel(WidgetTester tester) async {
  await tester.tapAt(const Offset(5, 5));
  await tester.pumpAndSettle();
}

/// Deleting removes real files, which the fake clock of a widget test never
/// lets finish. This hands that work real time, a little at a time, until
/// [until] has left the screen.
Future<void> _letFilesFinish(
  WidgetTester tester, {
  required Finder until,
}) async {
  for (var i = 0; i < 400 && until.evaluate().isNotEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// Opens the folder from a page of its own, as Home does.
Future<void> _openFolder(
  WidgetTester tester,
  _Store store,
  SoundFolder folder, {
  AssetRepository? assets,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FolderScreen(
                    folder: folder,
                    folders: store.folders,
                    assets: assets ?? store.assets,
                    onCapture: (_) async {},
                    onMakeSong: (_) async {},
                  ),
                ),
              ),
              child: const Text('ホーム'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ホーム'));
  await tester.pumpAndSettle();
}

typedef _Sound = ({String id, File file});

/// The real storage, in a directory of its own.
final class _Store {
  _Store(this.root, this.database)
    : assets = SqliteAssetRepository(database, inspector: const _Inspector()),
      folders = SqliteFolderRepository(database),
      projects = SqliteProjectRepository(database);

  final Directory root;
  final ProjectDatabase database;
  final SqliteAssetRepository assets;
  final SqliteFolderRepository folders;
  final SqliteProjectRepository projects;

  static Future<_Store> open(WidgetTester tester) async {
    final store = (await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('otogurashi-folder-');
      return _Store(root, await ProjectDatabase.open(root));
    }))!;
    addTearDown(() async {
      store.database.close();
      if (await store.root.exists()) await store.root.delete(recursive: true);
    });
    return store;
  }

  /// A recording kept in [folder], with the file storage holds for it.
  Future<_Sound> record(
    WidgetTester tester,
    String name,
    SoundFolder folder,
  ) async => (await tester.runAsync(() async {
    final source = File('${root.path}/$name.mov');
    await source.writeAsBytes(utf8.encode(name));
    final sound = await assets.importFile(source.path);
    await folders.addAsset(folder.id, sound.id);
    return (id: sound.id, file: File(await assets.resolvePath(sound.id)));
  }))!;

  /// A song, finished or not, made with these sounds.
  Future<Project> song(List<String> soundIds) async {
    final created = await projects.create('きょうの曲');
    final song = created.copyWith(revision: 1, clipIds: soundIds);
    await projects.save(song, expectedRevision: 0);
    return song;
  }

  Future<Set<String>> soundsIn(SoundFolder folder) async =>
      (await folders.list())
          .singleWhere((listed) => listed.id == folder.id)
          .assetIds
          .toSet();
}

/// Storage in which a song takes a sound up at the very last moment, after
/// the screen has already seen that none uses it.
final class _LateSong implements AssetRepository {
  _LateSong(this.store);

  final _Store store;

  @override
  Future<void> deleteUnreferenced(String assetId) async {
    await store.song([assetId]);
    await store.assets.deleteUnreferenced(assetId);
  }

  @override
  Future<List<ClipAsset>> list() => store.assets.list();

  @override
  Future<ClipAsset?> load(String id) => store.assets.load(id);

  @override
  Future<List<String>> referencingProjectIds(String assetId) =>
      store.assets.referencingProjectIds(assetId);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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
