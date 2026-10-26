import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/storage/poster_blocks.dart';
import 'package:otogurashi/storage/project_database.dart';

void main() {
  late Directory root;
  late ProjectDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('otogurashi-blocks-');
    database = await ProjectDatabase.open(root);
  });

  tearDown(() async {
    database.close();
    await root.delete(recursive: true);
  });

  test('blocked people are kept across reopening, newest first', () async {
    final blocks = SqlitePosterBlocks(database);
    await blocks.block(const BlockedPoster(poster: 'p1', name: 'はる'));
    await blocks.block(const BlockedPoster(poster: 'p2', name: 'なつ'));
    // blocking again only updates the name
    await blocks.block(const BlockedPoster(poster: 'p1', name: 'はるか'));

    database.close();
    database = await ProjectDatabase.open(root);
    final reopened = SqlitePosterBlocks(database);
    expect(
      (await reopened.list()).map((person) => (person.poster, person.name)),
      [('p2', 'なつ'), ('p1', 'はるか')],
    );

    await reopened.unblock('p2');
    expect((await reopened.list()).single.poster, 'p1');
  });
}
