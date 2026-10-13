import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/custom_song.dart';
import '../../domain/melody_template.dart';
import '../../sharing/song_catalog.dart';

/// What the person decided about a MIDI file that was just read.
typedef SongImportChoice = ({String title, String credit, bool post});

/// Shows what was read from a MIDI file and asks for its name. Null when the
/// person backs out; `post` when they want to go on and post it.
Future<SongImportChoice?> showSongImportSheet(
  BuildContext context,
  CustomSong song, {
  required bool canPost,
}) => showModalBottomSheet<SongImportChoice>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _ImportSheet(song: song, canPost: canPost),
);

final class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.song, required this.canPost});

  final CustomSong song;
  final bool canPost;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

final class _ImportSheetState extends State<_ImportSheet> {
  late final _title = TextEditingController(text: widget.song.title);
  late final _credit = TextEditingController(text: widget.song.credit);

  @override
  void dispose() {
    _title.dispose();
    _credit.dispose();
    super.dispose();
  }

  void _done({required bool post}) => Navigator.pop<SongImportChoice>(
    context,
    (title: _title.text, credit: _credit.text, post: post),
  );

  @override
  Widget build(BuildContext context) {
    final lanes = widget.song.lanes;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('この曲を追加', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'はじめの8小節を使います。'
              'メロディ ${lanes[0].length}音'
              '${lanes[1].isEmpty ? '' : ' · ベース ${lanes[1].length}音'}'
              '${lanes[2].isEmpty ? '' : ' · コード ${lanes[2].length}音'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _ScorePicture(lanes: lanes),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              maxLength: CustomSong.maxTitleLength,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: '曲の名前'),
            ),
            TextField(
              controller: _credit,
              maxLength: CustomSong.maxCreditLength,
              decoration: const InputDecoration(
                labelText: 'つくった人・もとの曲（なくてもOK）',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => _done(post: false),
              child: const Text('この曲でつくる'),
            ),
            if (widget.canPost) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => _done(post: true),
                child: const Text('みんなに投稿する'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The score at a glance: time runs left to right, higher notes sit higher,
/// one colour per part. It lets the person see that the right tune was read.
final class _ScorePicture extends StatelessWidget {
  const _ScorePicture({required this.lanes});

  final List<List<List<int>>> lanes;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '読み込んだ曲の音の並び',
    child: Container(
      height: 96,
      decoration: BoxDecoration(
        color: AppTokens.tile,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ScorePainter(lanes),
      ),
    ),
  );
}

final class _ScorePainter extends CustomPainter {
  const _ScorePainter(this.lanes);

  final List<List<List<int>>> lanes;

  @override
  void paint(Canvas canvas, Size size) {
    var low = 127, high = 0;
    for (final lane in lanes) {
      for (final note in lane) {
        if (note[2] < low) low = note[2];
        if (note[2] > high) high = note[2];
      }
    }
    if (high < low) return;
    final span = (high - low).clamp(12, 127);
    const inset = 8.0;
    final row = (size.height - inset * 2) / (span + 1);
    // chords and bass first, so the melody stays on top
    for (final lane in const [2, 1, 0]) {
      final paint = Paint()..color = AppTokens.soundColor(lane == 0 ? 0 : lane + 2);
      for (final note in lanes[lane]) {
        final left = inset + note[0] / scoreTicks * (size.width - inset * 2);
        final width = (note[1] / scoreTicks * (size.width - inset * 2)).clamp(
          2.0,
          size.width,
        );
        final top = size.height - inset - (note[2] - low + 1) * row;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, top, width - 1, row.clamp(2.0, 6.0)),
            const Radius.circular(2),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ScorePainter oldDelegate) => oldDelegate.lanes != lanes;
}

/// Asks what the person may post, and only lets them go on once they say the
/// song is their own or old enough to be free. Null when they back out.
Future<SongRights?> showSongPostSheet(BuildContext context, CustomSong song) =>
    showModalBottomSheet<SongRights>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PostSheet(song: song),
    );

final class _PostSheet extends StatefulWidget {
  const _PostSheet({required this.song});

  final CustomSong song;

  @override
  State<_PostSheet> createState() => _PostSheetState();
}

final class _PostSheetState extends State<_PostSheet> {
  SongRights? _rights;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('みんなに投稿する', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            '「${widget.song.title}」を、だれでも自分の音で演奏できるようにします。',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          const Text(
            'この曲は、どちらですか？',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          _RightsChoice(
            title: '自分でつくった曲',
            caption: 'メロディを自分で考えた曲です',
            selected: _rights == SongRights.own,
            onTap: () => setState(() => _rights = SongRights.own),
          ),
          const SizedBox(height: 8),
          _RightsChoice(
            title: '著作権の切れた曲',
            caption: 'クラシックや古い民謡など、つくった人が亡くなって70年以上たつ曲です',
            selected: _rights == SongRights.publicDomain,
            onTap: () => setState(() => _rights = SongRights.publicDomain),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTokens.blushSoft,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text(
              '市販の曲や、アニメ・ゲーム・ボカロの曲など、ほかの人が権利を持っている曲は投稿できません。'
              '見つかったときは削除されます。',
              style: TextStyle(fontSize: 13, height: 1.5, color: AppTokens.ink),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _rights == null
                ? null
                : () => Navigator.pop(context, _rights),
            child: const Text('投稿する'),
          ),
        ],
      ),
    ),
  );
}

final class _RightsChoice extends StatelessWidget {
  const _RightsChoice({
    required this.title,
    required this.caption,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String caption;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? AppTokens.ink : AppTokens.hairline,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected ? AppTokens.ink : AppTokens.mutedInk,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppTokens.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      caption,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: AppTokens.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Why a posted song should be looked at. Null when the person backs out.
Future<SongReportReason?> showSongReportDialog(
  BuildContext context,
  CatalogSong song,
) => showDialog<SongReportReason>(
  context: context,
  builder: (dialogContext) => SimpleDialog(
    title: Text('「${song.title}」を通報'),
    children: [
      for (final (reason, label) in const [
        (SongReportReason.rights, 'ほかの人の曲が、そのまま投稿されている'),
        (SongReportReason.inappropriate, '名前や内容が不適切'),
        (SongReportReason.other, 'そのほか'),
      ])
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, reason),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          child: Text(label),
        ),
      SimpleDialogOption(
        onPressed: () => Navigator.pop(dialogContext),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: const Text(
          'やめる',
          style: TextStyle(color: AppTokens.mutedInk),
        ),
      ),
    ],
  ),
);
