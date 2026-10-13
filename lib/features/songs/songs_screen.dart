import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/melody_template.dart';

/// The 曲 tab: your own songs (the real library), the way into the folders
/// shared with friends, and the songs a new piece can be made with.
final class SongsScreen extends StatefulWidget {
  const SongsScreen({
    required this.mine,
    this.onSettings,
    this.onMakeWithTemplate,
    this.onOpenSharedFolders,
    this.selectedMelody,
    super.key,
  });

  final Widget mine;
  final VoidCallback? onSettings;

  /// "この曲でつくる": the song is chosen before the sounds are.
  final ValueChanged<MelodyTemplate>? onMakeWithTemplate;
  final VoidCallback? onOpenSharedFolders;

  /// The song the piece in progress is set to, if there is one.
  final MelodyTemplate? selectedMelody;

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  static const _segments = ['じぶん', '友達', '曲をえらぶ'];
  var _segment = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '曲',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppTokens.ink,
                    ),
                  ),
                ),
                if (widget.onSettings != null)
                  IconButton(
                    onPressed: widget.onSettings,
                    tooltip: '設定',
                    icon: const Icon(Icons.settings_outlined),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: _Segmented(
              labels: _segments,
              selected: _segment,
              onSelected: (value) => setState(() => _segment = value),
            ),
          ),
          Expanded(
            child: switch (_segment) {
              0 => widget.mine,
              1 => _FriendsEntry(onOpen: widget.onOpenSharedFolders),
              _ => _SongChoices(
                onMake: widget.onMakeWithTemplate,
                selected: widget.selectedMelody,
              ),
            },
          ),
        ],
      ),
    ),
  );
}

final class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    height: 44,
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: AppTokens.tile,
      borderRadius: BorderRadius.circular(999),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / labels.length;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 380),
              curve: const Cubic(0.3, 1.45, 0.5, 1),
              left: width * selected,
              top: 0,
              bottom: 0,
              width: width,
              child: Container(
                decoration: BoxDecoration(
                  color: AppTokens.ink,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: i == selected,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelected(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: i == selected
                                  ? Colors.white
                                  : AppTokens.mutedInk,
                            ),
                            child: Text(labels[i]),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    ),
  );
}

/// 友達: sounds are shared through folders, so this leads to them.
final class _FriendsEntry extends StatelessWidget {
  const _FriendsEntry({required this.onOpen});

  final VoidCallback? onOpen;

  static const _steps = [
    (Icons.create_new_folder_outlined, '共有フォルダをつくる'),
    (Icons.link_rounded, '招待リンクを友だちに送る'),
    (Icons.graphic_eq_rounded, '集まった音で、1曲つくる'),
  ];

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
    children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTokens.blushSoft,
          borderRadius: BorderRadius.circular(AppTokens.tileRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '友だちの音も、\nひとつの曲に。',
              style: TextStyle(
                fontSize: 22,
                height: 1.25,
                fontWeight: FontWeight.w800,
                color: AppTokens.ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '「みんなの音」は、招待した友だちだけが入れる共有フォルダです。',
              style: TextStyle(color: AppTokens.ink, height: 1.5),
            ),
            const SizedBox(height: 16),
            for (final (icon, text) in _steps)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: AppTokens.ink),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        text,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTokens.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            FilledButton(
              onPressed: onOpen,
              child: const Text('みんなの音をひらく'),
            ),
            if (onOpen == null) ...[
              const SizedBox(height: 8),
              const Text(
                '共有フォルダは、いまは使えません。',
                style: TextStyle(fontSize: 12, color: AppTokens.mutedInk),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

/// Every song the app can play; one tap makes a piece with it.
final class _SongChoices extends StatelessWidget {
  const _SongChoices({required this.onMake, required this.selected});

  final ValueChanged<MelodyTemplate>? onMake;
  final MelodyTemplate? selected;

  @override
  Widget build(BuildContext context) {
    final make = onMake;
    final known = [
      for (final melody in melodyChoices)
        if (melody.scoreId != null) melody,
    ];
    final patterns = [
      for (final melody in melodyChoices)
        if (melody.scoreId == null) melody,
    ];
    Widget row(MelodyTemplate melody, int index) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _SongRow(
        melody: melody,
        color: AppTokens.soundColor(index),
        current: melody == selected,
        onMake: make == null ? null : () => make(melody),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        const Text(
          '曲をえらぶと、撮った音がその曲を演奏します。',
          style: TextStyle(fontSize: 12, color: AppTokens.mutedInk),
        ),
        const SizedBox(height: 14),
        const _GroupLabel('みんなが知ってる曲'),
        const SizedBox(height: 10),
        for (final (index, melody) in known.indexed) row(melody, index),
        const SizedBox(height: 12),
        const _GroupLabel('オトグラシのパターン'),
        const SizedBox(height: 10),
        for (final (index, melody) in patterns.indexed)
          row(melody, known.length + index),
      ],
    );
  }
}

final class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w800,
      color: AppTokens.ink,
    ),
  );
}

final class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.melody,
    required this.color,
    required this.current,
    required this.onMake,
  });

  final MelodyTemplate melody;
  final Color color;
  final bool current;
  final VoidCallback? onMake;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onMake != null,
    label: '${melody.label}でつくる',
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onMake,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const Icon(
                  Icons.music_note_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            melody.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: AppTokens.ink,
                            ),
                          ),
                        ),
                        if (current) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTokens.blushSoft,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'いまの曲',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: AppTokens.ink,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      melody.description,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.35,
                        color: AppTokens.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: onMake == null ? AppTokens.tile : AppTokens.ink,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'つくる',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: onMake == null ? AppTokens.mutedInk : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
