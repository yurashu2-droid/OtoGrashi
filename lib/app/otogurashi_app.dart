import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:otogurashi/design/tokens.dart';

import '../domain/project.dart';
import '../features/create/creation_controller.dart';
import '../features/create/creation_flow.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../storage/project_repository.dart';
import 'app_dependencies.dart';

typedef DependenciesLoader = Future<AppDependencies> Function();

class OtogurashiApp extends StatelessWidget {
  const OtogurashiApp({this.dependenciesLoader, super.key});

  final DependenciesLoader? dependenciesLoader;

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
      ),
    );
  }
}

class _CreationHost extends StatefulWidget {
  const _CreationHost({required this.dependenciesLoader});
  final DependenciesLoader dependenciesLoader;

  @override
  State<_CreationHost> createState() => _CreationHostState();
}

class _CreationHostState extends State<_CreationHost> {
  AppDependencies? _dependencies;
  CreationController? _controller;
  bool _busy = true;
  bool _showOnboarding = true;
  bool _startWithCapture = false;
  bool _startInLibrary = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
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
      );
      final projects = resume
          ? await dependencies.projects.list()
          : const <Project>[];
      final exports = resume && dependencies.projects is SqliteProjectRepository
          ? await (dependencies.projects as SqliteProjectRepository)
                .listCompletedExports()
          : const <CompletedExport>[];
      final project = _recentUnfinishedProject(projects, exports);
      if (project != null) await controller.openProject(project);
      if (!mounted) {
        controller.dispose();
        dependencies.close();
        return;
      }
      setState(() {
        _dependencies = dependencies;
        _controller = controller;
        _showOnboarding = resume && projects.isEmpty;
        _startWithCapture = !resume;
        _startInLibrary = resume && project == null && projects.isNotEmpty;
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

  Project? _recentUnfinishedProject(
    List<Project> projects,
    List<CompletedExport> exports,
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
    return unfinished.firstOrNull;
  }

  void _begin() {
    if (_busy) return;
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

  @override
  void dispose() {
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
      );
    }
    return OnboardingScreen(
      busy: _busy,
      error: _error == null ? null : '準備できませんでした。もう一度お試しください。',
      onCreate: _begin,
    );
  }
}
