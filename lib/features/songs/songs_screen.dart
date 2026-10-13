import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/custom_song.dart';
import '../../domain/melody_template.dart';
import '../../sharing/song_catalog.dart';
import 'song_library.dart';
import 'song_sheets.dart';

/// The 曲 tab: your own songs (the real library), the way into the folders
/// shared with friends, and the songs a new piece can be made with.
final class SongsScreen extends StatefulWidget {
  const SongsScreen({
    required this.mine,
    this.onSettings,
    this.onMakeWithTemplate,
    this.onOpenSharedFolders,
    this.selectedMelody,
    this.library,
    this.onMakeWithSong,
    super.key,
  });

  final Widget mine;
  final VoidCallback? onSettings;

  /// "この曲でつくる": the song is chosen before the sounds are.
  final ValueChanged<MelodyTemplate>? onMakeWithTemplate;
  final VoidCallback? onOpenSharedFolders;

  /// The song the piece in progress is set to, if there is one.
  final MelodyTemplate? selectedMelody;

  /// The songs from outside the app: posted by everyone, or on this phone.
  final SongLibrary? library;

  /// "この曲でつくる" for one of those.
  final ValueChanged<CustomSong>? onMakeWithSong;

  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  static const _segments = ['じぶん', '友だち', '曲をえらぶ'];
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
                library: widget.library,
                onMakeWithSong: widget.onMakeWithSong,
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
    // 44pt to touch inside the 4pt rim
    height: 52,
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
                            // large text shrinks rather than wrapping
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                ),
                                child: Text(labels[i], maxLines: 1),
                              ),
                            ),
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

/// 友だち: sounds are shared through folders, so this leads to them.
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

/// Every song a piece can be made with: the ones everyone has posted, the
/// ones on this phone, and the ones built into the app. One tap makes a piece
/// with it.
final class _SongChoices extends StatefulWidget {
  const _SongChoices({
    required this.onMake,
    required this.selected,
    required this.library,
    required this.onMakeWithSong,
  });

  final ValueChanged<MelodyTemplate>? onMake;
  final MelodyTemplate? selected;
  final SongLibrary? library;
  final ValueChanged<CustomSong>? onMakeWithSong;

  @override
  State<_SongChoices> createState() => _SongChoicesState();
}

final class _SongChoicesState extends State<_SongChoices> {
  var _popular = false;
  // the catalogue song being fetched, so its row can show it
  String? _taking;

  @override
  void initState() {
    super.initState();
    widget.library?.ensureLoaded();
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _take(CatalogSong song) async {
    final library = widget.library;
    final make = widget.onMakeWithSong;
    if (library == null || make == null || _taking != null) return;
    setState(() => _taking = song.id);
    try {
      make(await library.take(song));
    } on SongCatalogException catch (error) {
      _say(error.message);
    } finally {
      if (mounted) setState(() => _taking = null);
    }
  }

  Future<void> _import() async {
    final library = widget.library;
    if (library == null) return;
    final CustomSong? read;
    try {
      read = await library.pickMidi();
    } on MidiSongProblem catch (error) {
      return _say(error.message);
    }
    if (read == null || !mounted) return;
    final choice = await showSongImportSheet(
      context,
      read,
      canPost: library.canPost,
    );
    if (choice == null) return;
    final song = await library.keep(
      read,
      title: choice.title,
      credit: choice.credit,
    );
    if (!mounted) return;
    if (choice.post) {
      await _post(song);
    } else {
      widget.onMakeWithSong?.call(song);
    }
  }

  Future<void> _post(CustomSong song) async {
    final library = widget.library;
    if (library == null) return;
    final rights = await showSongPostSheet(context, song);
    if (rights == null) return;
    try {
      await library.post(song, rights);
      _say('「${song.title}」を投稿しました');
    } on SongCatalogException catch (error) {
      _say(error.message);
    }
  }

  Future<void> _report(CatalogSong song) async {
    final library = widget.library;
    if (library == null) return;
    final reason = await showSongReportDialog(context, song);
    if (reason == null) return;
    try {
      await library.report(song, reason);
      _say('通報を受けつけました。ありがとうございます');
    } on SongCatalogException catch (error) {
      _say(error.message);
    }
  }

  Future<void> _forget(CustomSong song) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('「${song.title}」を消しますか？'),
        content: const Text('この曲でつくった作品は、そのまま残ります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('消す'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.library?.forget(song.id);
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    if (library == null) return _list(context, null);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) => _list(context, library),
    );
  }

  Widget _list(BuildContext context, SongLibrary? library) {
    final make = widget.onMake;
    final makeWithSong = widget.onMakeWithSong;
    final known = [
      for (final melody in melodyChoices)
        if (melody.scoreId != null) melody,
    ];
    final patterns = [
      for (final melody in melodyChoices)
        if (melody.scoreId == null) melody,
    ];
    Widget builtIn(MelodyTemplate melody, int index) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _SongRow(
        title: melody.label,
        caption: melody.description,
        color: AppTokens.soundColor(index),
        current: melody == widget.selected,
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
        if (library != null) ...[
          ..._catalog(library),
          const SizedBox(height: 12),
          ..._local(library, makeWithSong),
          const SizedBox(height: 12),
        ],
        const _GroupLabel('みんなが知ってる曲'),
        const SizedBox(height: 10),
        for (final (index, melody) in known.indexed) builtIn(melody, index),
        const SizedBox(height: 12),
        const _GroupLabel('オトグラシのパターン'),
        const SizedBox(height: 10),
        for (final (index, melody) in patterns.indexed)
          builtIn(melody, known.length + index),
      ],
    );
  }

  List<Widget> _catalog(SongLibrary library) {
    final songs = _popular ? library.popular : library.newest;
    return [
      Row(
        children: [
          const Expanded(child: _GroupLabel('みんなの曲')),
          if (library.catalogPhase == CatalogPhase.loaded)
            for (final (popular, label) in const [(false, '新着'), (true, '人気')])
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _SmallToggle(
                  label: label,
                  selected: _popular == popular,
                  onTap: () => setState(() => _popular = popular),
                ),
              ),
        ],
      ),
      const SizedBox(height: 10),
      switch (library.catalogPhase) {
        CatalogPhase.unavailable => const _Notice(
          'みんなが投稿した曲は、まだ準備中です。MIDIを読み込めば、自分の曲はいまも使えます。',
        ),
        CatalogPhase.loading => const _Notice('みんなの曲を読み込んでいます…'),
        CatalogPhase.failed => _Notice(
          library.catalogMessage ?? 'みんなの曲を読み込めませんでした。',
          action: 'もう一度',
          onAction: library.refresh,
        ),
        CatalogPhase.loaded when songs.isEmpty => const _Notice(
          'まだ投稿がありません。MIDIを読み込んで、最初の1曲を投稿してみませんか。',
        ),
        CatalogPhase.loaded => Column(
          children: [
            for (final (index, song) in songs.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SongRow(
                  title: song.title,
                  caption: [
                    if (song.credit.isNotEmpty) song.credit,
                    if (song.author.isNotEmpty) '${song.author}さん',
                    if (song.uses > 0) '${song.uses}回つかわれた',
                  ].join(' · '),
                  color: AppTokens.soundColor(index),
                  busy: _taking == song.id,
                  onMake: widget.onMakeWithSong == null
                      ? null
                      : () => _take(song),
                  menu: [('通報する', () => _report(song))],
                ),
              ),
            if (!_popular && library.hasMore)
              TextButton(
                onPressed: library.loadMore,
                child: const Text('もっと見る'),
              ),
          ],
        ),
      },
    ];
  }

  List<Widget> _local(
    SongLibrary library,
    ValueChanged<CustomSong>? makeWithSong,
  ) => [
    const _GroupLabel('よみこんだ曲'),
    const SizedBox(height: 10),
    for (final (index, song) in library.local.indexed)
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _SongRow(
          title: song.title,
          caption: [
            if (song.credit.isNotEmpty) song.credit,
            if (song.author case final author?)
              '$authorさんの投稿'
            else
              'MIDIから読み込んだ曲',
          ].join(' · '),
          color: AppTokens.soundColor(index + 3),
          onMake: makeWithSong == null ? null : () => makeWithSong(song),
          menu: [
            if (library.canPost && song.origin == SongOrigin.imported)
              ('みんなに投稿する', () => _post(song)),
            ('この曲を消す', () => _forget(song)),
          ],
        ),
      ),
    if (library.canImport)
      OutlinedButton.icon(
        onPressed: _import,
        icon: const Icon(Icons.file_open_outlined, size: 20),
        label: const Text('MIDIを読み込む'),
      )
    else if (library.local.isEmpty)
      const _Notice('MIDIの読み込みは、iPhoneのアプリで使えます。'),
  ];
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

/// A quiet line where a list would be: nothing yet, loading, or a problem.
final class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: AppTokens.tile,
      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppTokens.mutedInk,
            ),
          ),
        ),
        if (action case final action?)
          TextButton(onPressed: onAction, child: Text(action))
        else
          const SizedBox(width: 8),
      ],
    ),
  );
}

final class _SmallToggle extends StatelessWidget {
  const _SmallToggle({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // 44pt to touch around a smaller pill
      child: SizedBox(
        height: 44,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? AppTokens.ink : AppTokens.tile,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: selected ? Colors.white : AppTokens.ink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.title,
    required this.caption,
    required this.color,
    required this.onMake,
    this.current = false,
    this.busy = false,
    this.menu = const [],
  });

  final String title;
  final String caption;
  final Color color;
  final bool current;

  /// The song is being fetched.
  final bool busy;
  final VoidCallback? onMake;

  /// Further things to do with this song, under a "…" button.
  final List<(String, VoidCallback)> menu;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(AppTokens.tileRadius),
    clipBehavior: Clip.antiAlias,
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            enabled: onMake != null,
            label: '$titleでつくる',
            child: InkWell(
              onTap: busy ? null : onMake,
              child: Padding(
                padding: EdgeInsets.fromLTRB(14, 12, menu.isEmpty ? 12 : 4, 12),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
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
                                  title,
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
                          if (caption.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              caption,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                color: AppTokens.mutedInk,
                              ),
                            ),
                          ],
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
                        busy ? '…' : 'つくる',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: onMake == null
                              ? AppTokens.mutedInk
                              : Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (menu.isNotEmpty)
          PopupMenuButton<int>(
            tooltip: '$titleのメニュー',
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppTokens.mutedInk,
            ),
            onSelected: (index) => menu[index].$2(),
            itemBuilder: (context) => [
              for (final (index, item) in menu.indexed)
                PopupMenuItem<int>(value: index, child: Text(item.$1)),
            ],
          ),
      ],
    ),
  );
}
