import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:app_links/app_links.dart';

import 'package:otogurashi/design/tokens.dart';

import '../domain/arrangement.dart';
import '../domain/melody_template.dart';
import '../domain/project.dart';
import '../features/create/creation_controller.dart';
import '../features/create/creation_flow.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/songs/midi_song_reader.dart';
import '../features/songs/song_library.dart';
import '../media/midi_file_picker.dart';
import '../storage/profile_store.dart';
import '../storage/project_repository.dart';
import '../sharing/shared_folder_service.dart';
import '../sharing/song_catalog.dart';
import 'app_dependencies.dart';

typedef DependenciesLoader = Future<AppDependencies> Function();

class OtogurashiApp extends StatelessWidget {
  const OtogurashiApp({
    this.dependenciesLoader,
    this.invitationLinks,
    super.key,
  });

  final DependenciesLoader? dependenciesLoader;
  final Stream<Uri>? invitationLinks;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'オトグラシ',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ja'),
      supportedLocales: const [Locale('ja')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildOtogurashiTheme(),
      home: _CreationHost(
        dependenciesLoader: dependenciesLoader ?? AppDependencies.bootstrap,
        invitationLinks: invitationLinks,
        enableAppLinks: dependenciesLoader == null,
      ),
    );
  }
}

class _CreationHost extends StatefulWidget {
  const _CreationHost({
    required this.dependenciesLoader,
    required this.enableAppLinks,
    this.invitationLinks,
  });
  final DependenciesLoader dependenciesLoader;
  final bool enableAppLinks;
  final Stream<Uri>? invitationLinks;

  @override
  State<_CreationHost> createState() => _CreationHostState();
}

class _CreationHostState extends State<_CreationHost> {
  AppDependencies? _dependencies;
  CreationController? _controller;
  SongLibrary? _songLibrary;
  bool _busy = true;
  bool _showOnboarding = true;
  bool _startWithCapture = false;
  bool _startInLibrary = false;
  String? _ownerName;
  Object? _error;
  StreamSubscription<Uri>? _invitationSubscription;
  String? _pendingInvitation;

  @override
  void initState() {
    super.initState();
    final links =
        widget.invitationLinks ??
        (widget.enableAppLinks ? AppLinks().uriLinkStream : null);
    _invitationSubscription = links?.listen((uri) {
      if (uri.scheme != 'otograshi' || uri.host != 'invite') return;
      final invitation = uri.queryParameters['url'];
      if (invitation == null || !mounted) return;
      try {
        SharedInvitation.parse(invitation);
        setState(() => _pendingInvitation = invitation);
      } on FormatException {
        // Ignore malformed links; valid invitations are presented, never auto-joined.
      }
    }, onError: (Object _) {});
    unawaited(_load(resume: true));
  }

  Future<void> _load({required bool resume}) async {
    if (!resume) setState(() => _busy = true);
    AppDependencies? dependencies;
    CreationController? controller;
    try {
      dependencies = await widget.dependenciesLoader();
      controller = CreationController(
        projects: dependencies.projects,
        assets: dependencies.assets,
        media: dependencies.media,
        presentation: dependencies.presentation,
        demo: BundledDemoAssetSource(
          stagingDirectory: dependencies.database.stagingDirectory,
        ),
        // choose first, then make: nothing renders until つくる is pressed
        deferRendering: true,
        // a first song should already sound like one: the recommended form,
        // playing a tune everyone knows
        defaultPerformanceMode: PerformanceMode.mad,
        defaultMelody: MelodyTemplate.odeToJoy,
      );
      final projects = resume
          ? await dependencies.projects.list()
          : const <Project>[];
      final exports = resume && dependencies.projects is SqliteProjectRepository
          ? await (dependencies.projects as SqliteProjectRepository)
                .listCompletedExports()
          : const <CompletedExport>[];
      final ownerName = await dependencies.profile?.loadName();
      controller.ownerName = ownerName;
      final remembered = await dependencies.draft?.load();
      final project = _draftToResume(projects, exports, remembered);
      if (project != null) await controller.openProject(project);
      _watchDraft(controller, dependencies);
      if (!mounted) {
        controller.dispose();
        dependencies.close();
        return;
      }
      final songs = dependencies.songs;
      final sharing = dependencies.sharedFolders;
      final songLibrary = songs == null
          ? null
          : SongLibrary(
              songs: songs,
              catalog: sharing == null ? null : ServerSongCatalog(sharing),
              picker: const PlatformMidiFilePicker(),
              reader: readMidiSong,
              signIn: sharing == null
                  ? null
                  : () async {
                      await sharing.signIn();
                    },
            );
      setState(() {
        _dependencies = dependencies;
        _controller = controller;
        _songLibrary = songLibrary;
        _showOnboarding = resume && projects.isEmpty;
        _startWithCapture = !resume;
        _startInLibrary = resume && project == null && projects.isNotEmpty;
        _ownerName = ownerName;
        _busy = false;
        _error = null;
      });
    } catch (error) {
      controller?.dispose();
      dependencies?.close();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  /// The song to continue: the one that was in progress last time. Before
  /// anything has been remembered ([remembered] null) it is the newest
  /// unfinished song, as it always was.
  Project? _draftToResume(
    List<Project> projects,
    List<CompletedExport> exports,
    String? remembered,
  ) {
    final unfinished =
        projects
            .where(
              (project) =>
                  project.clipIds.isNotEmpty &&
                  !exports.any(
                    (export) =>
                        export.projectId == project.id &&
                        export.sourceRevision == project.revision,
                  ),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (remembered == null) return unfinished.firstOrNull;
    return unfinished.where((project) => project.id == remembered).firstOrNull;
  }

  /// Keeps the remembered song in step with what the person is working on.
  void _watchDraft(CreationController controller, AppDependencies dependencies) {
    final pointer = dependencies.draft;
    if (pointer == null) return;
    String? current() {
      final state = controller.state;
      // a finished song is not a draft; nor is one without sounds
      return state.phase == CreationPhase.completed || state.clips.isEmpty
          ? null
          : state.project?.id;
    }

    var saved = current();
    unawaited(pointer.save(saved));
    controller.addListener(() {
      final now = current();
      if (now == saved) return;
      saved = now;
      unawaited(pointer.save(now));
    });
  }

  void _begin(String name) {
    if (_busy) return;
    final profile = _dependencies?.profile;
    final cleaned = profile == null ? null : ProfileStore.clean(name);
    _ownerName = cleaned;
    _controller?.ownerName = cleaned;
    if (profile != null) unawaited(profile.saveName(name));
    if (_controller != null && _dependencies != null) {
      setState(() {
        _showOnboarding = false;
        _startWithCapture = true;
        _startInLibrary = false;
      });
    } else {
      unawaited(_load(resume: false));
    }
  }

  /// The name edited in Settings; returns it as stored (null when cleared).
  Future<String?> _rename(String name) async {
    final profile = _dependencies?.profile;
    final saved = profile == null
        ? ProfileStore.clean(name)
        : await profile.saveName(name);
    _ownerName = saved;
    return saved;
  }

  @override
  void dispose() {
    unawaited(_invitationSubscription?.cancel());
    _songLibrary?.dispose();
    _controller?.dispose();
    _dependencies?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final dependencies = _dependencies;
    if (!_showOnboarding && controller != null && dependencies != null) {
      return CreationFlow(
        controller: controller,
        media: dependencies.media,
        startWithCapture: _startWithCapture,
        startInLibrary: _startInLibrary,
        folders: dependencies.folders,
        sharedFolders: dependencies.sharedFolders,
        pendingInvitation: _pendingInvitation,
        onInvitationOpened: (invitation) {
          if (_pendingInvitation == invitation) {
            setState(() => _pendingInvitation = null);
          }
        },
        startAtHome: true,
        onOwnerName: _rename,
        songLibrary: _songLibrary,
      );
    }
    return OnboardingScreen(
      busy: _busy,
      error: _error == null ? null : '準備できませんでした。もう一度お試しください。',
      initialName: _ownerName,
      onCreate: _begin,
    );
  }
}
