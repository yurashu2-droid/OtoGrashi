import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/playback_chrome.dart';
import '../../design/rolling_tab_bar.dart';
import '../../design/tokens.dart';
import '../../domain/arrangement.dart';
import '../../domain/clip_asset.dart';
import '../../domain/custom_song.dart';
import '../../domain/melody_template.dart';
import '../../domain/project.dart';
import '../../domain/video_recipe.dart';
import '../arrange/adjustments_sheet.dart';
import '../home/folder_screen.dart';
import '../home/home_screen.dart';
import '../sharing/shared_folders_screen.dart';
import '../../sharing/shared_folder_service.dart';
import '../library/library_screen.dart';
import '../settings/settings_screen.dart';
import '../songs/song_library.dart';
import '../songs/songs_screen.dart';
import '../../storage/folder_repository.dart';
import '../../storage/project_repository.dart';
import '../../features/capture/capture_controller.dart';
import '../../features/capture/capture_screen.dart';
import '../../features/capture/capture_state.dart';
import '../../media/media_gateway.dart';
import '../../media/media_presentation_gateway.dart';
import '../../media/media_delivery_gateway.dart';
import '../export/comparison_player.dart';
import '../export/media_playback.dart';
import 'beat_building_preview.dart';
import 'performance_controls.dart';
import 'clip_card.dart';
import 'creation_controller.dart';
import 'making_screen.dart';

class CreationFlow extends StatefulWidget {
  const CreationFlow({
    required this.controller,
    required this.media,
    this.delivery,
    this.startWithCapture = false,
    this.startInLibrary = false,
    this.folders,
    this.sharedFolders,
    this.pendingInvitation,
    this.onInvitationOpened,
    this.startAtHome = false,
    this.onOwnerName,
    this.songLibrary,
    super.key,
  });

  final CreationController controller;
  final MediaGateway media;
  final MediaDeliveryGateway? delivery;
  final bool startWithCapture;
  final bool startInLibrary;
  final FolderRepository? folders;
  final SharedFolderService? sharedFolders;
  final String? pendingInvitation;
  final ValueChanged<String>? onInvitationOpened;

  /// Open on Home rather than inside the song in progress.
  final bool startAtHome;

  /// Saves the creator name from Settings; returns the name as stored.
  final Future<String?> Function(String name)? onOwnerName;

  /// Songs from outside the app (MIDI files, the catalogue), for the 曲 tab.
  final SongLibrary? songLibrary;

  @override
  State<CreationFlow> createState() => _CreationFlowState();
}

final class _SongRoleSummary extends StatelessWidget {
  const _SongRoleSummary({required this.state});

  final CreationState state;

  @override
  Widget build(BuildContext context) {
    final isMidiScore = state.melody.isMidiScore;
    final arrangement = state.project?.arrangement;
    final roles =
        arrangement != null &&
            arrangement['melodyTemplate'] == state.melody.name
        ? arrangement['songRoles']
        : null;
    if (roles is! Map) {
      return Text(
        '撮った音の担当を探しています…',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    String name(Object? id) {
      if (id is! String) return 'お休み';
      for (final clip in state.clips) {
        if (clip.id == id) return clip.label;
      }
      return 'お休み';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('撮った音の担当', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry
                  in (isMidiScore
                          ? <String, Object?>{
                              'メロディ': roles['melody'],
                              'ベース': roles['bass'],
                              'ピアノ': roles['keys'],
                            }
                          : <String, Object?>{
                              '拍': roles['beat'],
                              'ベース風': roles['bass'],
                              'ピアノ風': roles['keys'],
                              '旋律': roles['melody'],
                            })
                      .entries)
                Chip(label: Text('${entry.key}  ${name(entry.value)}')),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isMidiScore ? '音程が取れない音も、楽譜のリズムに合わせて鳴らします' : 'どの役割も、撮った音だけで鳴らしています',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _CreationFlowState extends State<CreationFlow> {
  var _captureOpened = false;
  late int _tabIndex = widget.startInLibrary ? 1 : 0;
  // Home shows the folder list; the current folder opens on top of it.
  late var _folderOpen = !widget.startAtHome;
  var _capturing = false;
  // the folder the last recording went into, offered first next time
  String? _destinationId;
  var _sharingOpen = false;
  String? _openedInvitation;
  // what is remembered about the finished song while another tab is open
  _FinishedSong? _finished;

  @override
  void didUpdateWidget(CreationFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pendingInvitation != widget.pendingInvitation) {
      _openedInvitation = null;
      _scheduleInvitation();
    }
  }

  void _scheduleInvitation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sharingOpen) return;
      final invitation = widget.pendingInvitation;
      if (invitation == null || invitation == _openedInvitation ||
          widget.sharedFolders == null) {
        return;
      }
      _openedInvitation = invitation;
      widget.onInvitationOpened?.call(invitation);
      unawaited(_openSharedFolders(invitation: invitation));
    });
  }

  Future<void> _openSharedFolders({String? invitation}) async {
    final service = widget.sharedFolders;
    if (service == null || _sharingOpen) return;
    _sharingOpen = true;
    try {
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => SharedFoldersScreen(
          service: service,
          assets: widget.controller.assets,
          presentation: widget.controller.presentation,
          ownerName: widget.controller.ownerName,
          initialInvitation: invitation,
          onMakeSong: _makeSongFrom,
        ),
      ));
    } finally {
      _sharingOpen = false;
      if (mounted) {
        setState(() {});
        _scheduleInvitation();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleInvitation();
    if (widget.startWithCapture && !_captureOpened && widget.pendingInvitation == null) {
      _captureOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final before = widget.controller.state.clips.length;
        await _openCapture();
        // the first sound is ready to become a song: show it with つくる in reach
        if (mounted && widget.controller.state.clips.length > before) {
          setState(() => _folderOpen = true);
        }
      });
    }
  }

  /// Records a sound. From the collection (no [folder]) it joins いま集めてる音
  /// while there is room; it is always filed into the chosen folder too.
  /// From a folder it goes only into that folder.
  Future<void> _openCapture({bool fromPhotos = false, SoundFolder? folder}) async {
    final before = widget.controller.state.clips.map((clip) => clip.id).toSet();
    final folders = widget.folders;
    var destinations = const <SoundFolder>[];
    if (folders != null) {
      destinations = await folders.list();
      if (destinations.isEmpty) {
        destinations = [await folders.create(SqliteFolderRepository.starterTitle)];
      }
    }
    if (!mounted) return;
    final ids = destinations.map((d) => d.id).toSet();
    var destination =
        folder?.id ??
        (ids.contains(_destinationId) ? _destinationId : null) ??
        destinations.firstOrNull?.id;
    final intoCollection = folder == null;
    await Navigator.of(context).push<void>(
      // A fade, so the shutter (a Hero shared with the tab bar's mic ball)
      // is what visibly travels and grows into place.
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 460),
        reverseTransitionDuration: const Duration(milliseconds: 340),
        transitionsBuilder: (context, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
        pageBuilder: (_, _, _) => _CaptureRoute(
          media: widget.media,
          presentation: widget.controller.presentation,
          fromPhotos: fromPhotos,
          recordedClipCount: widget.controller.state.clips.length,
          destinations: [for (final d in destinations) (id: d.id, title: d.title)],
          initialDestination: destination,
          onDestination: (id) {
            destination = id;
            _destinationId = id;
          },
          onCommit: (captured) async {
            final controller = widget.controller;
            String? newId;
            if (intoCollection && controller.state.clips.length < 6) {
              if (await controller.addCaptured(captured)) {
                newId = controller.state.clips.last.id;
              }
            } else {
              newId = (await controller.importCaptured(captured))?.id;
            }
            if (newId == null) return false;
            final target = destination;
            if (folders != null && target != null) {
              await folders.addAsset(target, newId);
              _destinationId = target;
            }
            if (mounted) unawaited(HapticFeedback.selectionClick());
            return true;
          },
        ),
        fullscreenDialog: true,
      ),
    );
    if (mounted) await _nameNewRelayClip(before);
  }

  Future<void> _nameNewRelayClip(Set<String> previousIds) async {
    if (!widget.controller.isRelay) return;
    final clips = widget.controller.state.clips;
    final newClips = clips.where((clip) => !previousIds.contains(clip.id));
    if (newClips.isEmpty) return;
    final clip = newClips.last;
    final person = TextEditingController(text: '${clips.length}人目');
    final sound = TextEditingController(text: '音');
    try {
      final label = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'この音はだれの？',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text('名前は完成動画にも表示されます。あとから変更できます。'),
              const SizedBox(height: 16),
              TextField(
                controller: person,
                maxLength: 16,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: '撮った人'),
              ),
              TextField(
                controller: sound,
                maxLength: 20,
                decoration: const InputDecoration(labelText: '音の名前'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final who = person.text.trim();
                  final what = sound.text.trim();
                  final parts = [who, what].where((part) => part.isNotEmpty);
                  Navigator.pop(sheetContext, parts.join(' · '));
                },
                child: const Text('次の人へ渡す'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('あとで名前をつける'),
              ),
            ],
          ),
        ),
      );
      if (label != null && label.isNotEmpty && mounted) {
        try {
          await widget.controller.renameClip(clip.id, label);
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('名前を保存できませんでした')));
          }
        }
      }
    } finally {
      person.dispose();
      sound.dispose();
    }
  }

  Future<void> _openFolder(SoundFolder folder) async {
    final folders = widget.folders;
    if (folders == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FolderScreen(
          folder: folder,
          folders: folders,
          assets: widget.controller.assets,
          presentation: widget.controller.presentation,
          onCapture: (target) => _openCapture(folder: target),
          onMakeSong: _makeSongFrom,
        ),
      ),
    );
  }

  /// A song from a folder: those sounds become the collection, and the song
  /// settings open (nothing is made until つくる). A song already in progress
  /// is never replaced without asking.
  Future<void> _makeSongFrom(List<ClipAsset> sounds) async {
    final controller = widget.controller;
    final draft = controller.state;
    var addToDraft = false;
    if (draft.clips.isNotEmpty && draft.phase != CreationPhase.completed) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('つくりかけの曲があります'),
          content: Text(
            'いまの${draft.clips.length}つの音に足しますか？ それとも、新しい曲にしますか？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('キャンセル'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('いまの曲に足す'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('新しい曲にする'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      addToDraft = choice;
    }
    if (!addToDraft) controller.startNew();
    for (final sound in sounds.take(6)) {
      await controller.addExisting(sound);
    }
    if (!mounted) return;
    setState(() {
      _tabIndex = 0;
      _folderOpen = true;
    });
    controller.beginChoosing();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _openProject(Project project) async {
    await widget.controller.openProject(project);
    if (mounted) {
      setState(() {
        _tabIndex = 0;
        _folderOpen = true;
      });
    }
  }

  /// The centre mic: the ball rolls onto it, then the camera opens; after
  /// capture the new sound lands in the current folder on Home.
  Future<void> _captureFromBar() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    await Future<void>.delayed(const Duration(milliseconds: 540));
    if (!mounted) return;
    try {
      await _startCaptureFromLibrary();
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _selectTab(RollingTab tab) {
    switch (tab) {
      case RollingTab.home:
        setState(() {
          if (_tabIndex == 0) _folderOpen = false;
          _tabIndex = 0;
        });
      case RollingTab.capture:
        unawaited(_captureFromBar());
      case RollingTab.songs:
        setState(() => _tabIndex = 1);
    }
  }

  Future<void> _startCaptureFromLibrary() async {
    if (mounted) {
      setState(() {
        _tabIndex = 0;
        _folderOpen = true;
      });
    }
    if (widget.controller.state.phase == CreationPhase.completed) {
      widget.controller.startNew();
    }
    await _openCapture();
  }

  /// "この曲でつくる" from the 曲 tab: the song is chosen first; with sounds
  /// already collected the settings open, otherwise the camera does.
  Future<void> _makeWithSong(MelodyTemplate melody) =>
      _makeWith(() => widget.controller.presetMelody(melody));

  /// The same for a song from outside the app.
  Future<void> _makeWithCustomSong(CustomSong song) =>
      _makeWith(() => widget.controller.presetSong(song));

  Future<void> _makeWith(VoidCallback choose) async {
    final controller = widget.controller;
    if (controller.state.phase == CreationPhase.completed) {
      controller.startNew();
    }
    choose();
    if (controller.state.clips.isEmpty) {
      await _captureFromBar();
      return;
    }
    setState(() {
      _tabIndex = 0;
      _folderOpen = true;
    });
    controller.beginChoosing();
  }

  /// Adds a sound from a list to the song in progress. The person stays where
  /// they are, so several sounds can be added in a row.
  Future<void> _reuseAsset(ClipAsset asset) async {
    final controller = widget.controller;
    // a finished song is left as it is: this starts the next one
    if (controller.state.phase == CreationPhase.completed) {
      controller.startNew();
    }
    final before = controller.state.clips.map((clip) => clip.id).toSet();
    final String message;
    if (before.contains(asset.id)) {
      message = 'この音は、もう入っています';
    } else if (before.length >= 6) {
      message = '曲に入れられるのは6つまでです';
    } else {
      await controller.addExisting(asset);
      if (!mounted) return;
      final count = controller.state.clips.length;
      message = count > before.length
          ? 'つくりかけの曲に入れました（$count/6）'
          : '追加できませんでした。もう一度お試しください。';
      await _nameNewRelayClip(before);
      if (!mounted) return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: '見る',
            onPressed: () => setState(() {
              _tabIndex = 0;
              _folderOpen = true;
            }),
          ),
        ),
      );
  }

  /// Deletes a sound from the phone and from every folder, unless a song
  /// (the one in progress included) still uses it. Completes with the number
  /// of songs using it: 0 when the sound is gone.
  Future<int> _deleteSound(ClipAsset asset) async {
    final assets = widget.controller.assets;
    final songs = (await assets.referencingProjectIds(asset.id)).length;
    if (songs > 0) return songs;
    await widget.folders?.removeEverywhere(asset.id);
    await assets.deleteUnreferenced(asset.id);
    return await assets.load(asset.id) == null ? 0 : 1;
  }

  /// The song in progress was deleted in the library: let go of it, or every
  /// later recording would try to join a project that is gone.
  void _projectDeleted(Project project) {
    final controller = widget.controller;
    if (controller.state.project?.id == project.id) controller.startNew();
  }

  Widget _settings() {
    final projects = widget.controller.projects;
    if (projects is! SqliteProjectRepository) {
      return const Scaffold(body: Center(child: Text('設定を読み込めません')));
    }
    final saveName = widget.onOwnerName;
    final sharing = widget.sharedFolders;
    return SettingsScreen(
      usageLoader: projects.storageUsage,
      clearCache: projects.clearRegenerableCache,
      ownerName: widget.controller.ownerName,
      accountName: sharing == null
          ? null
          : () async => (await sharing.account())?.displayName,
      onDeleteAccount: sharing?.deleteAccount,
      onOwnerName: saveName == null
          ? null
          : (name) async {
              final saved = await saveName(name);
              widget.controller.ownerName = saved;
              if (mounted) setState(() {});
              return saved;
            },
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final state = widget.controller.state;
      final content = switch (_tabIndex) {
        1 => SongsScreen(
          onSettings: _openSettings,
          onMakeWithTemplate: (melody) => unawaited(_makeWithSong(melody)),
          onOpenSharedFolders: widget.sharedFolders == null
              ? null
              : () => unawaited(_openSharedFolders()),
          selectedMelody:
              state.clips.isEmpty || state.phase == CreationPhase.completed
              ? null
              : state.melody,
          library: widget.songLibrary,
          onMakeWithSong: (song) => unawaited(_makeWithCustomSong(song)),
          mine: LibraryScreen(
            projects: widget.controller.projects,
            assets: widget.controller.assets,
            presentation: widget.controller.presentation,
            delivery: widget.delivery ?? PlatformMediaDeliveryGateway(),
            initialTabIndex: 0,
            embedded: true,
            onCreate: _startCaptureFromLibrary,
            onProjectSelected: _openProject,
            onProjectDeleted: _projectDeleted,
            onAssetSelected: _reuseAsset,
            onDeleteAsset: _deleteSound,
          ),
        ),
        _ => _creationContent(state),
      };
      final showBar =
          content is HomeScreen || content is _CollectScreen || _tabIndex == 1;
      return Scaffold(
        body: content,
        bottomNavigationBar: showBar
            ? SafeArea(
                top: false,
                child: RollingTabBar(
                  selected: _capturing
                      ? RollingTab.capture
                      : _tabIndex == 1
                      ? RollingTab.songs
                      : RollingTab.home,
                  onSelected: _selectTab,
                ),
              )
            : null,
      );
    },
  );

  void _openSettings() => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => _settings()));

  Widget _creationContent(CreationState state) {
    if (state.phase == CreationPhase.completed) {
      final key = '${state.project?.id}:${state.project?.revision}';
      var finished = _finished;
      if (finished == null || finished.key != key) {
        finished = _finished = _FinishedSong(key);
      }
      return _CompletedScreen(
        controller: widget.controller,
        delivery: widget.delivery,
        song: finished,
        onOpenLibrary: () => setState(() => _tabIndex = 1),
        onClose: () {
          setState(() => _folderOpen = false);
          widget.controller.startNew();
        },
      );
    }
    // Pressing つくる shows its own waiting screen until the song is ready.
    if (state.making &&
        (state.phase == CreationPhase.preparing ||
            state.phase == CreationPhase.rendering)) {
      return MakingScreen(
        clips: state.clips,
        thumbnails: state.thumbnails,
        seconds: state.durationSeconds,
        progress: widget.controller.renderProgress,
        stage: widget.controller.renderStage,
        onCancel: () => unawaited(widget.controller.cancelMaking()),
      );
    }
    if (state.preview != null ||
        state.choosing ||
        state.phase == CreationPhase.rendering ||
        (state.phase == CreationPhase.failed && state.project != null)) {
      return _ArrangeScreen(controller: widget.controller);
    }
    if (!_folderOpen) {
      return HomeScreen(
        currentClips: state.clips,
        thumbnails: state.thumbnails,
        assets: widget.controller.assets,
        presentation: widget.controller.presentation,
        ownerName: widget.controller.ownerName,
        onOpenCurrent: () => setState(() => _folderOpen = true),
        onMakeCurrent: () {
          setState(() => _folderOpen = true);
          widget.controller.beginChoosing();
        },
        folders: widget.folders,
        onOpenFolder: _openFolder,
        onOpenSharedFolders: widget.sharedFolders == null
            ? null : () => unawaited(_openSharedFolders()),
        onAssetSelected: (asset) => unawaited(_reuseAsset(asset)),
        onSettings: _openSettings,
      );
    }
    return _CollectScreen(
      controller: widget.controller,
      onBack: () => setState(() => _folderOpen = false),
      onCapture: _openCapture,
      onPhotos: () => _openCapture(fromPhotos: true),
    );
  }
}

class _CollectScreen extends StatelessWidget {
  const _CollectScreen({
    required this.controller,
    required this.onBack,
    required this.onCapture,
    required this.onPhotos,
  });
  final CreationController controller;
  final VoidCallback onBack;
  final VoidCallback onCapture;
  final VoidCallback onPhotos;

  Future<void> _previewClip(BuildContext context, ClipAsset clip, int index) =>
      _previewClipSegment(context, clip, controller.comparisonSegments[index]);

  Future<void> _previewClipSegment(
    BuildContext context,
    ClipAsset clip,
    PlaybackSegment segment,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ClipPreviewSheet(
      clip: clip,
      segment: segment,
      presentation: controller.presentation,
    ),
  );

  Future<void> _renameClip(
    BuildContext context,
    ClipAsset clip,
    int index,
  ) async {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    var name = generatedName ? '録った音 ${index + 1}' : clip.label;
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音に名前をつける'),
        content: TextFormField(
          initialValue: name,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: '例：コップを置く音'),
          onChanged: (value) => name = value,
          onFieldSubmitted: (_) => Navigator.pop(dialogContext, name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, name),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (chosen == null || chosen.trim().isEmpty || !context.mounted) return;
    try {
      await controller.renameClip(clip.id, chosen);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('名前を保存できませんでした')));
      }
    }
  }

  Future<void> _removeClip(
    BuildContext context,
    ClipAsset clip,
    int index,
  ) async {
    final generatedName = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$')
        .hasMatch(clip.label);
    final title = generatedName ? '録った音 ${index + 1}' : clip.label;
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音を作品から外しますか？'),
        content: Text('「$title」を音の並びから外します。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('外す'),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    await controller.removeClip(clip.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final segments = controller.comparisonSegments;
    final clipCount = state.clips.length;
    final collectionHint = clipCount == 0
        ? '1本から作成OK · 全6つまで'
        : clipCount < 6
        ? '作成OK · あと${6 - clipCount}つ追加できます'
        : '作成OK · 追加はここまで';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: onBack,
          tooltip: 'ホーム',
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        ),
        title: const Text(
          'つくりかけの曲',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (state.clips.isNotEmpty || controller.isRelay)
            TextButton(
              onPressed: () {
                final leavesDraft = state.clips.isNotEmpty;
                controller.startNew();
                // the sounds collected so far are not thrown away
                if (leavesDraft) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(
                      const SnackBar(
                        content: Text('つくりかけの曲は、曲タブの「じぶん」に残しました'),
                      ),
                    );
                }
              },
              child: Text(state.clips.isEmpty ? 'ひとりでつくる' : '新しくつくる'),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            state.clips.isEmpty ? 12 : 8,
            20,
            28,
          ),
          children: [
            if (state.clips.isEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Transform.rotate(
                  angle: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTokens.blushSoft,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      'STEP 1  /  音の採集ノート',
                      style: TextStyle(
                        color: AppTokens.ink,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                controller.isRelay ? 'ひとり一音、\nみんなで一曲。' : 'いつもの音が、\n音楽に変わる。',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              const SizedBox(height: 10),
              Text(
                controller.isRelay
                    ? 'スマホを順番に渡して、一人ずつ短い音を撮ろう。3人から作れます。'
                    : '声やリアクションは1本から。少ない素材は別の場面もパーツに。最大6本。',
                style: const TextStyle(color: AppTokens.mutedInk, height: 1.5),
              ),
              const SizedBox(height: 22),
            ],
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      for (var index = 0; index < 6; index++) ...[
                        Expanded(
                          child: Container(
                            height: 6,
                            decoration: BoxDecoration(
                              color: index < clipCount
                                  ? AppTokens.soundColor(index)
                                  : AppTokens.hairline,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                        if (index < 5) SizedBox(width: index == 2 ? 12 : 5),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  controller.isRelay ? '$clipCount/6人' : '$clipCount/6',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            if (controller.isRelay || clipCount > 0) ...[
              const SizedBox(height: 4),
              Text(
                controller.isRelay
                    ? clipCount >= 6
                          ? 'みんなの音が集まりました'
                          : clipCount >= 3
                          ? '曲にするか、次の人へ渡そう'
                          : 'あと${3 - clipCount}人で作成OK · 次の人へスマホを渡そう'
                    : collectionHint,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppTokens.mutedInk,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
            ] else
              const SizedBox(height: 22),
            if (state.clips.isEmpty)
              Container(
                padding: EdgeInsets.symmetric(
                  vertical: controller.isRelay ? 38 : 20,
                  horizontal: 22,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                ),
                child: Column(
                  children: [
                    if (controller.isRelay)
                      const Icon(
                        Icons.graphic_eq_rounded,
                        color: AppTokens.coral,
                        size: 42,
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: state.phase == CreationPhase.preparing
                            ? null
                            : controller.startRelay,
                        icon: const Icon(Icons.groups_rounded),
                        label: const Text('みんなで一音ずつ'),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      controller.isRelay
                          ? '最初の人の音から始めよう。'
                          : '会話や長い音も、そのまま録ってみよう。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      controller.isRelay ? '撮ったら次の人へ。' : '同じ場所の音でも大丈夫。',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: state.clips.length,
                onReorderItem: controller.reorder,
                itemBuilder: (context, index) => ClipCard(
                  key: ValueKey(state.clips[index].id),
                  clip: state.clips[index],
                  index: index,
                  thumbnail: state.thumbnails[state.clips[index].id],
                  presentation: controller.presentation,
                  selectionStartUs: segments[index].startUs,
                  selectionDurationUs: segments[index].durationUs,
                  onPreview: () =>
                      _previewClip(context, state.clips[index], index),
                  onTrim: (waveform) => showClipTrimSheet(
                    context,
                    clip: state.clips[index],
                    waveform: waveform,
                    presentation: controller.presentation,
                    selectionStartUs: segments[index].startUs,
                    selectionDurationUs: segments[index].durationUs,
                    onSave: (startUs, durationUs) => controller.setTrim(
                      state.clips[index].id,
                      startUs,
                      durationUs,
                    ),
                    onAudition: (startUs, durationUs) => _previewClipSegment(
                      context,
                      state.clips[index],
                      PlaybackSegment(
                        relativePath: state.clips[index].relativePath,
                        startUs: startUs,
                        durationUs: durationUs,
                      ),
                    ),
                  ),
                  onRename: () =>
                      _renameClip(context, state.clips[index], index),
                  onRemove: () =>
                      _removeClip(context, state.clips[index], index),
                  canMoveDown: index < state.clips.length - 1,
                  onMove: (offset) {
                    final target = (index + offset).clamp(
                      0,
                      state.clips.length - 1,
                    );
                    if (target != index) {
                      unawaited(controller.reorder(index, target));
                    }
                  },
                ),
              ),
            const SizedBox(height: 12),
            if (clipCount >= 6) ...[
              const Text(
                '音は最大6つまで追加できます。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTokens.mutedInk),
              ),
              const SizedBox(height: 8),
            ],
            if (!controller.isRelay || clipCount < 3)
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: state.clips.length >= 6 ? null : onCapture,
                      icon: const Icon(Icons.videocam_outlined),
                      label: const Text('今撮る'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.ink,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 148,
                    child: OutlinedButton.icon(
                      onPressed: state.clips.length >= 6 ? null : onPhotos,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('動画を選ぶ'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ),
                ],
              ),
            if (state.clips.isNotEmpty && !controller.deferRendering)
              TextButton.icon(
                icon: const Icon(Icons.tune_rounded),
                label: Text(
                  '演出と長さ · ${PerformanceControls.labels[state.performanceMode]!.$1} · ${state.durationSeconds}秒',
                ),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (sheetContext) => SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: AnimatedBuilder(
                        animation: controller,
                        builder: (context, _) => PerformanceControls(
                          mode: controller.state.performanceMode,
                          seconds: controller.state.durationSeconds,
                          onMode: controller.selectPerformance,
                          onDuration: controller.selectDuration,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (state.phase == CreationPhase.preparing) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('音を確かめています', textAlign: TextAlign.center),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(
                '準備できませんでした。素材を確認して、もう一度お試しください。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: state.phase == CreationPhase.readyToCreate
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: controller.isRelay && clipCount < 6
                    ? Row(
                        children: [
                          IconButton.outlined(
                            onPressed: onPhotos,
                            tooltip: '動画を選ぶ',
                            icon: const Icon(Icons.photo_library_outlined),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            onPressed: onCapture,
                            tooltip: '次の人を撮る',
                            icon: const Icon(Icons.videocam_outlined),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton(
                              onPressed: controller.deferRendering
                                  ? controller.beginChoosing
                                  : controller.createPreview,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTokens.ink,
                                foregroundColor: Colors.white,
                              ),
                              child: Text('${state.durationSeconds}秒の曲にする ↗'),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // the song chosen so far (also from the 曲 tab)
                          if (controller.deferRendering) ...[
                            Text(
                              '曲は「${state.songLabel}」。次の画面で変えられます',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTokens.mutedInk,
                              ),
                            ),
                            const SizedBox(height: 6),
                          ],
                          FilledButton(
                            onPressed: controller.deferRendering
                                ? controller.beginChoosing
                                : controller.createPreview,
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTokens.ink,
                              foregroundColor: Colors.white,
                            ),
                            child: Text(
                              controller.deferRendering
                                  ? 'この音で曲をつくる  ↗'
                                  : 'この音で${state.durationSeconds}秒をつくる  ↗',
                            ),
                          ),
                        ],
                      ),
              ),
            )
          : null,
    );
  }
}

class _ClipPreviewSheet extends StatefulWidget {
  const _ClipPreviewSheet({
    required this.clip,
    required this.segment,
    required this.presentation,
  });

  final ClipAsset clip;
  final PlaybackSegment segment;
  final MediaPresentationGateway presentation;

  @override
  State<_ClipPreviewSheet> createState() => _ClipPreviewSheetState();
}

class _ClipPreviewSheetState extends State<_ClipPreviewSheet> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.presentation,
  );

  @override
  void dispose() {
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    heightFactor: 0.78,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.clip.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: '閉じる',
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('曲にする前の、元の動画と音'),
            const SizedBox(height: 14),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: NativeMovieView(
                      relativePath: widget.clip.relativePath,
                      segments: [widget.segment],
                      gateway: widget.presentation,
                      controller: playback,
                      fallback: const ColoredBox(
                        color: Color(0xFF302D36),
                        child: Center(child: Text('元の動画')),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _PlaybackControls(playback: playback, label: '元の音'),
          ],
        ),
      ),
    ),
  );
}

class _ArrangeScreen extends StatefulWidget {
  const _ArrangeScreen({required this.controller});
  final CreationController controller;

  @override
  State<_ArrangeScreen> createState() => _ArrangeScreenState();
}

class _ArrangeScreenState extends State<_ArrangeScreen> {
  final ScrollController _scrollController = ScrollController(
    keepScrollOffset: false,
  );
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.controller.presentation,
  );

  @override
  void dispose() {
    _scrollController.dispose();
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  Future<void> _openComparison() async {
    final state = widget.controller.state;
    final songPath = state.preview?.relativePath;
    if (songPath == null) return;
    await playback.pause();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComparisonPlayer(
          songPath: songPath,
          originalSegments: widget.controller.comparisonSegments,
          presentation: widget.controller.presentation,
          fallback: _SyntheticPreview(clips: state.clips),
        ),
      ),
    );
  }

  Future<void> _renameSounds() async {
    final startingRevision = widget.controller.state.project?.revision;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final clips = widget.controller.state.clips;
          return SafeArea(
            child: SizedBox(
              height: (88.0 + clips.length * 62).clamp(
                150.0,
                MediaQuery.sizeOf(context).height * .7,
              ),
              child: ListView(
                children: [
                  const ListTile(title: Text('音の名前をつける')),
                  for (var index = 0; index < clips.length; index++)
                    ListTile(
                      title: Text(_soundName(clips[index], index)),
                      trailing: const Icon(Icons.edit_rounded),
                      onTap: () => _renameSound(clips[index], index),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted &&
        widget.controller.state.project?.revision != startingRevision) {
      widget.controller.refreshNamedPreview();
    }
  }

  String _soundName(ClipAsset clip, int index) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(clip.label)
      ? '録った音 ${index + 1}'
      : clip.label;

  Future<void> _renameSound(ClipAsset clip, int index) async {
    var draft = _soundName(clip, index);
    final chosen = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('この音の名前'),
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '例：友だちのわっ！'),
          onChanged: (value) => draft = value,
          onFieldSubmitted: (_) => Navigator.pop(dialogContext, draft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, draft),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || chosen == null || chosen.trim().isEmpty) return;
    try {
      await widget.controller.renameClip(clip.id, chosen.trim());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('音の名前を保存できませんでした')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final path = state.preview?.relativePath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('曲をつくる'),
        centerTitle: true,
        leading: IconButton(
          onPressed: widget.controller.editClips,
          tooltip: '素材に戻る',
          icon: const Icon(Icons.arrow_back_rounded),
        ),
      ),
      body: SafeArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
          children: [
            _UsedSounds(
              clips: state.clips,
              thumbnails: state.thumbnails,
              onRename: _renameSounds,
            ),
            const SizedBox(height: 18),
            const _SectionLabel('曲'),
            const SizedBox(height: 8),
            // one sliding row, so the list of songs never pushes the page down
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  // a song from outside the app comes first, under its own name
                  if (state.song case final song?)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _PillChoice(
                        label: song.title,
                        tooltip: MelodyTemplate.imported.description,
                        selected: state.melody == MelodyTemplate.imported,
                        onTap: () => widget.controller.selectMelody(
                          MelodyTemplate.imported,
                        ),
                      ),
                    ),
                  for (final melody in melodyChoices)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _PillChoice(
                        label: melody.label,
                        tooltip: melody.description,
                        selected: state.melody == melody,
                        onTap: () => widget.controller.selectMelody(melody),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _songDescription(state),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            PerformanceControls(
              mode: state.performanceMode,
              seconds: state.durationSeconds,
              onMode: widget.controller.selectPerformance,
              onDuration: widget.controller.selectDuration,
            ),
            const _SectionLabel('雰囲気'),
            const SizedBox(height: 8),
            // wraps instead of overflowing with large text
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (style, label) in const [
                  (ArrangementStyle.sparse, 'ぽつぽつ'),
                  (ArrangementStyle.swaying, 'ゆらゆら'),
                  (ArrangementStyle.lively, 'にぎやか'),
                ])
                  _PillChoice(
                    label: label,
                    selected: state.style == style,
                    onTap: () => widget.controller.selectStyle(style),
                  ),
              ],
            ),
            if (path != null ||
                !widget.controller.deferRendering ||
                state.phase == CreationPhase.failed) ...[
              const SizedBox(height: 22),
              Center(
                child: PlaybackChrome(
                  child: SizedBox(
                    width: 200,
                    child: Stack(
                      children: [
                        AspectRatio(
                          aspectRatio: 9 / 16,
                          child: path == null
                              ? state.phase == CreationPhase.failed
                                    ? const _PreviewFailed()
                                    : BeatBuildingPreview(
                                        clips: state.clips,
                                        thumbnails: state.thumbnails,
                                      )
                              : NativeMovieView(
                                  key: ValueKey(
                                    '$path:${state.project?.revision}',
                                  ),
                                  relativePath: path,
                                  gateway: widget.controller.presentation,
                                  controller: playback,
                                  fallback: _SyntheticPreview(clips: state.clips),
                                ),
                        ),
                        if (path != null)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _CompareVideoButton(
                              onPressed: _openComparison,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (state.phase == CreationPhase.rendering ||
                  state.phase == CreationPhase.preparing)
                Column(
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text('${state.durationSeconds}秒のプレビューをつくっています'),
                  ],
                )
              else if (state.phase == CreationPhase.failed)
                Text(
                  'プレビューを作れませんでした。別のアレンジでもう一度お試しください。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else
                _PlaybackControls(playback: playback, label: '曲になった音'),
              if (state.melody != MelodyTemplate.none) ...[
                const SizedBox(height: 12),
                _SongRoleSummary(state: state),
              ],
            ],
            // nothing to vary or adjust before the first song is made
            if (!widget.controller.deferRendering || path != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.controller.another,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('同じ音でもうひとつ作る'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _showAdjustments(context),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text('かんたん調整'),
                    ),
                  ),
                ],
              ),
            ],
            if (state.phase == CreationPhase.failed) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: widget.controller.createPreview,
                child: const Text('プレビューを作り直す'),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: _bottomAction(state),
        ),
      ),
    );
  }

  Future<void> _showAdjustments(BuildContext context) =>
      showAdjustmentsSheet(context, widget.controller);

  /// One line under the songs: what the chosen one is, or whose it is.
  String _songDescription(CreationState state) {
    final song = state.song;
    if (state.melody != MelodyTemplate.imported || song == null) {
      return state.melody.description;
    }
    return [
      if (song.credit.isNotEmpty) song.credit,
      if (song.author case final author?)
        '$authorさんの投稿'
      else
        'MIDIから読み込んだ曲',
    ].join(' · ');
  }

  /// Choose first, then make: つくる until there is a song for the current
  /// choices, then これで完成.
  Widget _bottomAction(CreationState state) {
    final controller = widget.controller;
    final busy =
        state.phase == CreationPhase.preparing ||
        state.phase == CreationPhase.rendering;
    final needsMaking =
        controller.deferRendering &&
        (state.preview == null || state.settingsChanged);
    if (needsMaking) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.settingsChanged) ...[
            const Text(
              '選び直した曲は、つくり直すと反映されます',
              style: TextStyle(fontSize: 12, color: AppTokens.mutedInk),
            ),
            const SizedBox(height: 6),
          ],
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    unawaited(HapticFeedback.selectionClick());
                    unawaited(controller.createPreview());
                  },
            style: FilledButton.styleFrom(
              backgroundColor: AppTokens.ink,
              foregroundColor: Colors.white,
            ),
            child: Text(state.preview == null ? '♪  つくる' : 'この設定でつくり直す'),
          ),
        ],
      );
    }
    return FilledButton(
      onPressed: state.phase == CreationPhase.ready ? controller.complete : null,
      style: FilledButton.styleFrom(
        backgroundColor: AppTokens.coral,
        foregroundColor: AppTokens.ink,
      ),
      child: const Text('これで完成'),
    );
  }
}

/// What is remembered about a finished song while the person looks elsewhere
/// (the 曲 tab): coming back neither replays it nor exports or saves it twice.
final class _FinishedSong {
  _FinishedSong(this.key);

  /// project id and revision
  final String key;
  var revealed = false;
  var saved = false;
  var exportRecorded = false;
  RenderedMedia? fullVideo;
}

class _CompletedScreen extends StatefulWidget {
  const _CompletedScreen({
    required this.controller,
    required this.delivery,
    required this.song,
    required this.onOpenLibrary,
    required this.onClose,
  });
  final CreationController controller;
  final MediaDeliveryGateway? delivery;
  final _FinishedSong song;
  final VoidCallback onOpenLibrary;

  /// Back to Home; the song stays in the library.
  final VoidCallback onClose;

  @override
  State<_CompletedScreen> createState() => _CompletedScreenState();
}

class _CompletedScreenState extends State<_CompletedScreen> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.controller.presentation,
  );
  late final MediaDeliveryGateway delivery =
      widget.delivery ?? PlatformMediaDeliveryGateway();
  String? _exportOperationId;
  bool _busy = false;
  String? _message;
  String? _busyStage;
  var _autoStarted = false;

  @override
  void initState() {
    super.initState();
    // the first look at this song: it is kept as a finished work, and it
    // starts playing by itself
    if (_song.revealed) return;
    _song.revealed = true;
    playback.addListener(_autoPlay);
    unawaited(HapticFeedback.mediumImpact());
    unawaited(_keepAsFinished());
  }

  /// 「オトグラシに保存したよ」 has to be true before anything is shared: from
  /// here on the song is listed as finished, with the video that was just
  /// made, and is no longer brought back as a draft.
  Future<void> _keepAsFinished() async {
    final state = widget.controller.state;
    final project = state.project;
    final preview = state.preview;
    final projects = widget.controller.projects;
    if (project == null ||
        preview == null ||
        projects is! SqliteProjectRepository) {
      return;
    }
    try {
      await projects.recordCompletedExport(
        projectId: project.id,
        sourceRevision: project.revision,
        relativePath: preview.relativePath,
        replacePreviews: true,
      );
    } catch (_) {
      // it can still be saved or shared, which records it as well
    }
  }

  _FinishedSong get _song => widget.song;
  bool get _saved => _song.saved;

  /// The video is as large as the screen allows while the controls and the
  /// row of smaller actions under it still fit without scrolling: about 230
  /// wide on a 844pt phone, never under 180 (then the list scrolls).
  static double _cardWidth(double available) {
    // everything but the video, from the top of the list to under the
    // actions: paddings, title and caption, one row of controls, the tiles
    const rest = 8 + 24 + 10 + 42 + 8 + 48 + 8 + 68 + 6;
    final videoHeight = (available - rest).clamp(320.0, 412.0);
    return videoHeight * 9 / 16 + 24;
  }

  // the reveal: a finished song starts by itself, once
  void _autoPlay() {
    if (_autoStarted || !playback.isReady) return;
    _autoStarted = true;
    playback.removeListener(_autoPlay);
    if (!playback.isPlaying) unawaited(playback.toggle());
  }

  Future<void> _openComparison() async {
    await playback.pause();
    if (!mounted) return;
    final state = widget.controller.state;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ComparisonPlayer(
          songPath: state.preview!.relativePath,
          originalSegments: widget.controller.comparisonSegments,
          presentation: widget.controller.presentation,
          fallback: _SyntheticPreview(clips: state.clips),
        ),
      ),
    );
  }

  Future<RenderedMedia> _ensureFullVideo() async {
    final project = widget.controller.state.project!;
    final song = _song;
    var video = song.fullVideo;
    if (video == null || video.revision != project.revision) {
      final operationId = 'export-${DateTime.now().microsecondsSinceEpoch}';
      _exportOperationId = operationId;
      try {
        video = await widget.controller.media.render(
          RenderRequest(
            operationId: operationId,
            projectId: project.id,
            revision: project.revision,
            arrangement: Arrangement.fromJson(project.arrangement),
            video: VideoRecipe.fromJson(project.videoRecipe),
            quality: RenderQuality.full,
          ),
        );
      } finally {
        if (_exportOperationId == operationId) _exportOperationId = null;
      }
      song.fullVideo = video;
      song.exportRecorded = false;
    }
    final projects = widget.controller.projects;
    if (!song.exportRecorded && projects is SqliteProjectRepository) {
      await projects.recordCompletedExport(
        projectId: project.id,
        sourceRevision: project.revision,
        relativePath: video.relativePath,
        replacePreviews: true,
      );
      song.exportRecorded = true;
    }
    return video;
  }

  Future<void> _save() async {
    if (_busy || _saved) return;
    setState(() {
      _busy = true;
      _message = null;
      _busyStage = '高画質の動画を準備しています';
    });
    try {
      final video = await _ensureFullVideo();
      if (!mounted) return;
      setState(() => _busyStage = '写真に保存しています');
      await delivery.saveToPhotos(video.relativePath);
      if (mounted) {
        setState(() {
          _song.saved = true;
          _message = '写真に保存しました';
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _message = error.code == 'photos_permission_denied'
              ? '写真への追加を許可してください。iPhoneの設定から変更できます。'
              : '保存できませんでした。もう一度お試しください。',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _message = '保存できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyStage = null;
        });
      }
    }
  }

  Future<void> _share() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _busyStage = '高画質の動画を準備しています';
    });
    try {
      final video = await _ensureFullVideo();
      if (!mounted) return;
      setState(() => _busyStage = '共有画面を開いています');
      await delivery.share(video.relativePath);
    } catch (_) {
      if (mounted) setState(() => _message = '共有できませんでした。もう一度お試しください。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyStage = null;
        });
      }
    }
  }

  @override
  void dispose() {
    final exportId = _exportOperationId;
    if (exportId != null) unawaited(widget.controller.media.cancel(exportId));
    playback.removeListener(_autoPlay);
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final canRevise = widget.controller.deferRendering;
    final media = MediaQuery.of(context);
    // what is left for the list between the app bar and the two buttons
    final listHeight =
        media.size.height - media.padding.vertical - kToolbarHeight - 76;
    return Scaffold(
      backgroundColor: AppTokens.surfaceColor,
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onClose,
          tooltip: 'ホーム',
          icon: const Icon(Icons.close_rounded),
        ),
        title: const Text('できあがり'),
        centerTitle: true,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'オトグラシに保存したよ',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppTokens.mutedInk,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Center(
              child: Container(
                width: _cardWidth(listHeight),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTokens.tile,
                  borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        children: [
                          AspectRatio(
                            aspectRatio: 9 / 16,
                            child: NativeMovieView(
                              relativePath: state.preview!.relativePath,
                              gateway: widget.controller.presentation,
                              controller: playback,
                              fallback: _SyntheticPreview(clips: state.clips),
                            ),
                          ),
                          Positioned(
                            top: 8,
                            right: 8,
                            child: _CompareVideoButton(
                              onPressed: _openComparison,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      state.project?.title ?? '今日の音',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppTokens.ink,
                      ),
                    ),
                    Text(
                      '${state.clips.length}つの音 · ${state.durationSeconds}秒 · ${state.songLabel}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTokens.mutedInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            _PlaybackControls(
              playback: playback,
              label: '完成した${state.durationSeconds}秒',
              compact: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _ShareTile(
                  icon: Icons.compare_rounded,
                  label: '元の音と',
                  onTap: _openComparison,
                ),
                if (canRevise) ...[
                  const SizedBox(width: 8),
                  _ShareTile(
                    icon: Icons.tune_rounded,
                    label: 'つくり直す',
                    onTap: _busy ? null : widget.controller.reviseSong,
                  ),
                ],
                const SizedBox(width: 8),
                _ShareTile(
                  icon: Icons.library_music_outlined,
                  label: '作品を見る',
                  onTap: widget.onOpenLibrary,
                ),
                const SizedBox(width: 8),
                _ShareTile(
                  icon: Icons.add_rounded,
                  label: '新しくつくる',
                  onTap: _busy ? null : widget.controller.startNew,
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '映り込みや会話がないか、最後に確認してください。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppTokens.mutedInk),
            ),
          ],
        ),
      ),
      // what people came for stays in reach however small the phone is
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(
                  _busyStage ?? '動画を準備しています',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
              ] else if (_message != null) ...[
                Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _share,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTokens.coral,
                        foregroundColor: AppTokens.ink,
                        minimumSize: const Size(0, 56),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.ios_share_rounded, size: 20),
                      label: const Text('シェアする'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: OutlinedButton.icon(
                      onPressed: _busy || _saved ? null : _save,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 56),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: Icon(
                        _saved ? Icons.check_rounded : Icons.download_rounded,
                        size: 20,
                      ),
                      label: Text(_saved ? '保存済み' : '写真に保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the smaller square actions under a finished song.
final class _ShareTile extends StatelessWidget {
  const _ShareTile({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 160),
          opacity: onTap == null ? 0.45 : 1,
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: AppTokens.tile,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: AppTokens.ink),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppTokens.ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _CompareVideoButton extends StatelessWidget {
  const _CompareVideoButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size(44, 44),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      backgroundColor: AppTokens.paper,
      foregroundColor: AppTokens.ink,
    ),
    icon: const Icon(Icons.open_in_full_rounded, size: 18),
    label: const Text('見くらべる'),
  );
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({
    required this.playback,
    required this.label,
    this.compact = false,
  });

  final MediaPlaybackController playback;
  final String label;

  /// One row (play, position, time) where the screen is short of height.
  final bool compact;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      final durationUs = playback.duration.inMicroseconds.clamp(1, 1 << 53);
      final positionUs = playback.position.inMicroseconds.clamp(0, durationUs);
      final play = IconButton.filledTonal(
        onPressed: playback.isReady ? playback.toggle : null,
        tooltip: playback.isLoading
            ? '動画を読み込み中'
            : playback.isPlaying
            ? '一時停止'
            : '再生',
        icon: Text(
          playback.isPlaying ? 'Ⅱ' : '▶',
          style: const TextStyle(fontSize: 19),
        ),
      );
      final time = Text(
        '${_seconds(playback.position)} / ${_seconds(playback.duration)}',
      );
      final position = Semantics(
        label: '再生位置',
        value: '${playback.position.inSeconds}秒',
        child: Slider(
          value: positionUs.toDouble(),
          max: durationUs.toDouble(),
          onChanged: playback.isReady
              ? (value) => unawaited(
                  playback.seek(Duration(microseconds: value.round())),
                )
              : null,
        ),
      );
      return Column(
        children: [
          if (compact)
            Row(children: [play, Expanded(child: position), time])
          else ...[
            Row(
              children: [
                play,
                const SizedBox(width: 10),
                Expanded(child: Text(label)),
                time,
              ],
            ),
            position,
          ],
          if (playback.error != null)
            Text(
              '再生できませんでした。もう一度お試しください。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );

  static String _seconds(Duration value) =>
      '${value.inSeconds.toString().padLeft(2, '0')}秒';
}

class _PreviewFailed extends StatelessWidget {
  const _PreviewFailed();
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF302D36),
    child: Center(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          '音をつなげられませんでした',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}

class _SyntheticPreview extends StatelessWidget {
  const _SyntheticPreview({required this.clips});
  final List<ClipAsset> clips;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF302D36),
    child: Column(
      children: [
        for (var index = 0; index < 3; index++)
          Expanded(
            child: Container(
              width: double.infinity,
              color: [
                const Color(0xFF8069B2),
                const Color(0xFFCB766D),
                const Color(0xFF63958B),
              ][index],
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(12),
              child: Text(
                clips.elementAtOrNull(index)?.label ?? '合成素材',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _CaptureRoute extends StatefulWidget {
  const _CaptureRoute({
    required this.media,
    required this.presentation,
    required this.fromPhotos,
    required this.recordedClipCount,
    required this.onCommit,
    this.destinations = const [],
    this.initialDestination,
    this.onDestination,
  });
  final MediaGateway media;
  final MediaPresentationGateway presentation;
  final bool fromPhotos;
  final int recordedClipCount;
  final Future<bool> Function(CapturedMedia) onCommit;
  final List<CaptureDestination> destinations;
  final String? initialDestination;
  final ValueChanged<String>? onDestination;

  @override
  State<_CaptureRoute> createState() => _CaptureRouteState();
}

class _CaptureRouteState extends State<_CaptureRoute> {
  late String? _destination = widget.initialDestination;
  bool _committed = false;
  bool _saving = false;
  String? _saveError;
  late final CaptureController controller = CaptureController(
    widget.media,
    operationIdFactory: () =>
        'capture-${DateTime.now().microsecondsSinceEpoch}',
  );

  @override
  void initState() {
    super.initState();
    controller.addListener(_clearStaleSaveError);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startWhenSettled());
  }

  // Starting the camera session mid-transition stalls the UI thread and makes
  // the shutter's flight stutter, so wait until the route has fully arrived.
  void _startWhenSettled() {
    if (!mounted) return;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.isCompleted) {
      _start();
      return;
    }
    void onStatus(AnimationStatus status) {
      if (!status.isCompleted) return;
      animation.removeStatusListener(onStatus);
      if (mounted) _start();
    }

    animation.addStatusListener(onStatus);
  }

  void _start() {
    if (widget.fromPhotos) {
      unawaited(controller.importVideo());
    } else {
      unawaited(controller.prepare());
    }
  }

  @override
  void dispose() {
    controller.removeListener(_clearStaleSaveError);
    final unselected = controller.state.capturedMedia;
    if (!_committed && unselected != null) {
      unawaited(_discardUnselected(unselected.relativePath));
    }
    unawaited(controller.releaseCapture());
    controller.dispose();
    super.dispose();
  }

  void _clearStaleSaveError() {
    if (_saveError != null &&
        controller.state.phase != CapturePhase.completed &&
        mounted) {
      setState(() => _saveError = null);
    }
  }

  Future<void> _discardUnselected(String path) async {
    try {
      await widget.media.discardStaged(path);
    } catch (_) {
      // Leaving this screen should still succeed if staging cleanup fails.
    }
  }

  Future<void> _commit() async {
    final captured = controller.state.capturedMedia;
    if (_saving || captured == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    bool saved;
    try {
      saved = await widget.onCommit(captured);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _saving = false;
        _saveError = '追加できませんでした。もう一度試すか、撮り直してください。';
      });
      return;
    }
    _committed = true;
    setState(() => _saving = false);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: CaptureScreen(
      controller: controller,
      presentation: widget.presentation,
      isAdding: _saving,
      addError: _saveError,
      recordedClipCount: widget.recordedClipCount,
      onMediaReady: () => unawaited(_commit()),
      destinations: widget.destinations,
      destinationId: _destination,
      onDestination: (id) {
        setState(() => _destination = id);
        widget.onDestination?.call(id);
      },
    ),
  );
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.5,
      color: AppTokens.mutedInk,
    ),
  );
}

/// A rounded choice: dark when chosen, pale grey otherwise.
final class _PillChoice extends StatelessWidget {
  const _PillChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    hint: tooltip,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTokens.ink : AppTokens.tile,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: selected ? Colors.white : AppTokens.ink,
          ),
        ),
      ),
    ),
  );
}

/// The sounds this song is made of, as a row of small photos.
final class _UsedSounds extends StatelessWidget {
  const _UsedSounds({
    required this.clips,
    required this.thumbnails,
    required this.onRename,
  });

  final List<ClipAsset> clips;
  final Map<String, Uint8List> thumbnails;
  final VoidCallback onRename;

  static String _name(ClipAsset clip, int index) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$').hasMatch(clip.label)
      ? '音${index + 1}'
      : clip.label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTokens.tile,
      borderRadius: BorderRadius.circular(AppTokens.tileRadius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '使う音',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              '${clips.length}つ',
              style: const TextStyle(fontSize: 11, color: AppTokens.mutedInk),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: onRename,
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 36),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('音の名前をつける'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onRename,
          child: Row(
            children: [
              for (var i = 0; i < 6; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: i < clips.length
                        ? Column(
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Positioned.fill(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(14),
                                        child: thumbnails[clips[i].id] != null
                                            ? Image.memory(
                                                thumbnails[clips[i].id]!,
                                                fit: BoxFit.cover,
                                                errorBuilder:
                                                    (context, error, stack) =>
                                                        ColoredBox(
                                                          color: AppTokens
                                                              .soundColor(i),
                                                        ),
                                              )
                                            : ColoredBox(
                                                color: AppTokens.soundColor(i),
                                              ),
                                      ),
                                    ),
                                    Positioned(
                                      left: -3,
                                      top: -3,
                                      child: Container(
                                        width: 16,
                                        height: 16,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: AppTokens.soundColor(i),
                                          borderRadius: BorderRadius.circular(5),
                                        ),
                                        child: Text(
                                          '${i + 1}',
                                          style: const TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _name(clips[i], i),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
