import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../domain/arrangement.dart';
import '../../domain/arrangement_engine.dart';
import '../../domain/melody_template.dart';
import '../../domain/clip_asset.dart';
import '../../domain/project.dart';
import '../../domain/project_reducer.dart';
import '../../domain/video_recipe.dart';
import '../../features/arrange/render_controller.dart';
import '../../media/media_gateway.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/asset_repository.dart';
import '../../storage/project_repository.dart';
import '../export/media_playback.dart';

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
    this.melody = MelodyTemplate.hop,
    this.layout = VideoLayout.buildUp,
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
  final MelodyTemplate melody;
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
    MelodyTemplate? melody,
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
    melody: melody ?? this.melody,
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

final class _CachedAnalysis {
  const _CachedAnalysis(this.clip, this.request, this.result);

  final ClipAsset clip;
  final MediaAnalysisRequest request;
  final AnalyzedClip result;

  bool matches(ClipAsset candidate, MediaAnalysisRequest selection) =>
      clip.id == candidate.id &&
      clip.relativePath == candidate.relativePath &&
      clip.sha256 == candidate.sha256 &&
      clip.durationUs == candidate.durationUs &&
      request.assetId == selection.assetId &&
      request.relativePath == selection.relativePath &&
      request.selectionStartUs == selection.selectionStartUs &&
      request.selectionDurationUs == selection.selectionDurationUs &&
      request.audioTrackStartUs == selection.audioTrackStartUs;
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
  final Map<String, _CachedAnalysis> _analysisCache = {};
  Timer? _previewRenderTimer;
  var _analysisEpoch = 0;
  var _requestVersion = 0;
  var _disposed = false;

  CreationState get state => _state;

  List<PlaybackSegment> get comparisonSegments => _state.clips
      .map((clip) {
        final request = _analysisRequest(clip);
        return PlaybackSegment(
          relativePath: clip.relativePath,
          startUs: request.selectionStartUs,
          durationUs: request.selectionDurationUs,
        );
      })
      .toList(growable: false);

  Future<void> startDemo() async {
    if (_disposed || _state.phase == CreationPhase.preparing) return;
    ++_requestVersion;
    _clearAnalysisCache();
    _set(_state.copyWith(phase: CreationPhase.preparing, clearError: true));
    try {
      final clips = await demo.install(assets);
      if (_disposed) return;
      var project = await projects.create('合成サンプルの一日');
      if (_disposed) return;
      project = project.copyWith(
        revision: project.revision + 1,
        clipIds: clips.map((clip) => clip.id).toList(),
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(project, expectedRevision: 0);
      if (_disposed) return;
      _set(_state.copyWith(project: project, clips: clips));
      await _loadThumbnails(clips);
      _set(_state.copyWith(phase: CreationPhase.readyToCreate));
    } catch (error) {
      _set(_state.copyWith(phase: CreationPhase.failed, error: error));
    }
  }

  Future<bool> addCaptured(CapturedMedia captured) async {
    if (_disposed) return false;
    try {
      final asset = await assets.importManagedStaging(captured.relativePath);
      final previousCount = _state.clips.length;
      await addExisting(asset);
      final added = _state.clips.length > previousCount;
      if (!added) {
        try {
          await assets.deleteUnreferenced(asset.id);
        } catch (_) {
          // A failed cleanup must not hide the original project error.
        }
        return false;
      }
      try {
        await media.discardStaged(captured.relativePath);
      } catch (_) {
        // The managed staging folder is cleaned on the next launch.
      }
      return true;
    } catch (error) {
      _set(_state.copyWith(phase: CreationPhase.failed, error: error));
      return false;
    }
  }

  Future<void> addExisting(ClipAsset asset) async {
    if (_disposed ||
        _state.clips.length >= 6 ||
        _state.clips.any((clip) => clip.id == asset.id)) {
      return;
    }
    ++_requestVersion;
    _clearAnalysisCache();
    try {
      final current = _state.project ?? await projects.create('今日の音');
      if (_disposed) return;
      final clips = <ClipAsset>[..._state.clips, asset];
      final updated = current.copyWith(
        revision: current.revision + 1,
        clipIds: clips.map((clip) => clip.id).toList(),
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(updated, expectedRevision: current.revision);
      if (_disposed) return;
      _render.open(updated);
      _set(
        _state.copyWith(
          project: updated,
          clips: clips,
          phase: clips.length >= 3
              ? CreationPhase.readyToCreate
              : CreationPhase.collecting,
          clearPreview: true,
          clearError: true,
          compareOriginal: false,
        ),
      );
      await _loadThumbnails(<ClipAsset>[asset]);
    } catch (error) {
      _set(_state.copyWith(phase: CreationPhase.failed, error: error));
    }
  }

  Future<void> openProject(Project project) async {
    if (_disposed) return;
    final version = ++_requestVersion;
    _clearAnalysisCache();
    try {
      final loaded = await Future.wait(project.clipIds.map(assets.load));
      if (_disposed || version != _requestVersion) return;
      final clips = loaded.whereType<ClipAsset>().toList(growable: false);
      _render.open(project);
      _set(
        _state.copyWith(
          project: project,
          clips: clips,
          phase: clips.length >= 3
              ? CreationPhase.readyToCreate
              : CreationPhase.collecting,
          clearPreview: true,
          clearError: true,
          compareOriginal: false,
          style: ArrangementStyle.values.firstWhere(
            (value) => value.name == project.arrangement['style'],
            orElse: () => ArrangementStyle.sparse,
          ),
          melody: MelodyTemplate.values.firstWhere(
            (value) => value.name == project.arrangement['melodyTemplate'],
            orElse: () => MelodyTemplate.none,
          ),
          layout: VideoLayout.values.firstWhere(
            (value) => value.name == project.videoRecipe['layout'],
            orElse: () => VideoLayout.buildUp,
          ),
          seed: project.arrangement['seed'] is int
              ? project.arrangement['seed']! as int
              : 1,
        ),
      );
      await _loadThumbnails(clips);
    } catch (error) {
      if (!_disposed) {
        _set(_state.copyWith(phase: CreationPhase.failed, error: error));
      }
    }
  }

  Future<void> renameClip(String assetId, String label) async {
    if (_disposed || !_state.clips.any((clip) => clip.id == assetId)) return;
    final renamed = await assets.rename(assetId, label);
    if (_disposed) return;
    final project = _state.project;
    Project? updated;
    if (project != null) {
      final recipe = Map<String, Object?>.of(project.videoRecipe);
      final names = <String, String>{
        if (recipe['clipNames'] is Map)
          for (final entry in (recipe['clipNames'] as Map).entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
        assetId: renamed.label,
      };
      recipe['clipNames'] = names;
      updated = project.copyWith(
        revision: project.revision + 1,
        videoRecipe: recipe,
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(updated, expectedRevision: project.revision);
      if (_disposed) return;
      _render.open(updated);
    }
    _set(
      _state.copyWith(
        project: updated,
        clips: _state.clips
            .map((clip) => clip.id == assetId ? renamed : clip)
            .toList(growable: false),
      ),
    );
  }

  void refreshNamedPreview() {
    final project = _state.project;
    if (_disposed ||
        project == null ||
        _state.clips.length < 3 ||
        project.arrangement['events'] is! List ||
        project.videoRecipe['events'] is! List) {
      return;
    }
    _previewRenderTimer?.cancel();
    _set(_state.copyWith(phase: CreationPhase.rendering, clearError: true));
    _render.open(project);
    _render.generate(RenderQuality.preview);
  }

  void selectStyle(ArrangementStyle style) {
    if (_disposed) return;
    _set(_state.copyWith(style: style, compareOriginal: false));
    unawaited(_requestArrangement(style: style, seed: _state.seed));
  }

  void selectMelody(MelodyTemplate melody) {
    if (_disposed || melody == _state.melody) return;
    _previewRenderTimer?.cancel();
    final project = _state.project;
    if (project != null) _render.open(project);
    _set(
      _state.copyWith(
        melody: melody,
        compareOriginal: false,
        phase: CreationPhase.preparing,
        clearPreview: true,
        clearError: true,
      ),
    );
    unawaited(
      _requestArrangement(
        style: _state.style,
        seed: _state.seed,
        debouncePreview: true,
      ),
    );
  }

  Future<void> createPreview() => _disposed
      ? Future<void>.value()
      : _requestArrangement(style: _state.style, seed: _state.seed);

  void another() {
    if (_disposed) return;
    final seed = _state.seed + 1;
    _set(_state.copyWith(seed: seed, compareOriginal: false));
    unawaited(_requestArrangement(style: _state.style, seed: seed));
  }

  void setLayout(VideoLayout layout) {
    if (_disposed) return;
    _set(_state.copyWith(layout: layout));
    unawaited(_requestArrangement(style: _state.style, seed: _state.seed));
  }

  void setCompareOriginal(bool value) =>
      _disposed ? null : _set(_state.copyWith(compareOriginal: value));

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (_disposed) return;
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
    if (_disposed) return;
    _set(_state.copyWith(project: updated, clips: clips));
    await _requestArrangement(style: _state.style, seed: _state.seed);
  }

  Future<void> removeClip(String assetId) async {
    if (_disposed || !_state.clips.any((clip) => clip.id == assetId)) return;
    final current = _state.project;
    if (current == null) return;
    ++_requestVersion;
    _clearAnalysisCache();
    try {
      final clips = _state.clips
          .where((clip) => clip.id != assetId)
          .toList(growable: false);
      final updated = current.copyWith(
        revision: current.revision + 1,
        clipIds: clips.map((clip) => clip.id).toList(),
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(updated, expectedRevision: current.revision);
      if (_disposed) return;
      _render.open(updated);
      final thumbnails = Map<String, Uint8List>.of(_state.thumbnails)
        ..remove(assetId);
      _set(
        _state.copyWith(
          project: updated,
          clips: clips,
          thumbnails: thumbnails,
          phase: clips.length >= 3
              ? CreationPhase.readyToCreate
              : CreationPhase.collecting,
          clearPreview: true,
          clearError: true,
          compareOriginal: false,
        ),
      );
    } catch (error) {
      if (!_disposed) {
        _set(_state.copyWith(phase: CreationPhase.failed, error: error));
      }
    }
  }

  void editClips() {
    if (_disposed) return;
    ++_requestVersion;
    final project = _state.project;
    if (project != null) _render.open(project);
    _set(
      _state.copyWith(
        phase: _state.clips.length >= 3
            ? CreationPhase.readyToCreate
            : CreationPhase.collecting,
        clearPreview: true,
        clearError: true,
        compareOriginal: false,
      ),
    );
  }

  void startNew() {
    if (_disposed) return;
    ++_requestVersion;
    _clearAnalysisCache();
    final project = _state.project;
    if (project != null) _render.open(project);
    _set(const CreationState());
  }

  Future<void> renameProject(String title) => _applyEdit(RenameProject(title));

  Future<void> setGain(String assetId, double gain) =>
      _applyEdit(SetGain(assetId, gain));

  Future<void> setAccompanimentGain(double gain) =>
      _applyEdit(SetAccompanimentGain(gain));

  Future<void> setCaption(
    String text, {
    int index = 0,
    double x = .5,
    double y = .9,
    int destinationStartSample = 0,
    int durationSamples = 720000,
  }) => _applyEdit(
    SetCaption(
      text,
      index: index,
      x: x,
      y: y,
      destinationStartSample: destinationStartSample,
      durationSamples: durationSamples,
    ),
  );

  Future<void> removeCaption(int index) => _applyEdit(RemoveCaption(index));

  Future<void> setCrop(String assetId, NormalizedCrop crop) =>
      _applyEdit(SetCrop(assetId, crop));

  Future<void> setTrim(String assetId, int startUs, int durationUs) =>
      _applyEdit(SetTrim(assetId, startUs, durationUs));

  Future<Project?> duplicateProject({String? title}) async {
    final current = _state.project;
    if (_disposed || current == null) return null;
    if (projects is! SqliteProjectRepository) return null;
    return (projects as SqliteProjectRepository).duplicateProject(
      current.id,
      title: title,
    );
  }

  Future<void> _applyEdit(ProjectEditCommand command) async {
    if (_disposed) return;
    ++_requestVersion;
    final current = _state.project;
    if (current == null) return;
    if (command is SetTrim) _invalidateAnalysis(command.assetId);
    try {
      final updated = ProjectReducer.reduce(current, command);
      await projects.save(updated, expectedRevision: current.revision);
      if (_disposed) return;
      _set(_state.copyWith(project: updated, clearError: true));
      if (_state.clips.length >= 3) {
        await _requestArrangement(style: _state.style, seed: _state.seed);
      }
    } catch (error) {
      if (!_disposed) {
        _set(_state.copyWith(phase: CreationPhase.failed, error: error));
      }
    }
  }

  void complete() {
    if (!_disposed &&
        _state.phase == CreationPhase.ready &&
        _state.preview != null) {
      _set(_state.copyWith(phase: CreationPhase.completed));
    }
  }

  Future<void> _requestArrangement({
    required ArrangementStyle style,
    required int seed,
    bool debouncePreview = false,
  }) {
    if (_disposed) return Future<void>.value();
    _previewRenderTimer?.cancel();
    final version = ++_requestVersion;
    final work = _mutationTail.then(
      (_) => _arrange(version, style, seed, debouncePreview),
    );
    _mutationTail = work.catchError((Object _) {});
    return work;
  }

  Future<void> _arrange(
    int version,
    ArrangementStyle style,
    int seed,
    bool debouncePreview,
  ) async {
    if (_disposed || version != _requestVersion) return;
    final project = _state.project;
    if (project == null || _state.clips.length < 3) return;
    _set(
      _state.copyWith(
        phase: CreationPhase.preparing,
        clearPreview: true,
        clearError: true,
      ),
    );
    try {
      final analysisEpoch = _analysisEpoch;
      final analyses = await Future.wait([
        for (final clip in _state.clips)
          _analyzeCached(clip, _analysisRequest(clip), analysisEpoch),
      ]);
      if (_disposed || version != _requestVersion) return;
      final arrangement = arrange(
        clips: analyses,
        style: style,
        seed: seed,
        melodyTemplate: _state.melody,
      );
      final arrangementJson = _applyArrangementEdits(
        arrangement.toJson(),
        project.arrangement,
      );
      final recipe = VideoRecipe.fromArrangement(
        arrangement: arrangement,
        layout: _state.layout,
      );
      final recipeJson = _preserveRecipeEdits(
        recipe.toJson(),
        project.videoRecipe,
      );
      final updated = project.copyWith(
        revision: project.revision + 1,
        arrangement: arrangementJson,
        videoRecipe: recipeJson,
        updatedAt: DateTime.now().toUtc(),
      );
      await projects.save(updated, expectedRevision: project.revision);
      if (_disposed) return;
      if (version != _requestVersion) {
        // The saved revision still has to reach state before the queued choice
        // can save its own revision against the repository.
        if (_state.project?.id == project.id &&
            _state.project?.revision == project.revision) {
          _set(_state.copyWith(project: updated));
        }
        return;
      }
      _set(
        _state.copyWith(
          phase: CreationPhase.rendering,
          project: updated,
          clearPreview: true,
        ),
      );
      _render.open(updated);
      if (debouncePreview) {
        // Rendering a full 15-second movie for every quick choice is expensive.
        // The saved arrangement and its video recipe remain paired while the
        // short pause lets the next choice replace this render.
        _previewRenderTimer = Timer(const Duration(milliseconds: 180), () {
          if (!_disposed &&
              version == _requestVersion &&
              _state.project?.revision == updated.revision) {
            _render.generate(RenderQuality.preview);
          }
        });
      } else {
        _render.generate(RenderQuality.preview);
      }
    } catch (error) {
      if (!_disposed && version == _requestVersion) {
        _set(_state.copyWith(phase: CreationPhase.failed, error: error));
      }
    }
  }

  Map<String, Object?> _applyArrangementEdits(
    Map<String, Object?> generated,
    Map<String, Object?> previous,
  ) {
    final result = Map<String, Object?>.of(generated);
    final previousEdits = previous['edits'];
    if (previousEdits is Map) result['edits'] = _copyJson(previousEdits);
    final previousAccompaniment = previous['accompanimentGain'];
    if (previousAccompaniment is num) {
      result['accompanimentGain'] = previousAccompaniment.toDouble();
    }
    final gains = previousEdits is Map ? previousEdits['gains'] : null;
    if (gains is Map) {
      final events = (result['events'] as List<Object?>)
          .map(
            (value) => (value as Map).map<String, Object?>(
              (key, value) => MapEntry('$key', value),
            ),
          )
          .toList(growable: false);
      for (final event in events) {
        final gain = gains[event['assetId']];
        if (gain is num) event['gain'] = gain.toDouble();
      }
      result['events'] = events;
    }
    return result;
  }

  Map<String, Object?> _preserveRecipeEdits(
    Map<String, Object?> generated,
    Map<String, Object?> previous,
  ) {
    final result = Map<String, Object?>.of(generated);
    final captions = previous['captions'];
    final crops = previous['clipCrops'];
    final clipNames = previous['clipNames'];
    if (captions is List) result['captions'] = _copyJson(captions);
    if (clipNames is Map) {
      final validIds = (generated['clipCrops'] as List<Object?>)
          .map((crop) => (crop as Map)['assetId'])
          .toSet();
      result['clipNames'] = <String, String>{
        for (final entry in clipNames.entries)
          if (entry.key is String &&
              entry.value is String &&
              validIds.contains(entry.key))
            entry.key as String: entry.value as String,
      };
    }
    if (crops is List) {
      final previousById = <String, Object?>{
        for (final crop in crops)
          if (crop is Map && crop['assetId'] is String)
            crop['assetId'] as String: crop,
      };
      result['clipCrops'] = [
        for (final crop in generated['clipCrops'] as List<Object?>)
          _copyJson(previousById[(crop as Map)['assetId']] ?? crop),
      ];
    }
    return result;
  }

  Object? _copyJson(Object? value) {
    if (value is Map) {
      return value.map<String, Object?>(
        (key, value) => MapEntry('$key', _copyJson(value)),
      );
    }
    if (value is List) return value.map(_copyJson).toList(growable: true);
    return value;
  }

  MediaAnalysisRequest _analysisRequest(ClipAsset clip) {
    final edits = _state.project?.arrangement['edits'];
    final windows = edits is Map ? edits['sourceWindows'] : null;
    final value = windows is Map ? windows[clip.id] : null;
    final window = value is Map ? value : null;
    final start = window?['startUs'];
    final duration = window?['durationUs'];
    if (start is! int || duration is! int || start < 0 || duration <= 0) {
      return MediaAnalysisRequest.forAsset(clip);
    }
    if (start >= clip.durationUs) return MediaAnalysisRequest.forAsset(clip);
    final boundedDuration = duration.clamp(1, clip.durationUs - start);
    return MediaAnalysisRequest(
      assetId: clip.id,
      relativePath: clip.relativePath,
      selectionStartUs: start,
      selectionDurationUs: boundedDuration,
      audioTrackStartUs: clip.audioTrackStartUs,
    );
  }

  Future<AnalyzedClip> _analyzeCached(
    ClipAsset clip,
    MediaAnalysisRequest request,
    int epoch,
  ) async {
    final cached = _analysisCache[clip.id];
    if (cached != null && cached.matches(clip, request)) return cached.result;

    final result = await media.analyze(request);
    // A superseded theme request may still reuse its analysis. Source edits and
    // project changes advance the epoch so an old response cannot refill it.
    if (!_disposed && epoch == _analysisEpoch && result.assetId == clip.id) {
      _analysisCache[clip.id] = _CachedAnalysis(clip, request, result);
    }
    return result;
  }

  void _clearAnalysisCache() {
    ++_analysisEpoch;
    _analysisCache.clear();
  }

  void _invalidateAnalysis(String assetId) {
    ++_analysisEpoch;
    _analysisCache.remove(assetId);
  }

  Future<void> _loadThumbnails(List<ClipAsset> clips) async {
    if (_disposed) return;
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
    if (!_disposed) _set(_state.copyWith(thumbnails: thumbnails));
  }

  void _onRenderState() {
    if (_disposed) return;
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
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _previewRenderTimer?.cancel();
    _clearAnalysisCache();
    _render
      ..removeListener(_onRenderState)
      ..dispose();
    super.dispose();
  }
}
