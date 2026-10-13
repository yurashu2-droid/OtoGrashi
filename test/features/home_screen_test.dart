import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/clip_asset.dart';
import 'package:otogurashi/features/home/home_screen.dart';
import 'package:otogurashi/features/home/sound_player_screen.dart';
import 'package:otogurashi/media/media_presentation_gateway.dart';
import 'package:otogurashi/storage/asset_repository.dart';
import 'package:otogurashi/storage/folder_repository.dart';

void main() {
  testWidgets('さいきんの音 shows the eight newest sounds, newest first', (
    tester,
  ) async {
    _usePhone(tester);
    // "音 10" was recorded last; by name it would sit between 1 and 2
    final sounds = _Sounds([
      for (var number = 10; number >= 1; number--)
        _sound('sound-$number', '音 $number'),
    ]);
    await tester.pumpWidget(_home(sounds: sounds));
    await tester.pumpAndSettle();

    expect(sounds.limits, [8]);
    final tops = [
      for (var number = 10; number >= 3; number--)
        tester.getTopLeft(find.text('音 $number')).dy,
    ];
    expect(tops, [...tops]..sort());
    expect(tops.toSet(), hasLength(8));
    expect(find.text('音 2'), findsNothing);
    expect(find.text('音 1'), findsNothing);
  });

  testWidgets('a recent sound plays when tapped; ＋ still adds it', (
    tester,
  ) async {
    _usePhone(tester);
    final added = <ClipAsset>[];
    await tester.pumpWidget(
      _home(
        sounds: _Sounds([_sound('cup', 'コップ'), _sound('door', 'ドア')]),
        presentation: _Presentation(),
        onAssetSelected: added.add,
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getSemantics(find.text('コップ'));
    expect(row.label, contains('コップを再生'));
    expect(row.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(find.text('コップ'));
    await tester.pumpAndSettle();
    final player = tester.widget<SoundPlayerScreen>(
      find.byType(SoundPlayerScreen),
    );
    expect(player.asset.id, 'cup');
    expect(player.title, 'コップ');
    expect(added, isEmpty);
    await tester.tap(find.byTooltip('閉じる'));
    await tester.pumpAndSettle();
    expect(find.byType(SoundPlayerScreen), findsNothing);

    final add = find.ancestor(
      of: find.byTooltip('つくりかけの曲に入れる').first,
      matching: find.byType(IconButton),
    );
    expect(tester.getSize(add).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(add).height, greaterThanOrEqualTo(44));
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(added.single.id, 'cup');
    expect(find.byType(SoundPlayerScreen), findsNothing);
  });

  testWidgets('without a player a recent sound is not a button', (
    tester,
  ) async {
    _usePhone(tester);
    await tester.pumpWidget(_home(sounds: _Sounds([_sound('cup', 'コップ')])));
    await tester.pumpAndSettle();

    expect(tester.getSemantics(find.text('コップ')).label, isNot(contains('再生')));
    await tester.tap(find.text('コップ'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(SoundPlayerScreen), findsNothing);
  });

  testWidgets('the header makes a folder when the card is off screen', (
    tester,
  ) async {
    _usePhone(tester);
    final folders = _Folders([
      _folder('旅のオトグラシ', 12),
      _folder('いつメンのオトグラシ', 1),
    ]);
    await tester.pumpWidget(_home(sounds: _Sounds(const []), folders: folders));
    await tester.pumpAndSettle();

    expect(find.text('12個の音'), findsOneWidget);
    expect(find.text('1個の音'), findsOneWidget);
    expect(find.text('12の音'), findsNothing);
    // two folders push the card that makes one past the edge of the phone
    expect(find.text('フォルダを\nつくる'), findsNothing);
    expect(find.text('フォルダを\nつくる', skipOffstage: false), findsOneWidget);

    final make = find.ancestor(
      of: find.byTooltip('フォルダをつくる'),
      matching: find.byType(IconButton),
    );
    expect(tester.getRect(make).right, lessThanOrEqualTo(390));
    expect(tester.getSize(make).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(make).height, greaterThanOrEqualTo(44));
    await tester.tap(make);
    await tester.pumpAndSettle();
    expect(find.text('新しいフォルダ'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '海のオトグラシ');
    await tester.tap(find.text('つくる'));
    await tester.pumpAndSettle();

    expect(folders.created, ['海のオトグラシ']);
    expect(find.text('海のオトグラシ'), findsOneWidget);
    expect(find.text('0個の音'), findsOneWidget);
  });

  testWidgets('coming back from a folder shows what changed in it', (
    tester,
  ) async {
    _usePhone(tester);
    final folders = _Folders([_folder('旅のオトグラシ', 3)]);
    await tester.pumpWidget(
      _home(
        sounds: _Sounds(const []),
        folders: folders,
        // a sound is deleted while the folder is open
        onOpenFolder: (folder) async =>
            folders.folders[0] = _folder(folder.title, 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3個の音'), findsOneWidget);

    await tester.tap(find.text('旅のオトグラシ'));
    await tester.pumpAndSettle();

    expect(find.text('2個の音'), findsOneWidget);
    expect(find.text('3個の音'), findsNothing);
  });

  testWidgets('the song in progress says how many of its six sounds it has', (
    tester,
  ) async {
    _usePhone(tester);
    final clips = [_sound('cup', 'コップ'), _sound('door', 'ドア')];
    await tester.pumpWidget(_home(sounds: _Sounds(clips), currentClips: clips));
    await tester.pumpAndSettle();

    expect(find.text('音 2/6'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('音 2/6')).label,
      contains('つくりかけの曲 音 2/6'),
    );
    expect(find.textContaining('つの音'), findsNothing);
  });
}

/// A phone in portrait, tall enough to show the whole page without scrolling.
void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _home({
  required _Sounds sounds,
  _Folders? folders,
  MediaPresentationGateway? presentation,
  List<ClipAsset> currentClips = const [],
  ValueChanged<ClipAsset>? onAssetSelected,
  Future<void> Function(SoundFolder folder)? onOpenFolder,
}) => MaterialApp(
  home: HomeScreen(
    currentClips: currentClips,
    thumbnails: const <String, Uint8List>{},
    assets: sounds,
    folders: folders,
    presentation: presentation,
    onOpenCurrent: () {},
    onAssetSelected: onAssetSelected,
    onOpenFolder: onOpenFolder,
  ),
);

ClipAsset _sound(String id, String label) => ClipAsset(
  id: id,
  relativePath: 'originals/$id.mov',
  durationUs: 3000000,
  selectionStartUs: 0,
  selectionDurationUs: 3000000,
  width: 1080,
  height: 1920,
  rotation: 0,
  sha256: id,
  label: label,
);

SoundFolder _folder(String title, int sounds) => SoundFolder(
  id: title,
  title: title,
  createdAt: DateTime.utc(2026, 10, 14),
  assetIds: [for (var i = 0; i < sounds; i++) '$title-$i'],
);

/// Sounds in the order they were recorded, the newest first; [list] answers
/// by name as the real store does.
final class _Sounds implements AssetRepository {
  _Sounds(this.newestFirst);

  final List<ClipAsset> newestFirst;
  final limits = <int?>[];

  @override
  Future<List<ClipAsset>> list() async =>
      [...newestFirst]..sort((a, b) => a.label.compareTo(b.label));

  @override
  Future<List<ClipAsset>> listNewest({int? limit}) async {
    limits.add(limit);
    return newestFirst.take(limit ?? newestFirst.length).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Folders implements FolderRepository {
  _Folders(this.folders);

  final List<SoundFolder> folders;
  final created = <String>[];

  @override
  Future<List<SoundFolder>> list() async => [...folders];

  @override
  Future<SoundFolder> create(String title) async {
    created.add(title);
    final folder = _folder(title, 0);
    folders.insert(0, folder);
    return folder;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

final class _Presentation implements MediaPresentationGateway {
  @override
  Future<Uint8List> thumbnail(String relativePath) async =>
      throw StateError('No picture in this fixture.');

  @override
  Future<AudioWaveform> waveform(String relativePath) async =>
      AudioWaveform(durationUs: 3000000, levels: const [.2, .8, .4]);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
