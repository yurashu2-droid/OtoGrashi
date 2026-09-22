import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/arrangement.dart';
import '../../domain/arrangement_engine.dart';
import '../../domain/clip_asset.dart';
import '../../domain/project.dart';
import '../../domain/video_recipe.dart';
import '../../features/arrange/render_controller.dart';
import '../../media/media_gateway.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import '../../storage/project_repository.dart';

enum CreationPhase {
  collecting,
  preparing,
  readyToCreate,
  rendering,
  ready,
  completed,
  failed,
}

final class CreationState {
  const CreationState({
    this.phase = CreationPhase.collecting,
    this.project,
    this.clips = const <ClipAsset>[],
    this.thumbnails = const <String, Uint8List>{},
    this.style = ArrangementStyle.sparse,
    this.layout = VideoLayout.stacked,
    this.compareOriginal = false,
    this.seed = 1,
    this.preview,
    this.error,
  });

  final CreationPhase phase;
  final Project? project;
  final List<ClipAsset> clips;
  final Map<String, Uint8List> thumbnails;
  final ArrangementStyle style;
  final VideoLayout layout;
  final bool compareOriginal;
  final int seed;
  final RenderedMedia? preview;
  final Object? error;

  CreationState copyWith({
    CreationPhase? phase,
    Project? project,
    List<ClipAsset>? clips,
    Map<String, Uint8List>? thumbnails,
    ArrangementStyle? style,
    VideoLayout? layout,
    bool? compareOriginal,
    int? seed,
    RenderedMedia? preview,
    bool clearPreview = false,
    Object? error,
    bool clearError = false,
  }) => CreationState(
    phase: phase ?? this.phase,
    project: project ?? this.project,
    clips: clips ?? this.clips,
    thumbnails: thumbnails ?? this.thumbnails,
    style: style ?? this.style,
    layout: layout ?? this.layout,
    compareOriginal: compareOriginal ?? this.compareOriginal,
    seed: seed ?? this.seed,
    preview: clearPreview ? null : preview ?? this.preview,
    error: clearError ? null : error ?? this.error,
  );
}

abstract interface class DemoAssetSource {
  Future<List<ClipAsset>> install(AssetRepository repository);
}

final class BundledDemoAssetSource implements DemoAssetSource {
  const BundledDemoAssetSource({required this.stagingDirectory, this.bundle});

  final Directory stagingDirectory;
  final AssetBundle? bundle;

  static const paths = <String>[
    'assets/demo/source/synthetic-tap.mp4',
    'assets/demo/source/synthetic-sustain.mp4',
    'assets/demo/source/synthetic-texture.mp4',
  ];

  @override
  Future<List<ClipAsset>> install(AssetRepository repository) async {
    final sourceBundle = bundle ?? rootBundle;
    final installed = <ClipAsset>[];
    for (final assetPath in paths) {
      final data = await sourceBundle.load(assetPath);
      final target = File(p.join(stagingDirectory.path, p.basename(assetPath)));
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
      installed.add(await repository.importFile(target.path));
      if (await target.exists()) await target.delete();
    }
    return installed;
  }
}

final class CreationController extends ChangeNotifier {
  CreationController({
    required this.projects,
    required this.assets,
    required this.media,
    required this.presentation,
    required this.demo,
    Iterator<String>? renderOperationIds,
  }) : _render = RenderController(
         gateway: media,
         operationIds: renderOperationIds,
       ) {
    _render.addListener(_onRenderState);
  }

  final ProjectRepository projects;
  final AssetRepository assets;
  final MediaGateway media;
  final MediaPresentationGateway presentation;
  final DemoAssetSource demo;
  final RenderController _render;
  CreationState _state = const CreationState();
  Future<void> _mutationTail = Future<void>.value();
  var _requestVersion = 0;

  CreationState get state => _state;

  Future<void> startDemo() async {
    if (_state.phase == CreationPhase.preparing) return;
    _set(_state.copyWith(phase: CreationPhase.preparing, clearError: true));
    try {
      final clips = await demo.install(assets);
      var project = await projects.create('合成サンプルの一日');
      project = project.copyWith(
        revision: project.revision + 1,
        clipIds: clips.map((clip) => clip.id).toList(),
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(project, expectedRevision: 0);
      _set(_state.copyWith(project: project, clips: clips));
      await _loadThumbnails(clips);
      _set(_state.copyWith(phase: CreationPhase.readyToCreate));
    } catch (error) {
      _set(_state.copyWith(phase: CreationPhase.failed, error: error));
    }
  }

  Future<void> addCaptured(CapturedMedia captured) async {
    try {
      final asset = await assets.importManagedStaging(captured.relativePath);
      final current = _state.project ?? await projects.create('今日の音');
      final clips = <ClipAsset>[..._state.clips, asset];
      final updated = current.copyWith(
        revision: current.revision + 1,
        clipIds: clips.map((clip) => clip.id).toList(),
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(updated, expectedRevision: current.revision);
      _set(_state.copyWith(project: updated, clips: clips));
      await _loadThumbnails(<ClipAsset>[asset]);
      if (clips.length >= 3) {
        _set(_state.copyWith(phase: CreationPhase.readyToCreate));
      }
    } catch (error) {
      _set(_state.copyWith(phase: CreationPhase.failed, error: error));
    }
  }

  void selectStyle(ArrangementStyle style) {
    _set(_state.copyWith(style: style, compareOriginal: false));
    unawaited(_requestArrangement(style: style, seed: _state.seed));
  }

  Future<void> createPreview() =>
      _requestArrangement(style: _state.style, seed: _state.seed);

  void another() {
    final seed = _state.seed + 1;
    _set(_state.copyWith(seed: seed, compareOriginal: false));
    unawaited(_requestArrangement(style: _state.style, seed: seed));
  }

  void setLayout(VideoLayout layout) {
    _set(_state.copyWith(layout: layout));
    unawaited(_requestArrangement(style: _state.style, seed: _state.seed));
  }

  void setCompareOriginal(bool value) =>
      _set(_state.copyWith(compareOriginal: value));

  Future<void> reorder(int oldIndex, int newIndex) async {
    final clips = [..._state.clips];
    final moved = clips.removeAt(oldIndex);
    clips.insert(newIndex, moved);
    final current = _state.project;
    if (current == null) return;
    final updated = current.copyWith(
      revision: current.revision + 1,
      clipIds: clips.map((clip) => clip.id).toList(),
      updatedAt: DateTime.now().toUtc(),
    );
    await projects.save(updated, expectedRevision: current.revision);
    _set(_state.copyWith(project: updated, clips: clips));
    await _requestArrangement(style: _state.style, seed: _state.seed);
  }

  void complete() {
    if (_state.phase == CreationPhase.ready && _state.preview != null) {
      _set(_state.copyWith(phase: CreationPhase.completed));
    }
  }

  Future<void> _requestArrangement({
    required ArrangementStyle style,
    required int seed,
  }) {
    final version = ++_requestVersion;
    final work = _mutationTail.then((_) => _arrange(version, style, seed));
    _mutationTail = work.catchError((Object _) {});
    return work;
  }

  Future<void> _arrange(int version, ArrangementStyle style, int seed) async {
    if (version != _requestVersion) return;
    final project = _state.project;
    if (project == null || _state.clips.length < 3) return;
    _set(_state.copyWith(phase: CreationPhase.preparing, clearError: true));
    try {
      final analyses = await Future.wait(
        _state.clips.map(
          (clip) => media.analyze(MediaAnalysisRequest.forAsset(clip)),
        ),
      );
      if (version != _requestVersion) return;
      final arrangement = arrange(clips: analyses, style: style, seed: seed);
      final recipe = VideoRecipe.fromArrangement(
        arrangement: arrangement,
        layout: _state.layout,
      );
      final updated = project.copyWith(
        revision: project.revision + 1,
        arrangement: arrangement.toJson(),
        videoRecipe: recipe.toJson(),
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(updated, expectedRevision: project.revision);
      if (version != _requestVersion) return;
      _set(
        _state.copyWith(
          phase: CreationPhase.rendering,
          project: updated,
          clearPreview: true,
        ),
      );
      _render.open(updated);
      _render.generate(RenderQuality.preview);
    } catch (error) {
      if (version == _requestVersion) {
        _set(_state.copyWith(phase: CreationPhase.failed, error: error));
      }
    }
  }

  Future<void> _loadThumbnails(List<ClipAsset> clips) async {
    final thumbnails = Map<String, Uint8List>.of(_state.thumbnails);
    await Future.wait(
      clips.map((clip) async {
        try {
          thumbnails[clip.id] = await presentation.thumbnail(clip.relativePath);
        } catch (_) {
          // The UI retains a labelled fallback and the endpoint stays retryable.
        }
      }),
    );
    _set(_state.copyWith(thumbnails: thumbnails));
  }

  void _onRenderState() {
    final render = _render.state;
    switch (render.phase) {
      case RenderPhase.ready:
        _set(
          _state.copyWith(
            phase: CreationPhase.ready,
            preview: render.readyMedia,
            clearError: true,
          ),
        );
      case RenderPhase.failed:
        _set(_state.copyWith(phase: CreationPhase.failed, error: render.error));
      case RenderPhase.idle:
      case RenderPhase.rendering:
      case RenderPhase.cancelled:
        break;
    }
  }

  void _set(CreationState value) {
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _render
      ..removeListener(_onRenderState)
      ..dispose();
    super.dispose();
  }
}
