import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tokens.dart';
import 'sound_row.dart';

/// A folder the sound can be moved to.
typedef MoveTarget = ({String id, String title});

/// Long-press actions for one sound. The sound lifts out of the list over a
/// blurred page, and a white panel under it swaps between the menu and each
/// small editor (name, tags, move, delete) — no bottom sheets.
Future<void> showSoundActions(
  BuildContext context, {
  required String name,
  required Future<Uint8List>? thumbnail,
  required Color color,
  required int number,
  required List<String> tags,
  required List<String> tagSuggestions,
  required List<MoveTarget> moveTargets,
  required VoidCallback onFullScreen,
  required VoidCallback onTrim,
  required Future<void> Function(String name) onRename,
  required Future<void> Function(List<String> tags) onTags,
  required Future<void> Function(String folderId) onMove,
  required Future<void> Function() onDelete,
}) {
  HapticFeedback.mediumImpact();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '閉じる',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => _SoundActions(
      name: name,
      thumbnail: thumbnail,
      color: color,
      number: number,
      tags: tags,
      tagSuggestions: tagSuggestions,
      moveTargets: moveTargets,
      onFullScreen: onFullScreen,
      onTrim: onTrim,
      onRename: onRename,
      onTags: onTags,
      onMove: onMove,
      onDelete: onDelete,
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: const Cubic(0.3, 1.35, 0.5, 1),
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
}

enum _Pane { menu, rename, tags, move, delete }

class _SoundActions extends StatefulWidget {
  const _SoundActions({
    required this.name,
    required this.thumbnail,
    required this.color,
    required this.number,
    required this.tags,
    required this.tagSuggestions,
    required this.moveTargets,
    required this.onFullScreen,
    required this.onTrim,
    required this.onRename,
    required this.onTags,
    required this.onMove,
    required this.onDelete,
  });

  final String name;
  final Future<Uint8List>? thumbnail;
  final Color color;
  final int number;
  final List<String> tags;
  final List<String> tagSuggestions;
  final List<MoveTarget> moveTargets;
  final VoidCallback onFullScreen;
  final VoidCallback onTrim;
  final Future<void> Function(String name) onRename;
  final Future<void> Function(List<String> tags) onTags;
  final Future<void> Function(String folderId) onMove;
  final Future<void> Function() onDelete;

  @override
  State<_SoundActions> createState() => _SoundActionsState();
}

class _SoundActionsState extends State<_SoundActions> {
  var _pane = _Pane.menu;
  late final _name = TextEditingController(text: widget.name);
  final _newTag = TextEditingController();
  late final _tags = <String>{...widget.tags};
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _newTag.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _thenClose(VoidCallback action) {
    Navigator.pop(context);
    action();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.pop(context),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: const ColoredBox(color: Color(0x33000000)),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: inset),
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _LiftedSound(
                      name: widget.name,
                      thumbnail: widget.thumbnail,
                      color: widget.color,
                      number: widget.number,
                      tags: _tags.toList(),
                    ),
                    const SizedBox(height: 16),
                    Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                      clipBehavior: Clip.antiAlias,
                      child: SizedBox(
                        width: 300,
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: KeyedSubtree(
                              key: ValueKey(_pane),
                              child: switch (_pane) {
                                _Pane.menu => _menu(),
                                _Pane.rename => _rename(),
                                _Pane.tags => _tagEditor(),
                                _Pane.move => _move(),
                                _Pane.delete => _delete(),
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _menu() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _MenuRow(
        icon: Icons.fullscreen_rounded,
        label: 'フル画面で見る',
        onTap: () => _thenClose(widget.onFullScreen),
      ),
      _MenuRow(
        icon: Icons.content_cut_rounded,
        label: '使う範囲をえらぶ',
        onTap: () => _thenClose(widget.onTrim),
      ),
      _MenuRow(
        icon: Icons.edit_outlined,
        label: '名前を変える',
        onTap: () => setState(() => _pane = _Pane.rename),
      ),
      _MenuRow(
        icon: Icons.sell_outlined,
        label: 'タグ',
        trailing: _tags.isEmpty ? null : _tags.join('・'),
        onTap: () => setState(() => _pane = _Pane.tags),
      ),
      if (widget.moveTargets.isNotEmpty)
        _MenuRow(
          icon: Icons.drive_file_move_outline,
          label: 'ほかのフォルダへ移動',
          onTap: () => setState(() => _pane = _Pane.move),
        ),
      _MenuRow(
        icon: Icons.delete_outline_rounded,
        label: 'この音を削除',
        destructive: true,
        last: true,
        onTap: () => setState(() => _pane = _Pane.delete),
      ),
    ],
  );

  Widget _paneHeader(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 6, 16, 0),
    child: Row(
      children: [
        IconButton(
          onPressed: () => setState(() => _pane = _Pane.menu),
          tooltip: 'もどる',
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );

  Widget _rename() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _paneHeader('名前を変える'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 40,
              decoration: const InputDecoration(hintText: '例：コップを置く音'),
              onSubmitted: (_) => _run(() => widget.onRename(_name.text)),
            ),
            FilledButton(
              onPressed: _busy ? null : () => _run(() => widget.onRename(_name.text)),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _tagEditor() {
    final options = <String>{...widget.tagSuggestions, ..._tags}.toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paneHeader('タグ'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in options)
                    _TagPill(
                      label: tag,
                      selected: _tags.contains(tag),
                      onTap: () => setState(() {
                        if (!_tags.remove(tag)) _tags.add(tag);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _newTag,
                maxLength: 12,
                decoration: const InputDecoration(
                  hintText: '新しいタグ（例：海、1日目）',
                  counterText: '',
                ),
                onSubmitted: (value) => setState(() {
                  if (value.trim().isNotEmpty) _tags.add(value.trim());
                  _newTag.clear();
                }),
              ),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() {
                        final pending = _newTag.text.trim();
                        return widget.onTags([
                          ..._tags,
                          if (pending.isNotEmpty) pending,
                        ]);
                      }),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _move() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _paneHeader('どのフォルダへ？'),
      for (final (index, target) in widget.moveTargets.indexed)
        _MenuRow(
          icon: Icons.folder_outlined,
          label: target.title,
          last: index == widget.moveTargets.length - 1,
          onTap: _busy ? null : () => _run(() => widget.onMove(target.id)),
        ),
    ],
  );

  Widget _delete() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _paneHeader('この音を削除しますか？'),
      const Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Text(
          'すべてのフォルダから消えます。作った曲に使われている音は、その曲の中には残ります。',
          style: TextStyle(fontSize: 13, color: AppTokens.mutedInk, height: 1.5),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: FilledButton(
          onPressed: _busy ? null : () => _run(widget.onDelete),
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.blush,
            foregroundColor: Colors.white,
          ),
          child: const Text('削除する'),
        ),
      ),
    ],
  );
}

final class _LiftedSound extends StatelessWidget {
  const _LiftedSound({
    required this.name,
    required this.thumbnail,
    required this.color,
    required this.number,
    required this.tags,
  });

  final String name;
  final Future<Uint8List>? thumbnail;
  final Color color;
  final int number;
  final List<String> tags;

  @override
  Widget build(BuildContext context) => Container(
    width: 300,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
      boxShadow: const [
        BoxShadow(color: Color(0x26000000), blurRadius: 30, offset: Offset(0, 14)),
      ],
    ),
    child: Row(
      children: [
        SoundThumb(thumbnail: thumbnail, color: color, number: number, size: 72),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [for (final tag in tags) SoundTagChip(tag)],
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

final class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.destructive = false,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? trailing;
  final bool destructive;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final ink = destructive ? AppTokens.blush : AppTokens.ink;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          border: last
              ? null
              : const Border(bottom: BorderSide(color: AppTokens.hairline)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: ink,
                ),
              ),
            ),
            if (trailing case final text?)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTokens.mutedInk,
                    ),
                  ),
                ),
              ),
            Icon(icon, size: 20, color: ink),
          ],
        ),
      ),
    );
  }
}

final class _TagPill extends StatelessWidget {
  const _TagPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? AppTokens.ink : AppTokens.tile,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w800,
          color: selected ? Colors.white : AppTokens.ink,
        ),
      ),
    ),
  );
}
