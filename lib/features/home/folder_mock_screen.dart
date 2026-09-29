import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import 'sound_row.dart';

/// Sample shared folders. Shared folders are not built yet; these show the
/// idea with fixed content.
final class FolderMock {
  const FolderMock({
    required this.title,
    required this.members,
    required this.tones,
    required this.sounds,
  });

  final String title;
  final int members;
  final List<Color> tones;
  final List<FolderMockSound> sounds;

  static const samples = [
    FolderMock(
      title: '沖縄旅行のオトグラシ',
      members: 4,
      tones: [
        Color(0xFF8FCFE0),
        Color(0xFFF6D28B),
        Color(0xFF9ED6B5),
        Color(0xFFF2B6A6),
      ],
      sounds: [
        FolderMockSound('波がよせる音', 'みお', 0),
        FolderMockSound('三線のひとふし', 'けんた', 1),
        FolderMockSound('サンダルで砂をける', 'あや', 2),
        FolderMockSound('シーサーの前で「わっ」', 'ゆう', 3),
        FolderMockSound('オリオンの缶をあける', 'けんた', 4),
        FolderMockSound('夜のカエル', 'みお', 5),
      ],
    ),
    FolderMock(
      title: 'いつメンのオトグラシ',
      members: 5,
      tones: [
        Color(0xFFC9B8F5),
        Color(0xFFF5B3CF),
        Color(0xFFB8D8F5),
        Color(0xFFF5DDB3),
      ],
      sounds: [
        FolderMockSound('ファミレスの呼び出しベル', 'はる', 0),
        FolderMockSound('せーのでハイタッチ', 'りく', 1),
        FolderMockSound('自販機のガコン', 'なな', 2),
        FolderMockSound('「え、まって」', 'そら', 3),
      ],
    ),
  ];
}

final class FolderMockSound {
  const FolderMockSound(this.label, this.by, this.colorIndex);
  final String label;
  final String by;
  final int colorIndex;
}

final class FolderMockScreen extends StatelessWidget {
  const FolderMockScreen({required this.folder, super.key});

  final FolderMock folder;

  void _soon(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('共有フォルダは、もうすぐ使えるようになります')),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(folder.title)),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppTokens.blushSoft,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            'サンプル · ${folder.members}人で共有 · ${folder.sounds.length}つの音',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppTokens.ink,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(AppTokens.tileRadius),
          ),
          child: Column(
            children: [
              for (var i = 0; i < folder.sounds.length; i++)
                SoundRow(
                  number: i + 1,
                  color: AppTokens.soundColor(folder.sounds[i].colorIndex),
                  label: folder.sounds[i].label,
                  caption: folder.sounds[i].by,
                  seconds: 0,
                  seed: folder.sounds[i].label.hashCode,
                ),
            ],
          ),
        ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _soon(context),
              icon: const Icon(Icons.mic_none_rounded),
              label: const Text('音を入れる'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: () => _soon(context),
              child: const Text('曲をつくる'),
            ),
          ),
        ],
      ),
    ),
  );
}
