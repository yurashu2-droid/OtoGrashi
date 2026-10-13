import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/design/tokens.dart';
import 'package:otogurashi/domain/custom_song.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/features/songs/midi_song_reader.dart';
import 'package:otogurashi/features/songs/song_library.dart';
import 'package:otogurashi/features/songs/songs_screen.dart';
import 'package:otogurashi/media/midi_file_picker.dart';
import 'package:otogurashi/sharing/song_catalog.dart';
import 'package:otogurashi/storage/song_repository.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    SongLibrary? library, {
    ValueChanged<CustomSong>? onSong,
    ValueChanged<MelodyTemplate>? onTemplate,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildOtogurashiTheme(),
        home: SongsScreen(
          mine: const SizedBox(),
          library: library,
          onMakeWithSong: onSong ?? (_) {},
          onMakeWithTemplate: onTemplate ?? (_) {},
        ),
      ),
    );
    await tester.tap(find.text('曲をえらぶ'));
    await tester.pumpAndSettle();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('without a library only the built-in songs are offered', (
    tester,
  ) async {
    MelodyTemplate? chosen;
    await open(tester, null, onTemplate: (melody) => chosen = melody);
    expect(find.text('みんなの曲'), findsNothing);
    expect(find.text('みんなが知ってる曲'), findsOneWidget);
    await tester.tap(find.text('きらきら星'));
    expect(chosen, MelodyTemplate.twinkle);
  });

  testWidgets('a posted song is fetched, kept and used with one tap', (
    tester,
  ) async {
    final songs = _MemorySongs();
    final catalog = _FakeCatalog()
      ..listed = [
        _listed('r1', 'ゆうがたのうた', author: 'はる', uses: 12),
        _listed('r2', 'あさのうた', author: 'みお'),
      ]
      ..mostUsed = [_listed('r2', 'あさのうた', author: 'みお', uses: 40)];
    final library = SongLibrary(songs: songs, catalog: catalog);
    addTearDown(library.dispose);
    CustomSong? made;
    await open(tester, library, onSong: (song) => made = song);

    expect(find.text('みんなの曲'), findsOneWidget);
    expect(find.text('はるさん · 12回つかわれた'), findsOneWidget);
    await tester.tap(find.text('人気'));
    await tester.pumpAndSettle();
    expect(find.text('ゆうがたのうた'), findsNothing);
    expect(find.text('みおさん · 40回つかわれた'), findsOneWidget);
    await tester.tap(find.text('新着'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ゆうがたのうた'));
    await tester.pumpAndSettle();
    expect(made?.title, 'ゆうがたのうた');
    expect(made?.origin, SongOrigin.catalog);
    expect(made?.remoteId, 'r1');
    expect(catalog.used, ['r1']);
    // it is on the phone now, so it works without the catalogue next time
    expect(songs.kept.single.id, 'catalog-r1');
    await reveal(tester, find.text('はるさんの投稿'));
  });

  testWidgets('a MIDI file is read, named, kept and used', (tester) async {
    final songs = _MemorySongs();
    final library = SongLibrary(
      songs: songs,
      catalog: _FakeCatalog()..serverReady = false,
      picker: _FakePicker(),
      reader: (file, id) => MidiSongReading.only(
        CustomSong(id: id, title: file.name, lanes: _notes),
      ),
    );
    addTearDown(library.dispose);
    CustomSong? made;
    await open(tester, library, onSong: (song) => made = song);

    // no server yet: the catalogue says so, and files still work
    expect(find.textContaining('まだ準備中です'), findsOneWidget);
    await reveal(tester, find.text('MIDIを読み込む'));
    await tester.tap(find.text('MIDIを読み込む'));
    await tester.pumpAndSettle();
    expect(find.text('この曲を追加'), findsOneWidget);
    expect(find.textContaining('メロディ 3音'), findsOneWidget);
    // posting is not offered while there is nowhere to post to
    expect(find.text('みんなに投稿する'), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'さんぽのうた');
    await tester.tap(find.text('この曲でつくる'));
    await tester.pumpAndSettle();

    expect(made?.title, 'さんぽのうた');
    expect(songs.kept.single.title, 'さんぽのうた');
    expect(songs.kept.single.origin, SongOrigin.imported);
    await reveal(tester, find.text('さんぽのうた'));
  });

  testWidgets('a file that is not a song says why', (tester) async {
    final library = SongLibrary(
      songs: _MemorySongs(),
      picker: _FakePicker(),
      reader: (_, _) => throw const MidiSongProblem('このMIDIには音が入っていません。'),
    );
    addTearDown(library.dispose);
    await open(tester, library);
    await reveal(tester, find.text('MIDIを読み込む'));
    await tester.tap(find.text('MIDIを読み込む'));
    await tester.pumpAndSettle();
    expect(find.text('このMIDIには音が入っていません。'), findsOneWidget);
    expect(find.text('この曲を追加'), findsNothing);
  });

  testWidgets('posting asks what the song is and logs in when needed', (
    tester,
  ) async {
    final songs = _MemorySongs()
      ..kept.add(CustomSong(id: 'mine', title: 'じぶんのうた', lanes: _notes));
    final catalog = _FakeCatalog()..loggedIn = false;
    var logins = 0;
    final library = SongLibrary(
      songs: songs,
      catalog: catalog,
      signIn: () async {
        logins++;
        catalog.loggedIn = true;
      },
    );
    addTearDown(library.dispose);
    await open(tester, library);

    await reveal(tester, find.byTooltip('じぶんのうたのメニュー'));
    await tester.tap(find.byTooltip('じぶんのうたのメニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('みんなに投稿する'));
    await tester.pumpAndSettle();

    // nothing can be posted before the person says what the song is
    final post = find.widgetWithText(FilledButton, '投稿する');
    expect(tester.widget<FilledButton>(post).onPressed, isNull);
    expect(find.textContaining('ほかの人が権利を持っている曲は投稿できません'), findsOneWidget);
    await tester.tap(find.text('自分でつくった曲'));
    await tester.pumpAndSettle();
    await tester.tap(post);
    await tester.pumpAndSettle();

    expect(logins, 1);
    expect(catalog.posted.single.$1.title, 'じぶんのうた');
    expect(catalog.posted.single.$2, SongRights.own);
    expect(find.text('「じぶんのうた」を投稿しました'), findsOneWidget);
  });

  testWidgets('a reported song leaves the list; a kept song can be removed', (
    tester,
  ) async {
    final songs = _MemorySongs()
      ..kept.add(CustomSong(id: 'mine', title: 'じぶんのうた', lanes: _notes));
    final catalog = _FakeCatalog()
      ..listed = [_listed('r1', 'ゆうがたのうた', author: 'はる')];
    final library = SongLibrary(songs: songs, catalog: catalog);
    addTearDown(library.dispose);
    await open(tester, library);

    await tester.tap(find.byTooltip('ゆうがたのうたのメニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('通報する'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ほかの人の曲が、そのまま投稿されている'));
    await tester.pumpAndSettle();
    expect(catalog.reported, [('r1', SongReportReason.rights)]);
    expect(find.text('ゆうがたのうた'), findsNothing);

    await reveal(tester, find.byTooltip('じぶんのうたのメニュー'));
    await tester.tap(find.byTooltip('じぶんのうたのメニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('この曲を消す'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('消す'));
    await tester.pumpAndSettle();
    expect(songs.kept, isEmpty);
    expect(find.text('じぶんのうた'), findsNothing);
  });

  testWidgets('a person can see their own posts and take one down', (
    tester,
  ) async {
    final catalog = _FakeCatalog()
      ..own = [
        _listed('p1', 'じぶんのうた', uses: 3),
        const CatalogSong(
          id: 'p2',
          title: 'みなおし中のうた',
          credit: '',
          author: '',
          uses: 0,
          status: 'hidden',
        ),
      ];
    final library = SongLibrary(songs: _MemorySongs(), catalog: catalog);
    addTearDown(library.dispose);
    await open(tester, library);

    await tester.tap(find.text('自分の投稿をみる'));
    await tester.pumpAndSettle();
    expect(find.text('3回つかわれた'), findsOneWidget);
    expect(find.text('通報があり、確認のため非公開になっています'), findsOneWidget);
    await tester.tap(find.text('取り下げる').first);
    await tester.pumpAndSettle();
    expect(catalog.removed, ['p1']);
    expect(find.text('「じぶんのうた」を取り下げました'), findsOneWidget);
  });

  test('more songs are added without repeats; trouble is told once', () async {
    final catalog = _FakeCatalog()
      ..listed = [_listed('r1', 'いち'), _listed('r2', 'に')]
      ..nextPage = [_listed('r2', 'に'), _listed('r3', 'さん')];
    final library = SongLibrary(songs: _MemorySongs(), catalog: catalog);
    addTearDown(library.dispose);
    await library.ensureLoaded();
    expect(library.catalogPhase, CatalogPhase.loaded);
    expect(library.hasMore, isTrue);
    await library.loadMore();
    expect(library.newest.map((song) => song.id), ['r1', 'r2', 'r3']);
    expect(library.hasMore, isFalse);

    catalog.failure = const SongCatalogException('通信できませんでした。', code: 'network');
    await library.refresh();
    expect(library.catalogPhase, CatalogPhase.failed);
    expect(library.catalogMessage, '通信できませんでした。');
  });
}

const _notes = [
  [
    [0, 480, 60],
    [480, 480, 62],
    [960, 960, 64],
  ],
];

CatalogSong _listed(
  String id,
  String title, {
  String author = '',
  int uses = 0,
}) => CatalogSong(id: id, title: title, credit: '', author: author, uses: uses);

final class _MemorySongs implements SongRepository {
  final kept = <CustomSong>[];

  @override
  Future<List<CustomSong>> list() async => kept.reversed.toList();

  @override
  Future<void> save(CustomSong song) async {
    kept
      ..removeWhere((other) => other.id == song.id)
      ..add(song);
  }

  @override
  Future<void> delete(String id) async =>
      kept.removeWhere((song) => song.id == id);
}

final class _FakePicker implements MidiFilePicker {
  @override
  Future<PickedMidiFile?> pick() async =>
      PickedMidiFile(name: 'walk', bytes: Uint8List.fromList([1, 2, 3]));
}

final class _FakeCatalog implements SongCatalog {
  var serverReady = true;
  var loggedIn = true;
  var listed = <CatalogSong>[];
  var mostUsed = <CatalogSong>[];
  List<CatalogSong>? nextPage;
  SongCatalogException? failure;
  final used = <String>[];
  final posted = <(CustomSong, SongRights)>[];
  final reported = <(String, SongReportReason)>[];
  var own = <CatalogSong>[];
  final removed = <String>[];

  void _needLogin() {
    if (!loggedIn) {
      throw const SongCatalogException('ログインが必要です。', code: 'login_required');
    }
  }

  @override
  Future<bool> available() async => serverReady;

  @override
  Future<({List<CatalogSong> songs, String? next})> newest({
    String? after,
  }) async {
    if (failure case final failure?) throw failure;
    if (after != null) return (songs: nextPage ?? const [], next: null);
    return (songs: listed, next: nextPage == null ? null : 'page-2');
  }

  @override
  Future<List<CatalogSong>> popular() async => mostUsed;

  @override
  Future<CustomSong> fetch(CatalogSong song) async => CustomSong(
    id: 'catalog-${song.id}',
    title: song.title,
    author: song.author,
    remoteId: song.id,
    origin: SongOrigin.catalog,
    lanes: _notes,
  );

  @override
  Future<void> countUse(String id) async => used.add(id);

  @override
  Future<CatalogSong> post(CustomSong song, SongRights rights) async {
    _needLogin();
    posted.add((song, rights));
    return _listed('posted', song.title);
  }

  @override
  Future<void> report(
    String id,
    SongReportReason reason, {
    String note = '',
  }) async {
    _needLogin();
    reported.add((id, reason));
  }

  @override
  Future<List<CatalogSong>> mine() async {
    _needLogin();
    return own;
  }

  @override
  Future<void> remove(String id) async {
    _needLogin();
    removed.add(id);
  }
}
