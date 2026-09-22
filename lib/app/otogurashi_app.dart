import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:otogurashi/design/tokens.dart';

import '../features/create/creation_controller.dart';
import '../features/create/creation_flow.dart';
import '../features/onboarding/onboarding_screen.dart';
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
  bool _busy = false;
  bool _startWithCapture = false;
  Object? _error;

  Future<void> _begin({required bool sample}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final dependencies = await widget.dependenciesLoader();
      final controller = CreationController(
        projects: dependencies.projects,
        assets: dependencies.assets,
        media: dependencies.media,
        presentation: dependencies.presentation,
        demo: BundledDemoAssetSource(
          stagingDirectory: dependencies.database.stagingDirectory,
        ),
      );
      if (sample) await controller.startDemo();
      if (!mounted) {
        controller.dispose();
        dependencies.close();
        return;
      }
      setState(() {
        _dependencies = dependencies;
        _controller = controller;
        _startWithCapture = !sample;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
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
    if (controller != null && dependencies != null) {
      return CreationFlow(
        controller: controller,
        media: dependencies.media,
        startWithCapture: _startWithCapture,
      );
    }
    return OnboardingScreen(
      busy: _busy,
      error: _error == null ? null : '準備できませんでした。もう一度お試しください。',
      onTrySample: () => _begin(sample: true),
      onCreate: () => _begin(sample: false),
    );
  }
}
