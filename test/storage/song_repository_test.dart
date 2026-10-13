import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/custom_song.dart';
import 'package:otogurashi/storage/project_database.dart';
import 'package:otogurashi/storage/song_repository.dart';

void main() {
  late Directory root;
  late ProjectDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('otogurashi-songs-');
    database = await ProjectDatabase.open(root);
  });

  tearDown(() async {
    database.close();
    await root.delete(recursive: true);
  });

  CustomSong song(String id, String title, {String? remoteId}) => CustomSong(
    id: id,
    title: title,
    credit: 'だれかの曲',
    remoteId: remoteId,
    author: remoteId == null ? null : 'はる',
    origin: remoteId == null ? SongOrigin.imported : SongOrigin.catalog,
    lanes: [
      [
        [0, 480, 60],
        [480, 480, 62],
      ],
      [
        [0, 960, 36],
      ],
    ],
  );

  test('songs are kept across reopening, newest first', () async {
    var songs = SqliteSongRepository(database);
    await songs.save(song('a', 'はじめの曲'));
    await songs.save(song('b', 'つぎの曲', remoteId: 'remote-1'));

    database.close();
    database = await ProjectDatabase.open(root);
    songs = SqliteSongRepository(database);
    final listed = await songs.list();
    expect(listed.map((s) => s.title), ['つぎの曲', 'はじめの曲']);
    expect(listed.first.origin, SongOrigin.catalog);
    expect(listed.first.remoteId, 'remote-1');
    expect(listed.first.author, 'はる');
    expect(listed.last.lanes, [
      [
        [0, 480, 60],
        [480, 480, 62],
      ],
      [
        [0, 960, 36],
      ],
      <List<int>>[],
    ]);
  });

  test('saving again replaces a song in place; deleting removes it', () async {
    final songs = SqliteSongRepository(database);
    await songs.save(song('a', 'はじめの曲'));
    await songs.save(song('b', 'つぎの曲'));
    await songs.save(song('a', '名前を変えた曲'));
    expect((await songs.list()).map((s) => s.title), ['つぎの曲', '名前を変えた曲']);

    await songs.delete('b');
    expect((await songs.list()).map((s) => s.id), ['a']);
  });

  test('a row that is not a song is left out of the list', () async {
    final songs = SqliteSongRepository(database);
    await songs.save(song('a', 'はじめの曲'));
    database.connection.execute(
      'INSERT INTO songs (id, data, created_at) VALUES (?, ?, ?)',
      <Object?>['broken', '{"id":"broken","title":"x","lanes":[]}', '2026-01-01'],
    );
    database.connection.execute(
      'INSERT INTO songs (id, data, created_at) VALUES (?, ?, ?)',
      <Object?>['garbage', 'not json', '2026-01-02'],
    );
    expect((await songs.list()).map((s) => s.id), ['a']);
  });

  test('names are trimmed and a song needs a melody to be read back', () {
    final long = CustomSong(
      id: 'x',
      title: '  ${'あ' * 60}  ',
      credit: 'い' * 90,
      lanes: const [
        [
          [0, 480, 60],
        ],
      ],
    );
    expect(long.title.runes, hasLength(CustomSong.maxTitleLength));
    expect(long.credit.runes, hasLength(CustomSong.maxCreditLength));
    expect(CustomSong(id: 'y', title: ' ', lanes: const []).title, 'よみこんだ曲');
    expect(CustomSong.tryFromJson(long.toJson())?.title, long.title);
    expect(
      CustomSong.tryFromJson({'id': 'z', 'title': 'x', 'lanes': <Object?>[]}),
      isNull,
    );
    expect(
      CustomSong.tryFromJson({
        'id': 'z',
        'title': 'x',
        'lanes': [
          [
            [0, 480, 'c'],
          ],
        ],
      }),
      isNull,
    );
    expect(CustomSong.tryFromJson('nope'), isNull);
  });
}
