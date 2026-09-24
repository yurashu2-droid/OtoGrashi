import '../domain/clip_asset.dart';

enum SuggestedRole { transient, sustain, texture }

enum RenderQuality { preview, full }

enum MediaEventType { recording, progress, completed, interrupted, failed }

enum CameraFacing { back, front }

enum MediaCaptureErrorCode {
  permissionDenied,
  unavailable,
  interrupted,
  incompleteCapture,
  noAudio,
  tooShort,
  invalidMedia,
  cancelled,
}

final class MediaCaptureException implements Exception {
  const MediaCaptureException(this.code, this.message);

  final MediaCaptureErrorCode code;
  final String message;

  @override
  String toString() => 'MediaCaptureException(${code.name}): $message';
}

final class CaptureHandle {
  const CaptureHandle({
    required this.previewViewType,
    this.cameraFacing = CameraFacing.back,
  });

  factory CaptureHandle.fromJson(Map<String, Object?> json) {
    try {
      return CaptureHandle(
        previewViewType: json['previewViewType'] as String,
        cameraFacing: CameraFacing.values.byName(
          (json['cameraFacing'] as String?) ?? CameraFacing.back.name,
        ),
      );
    } on TypeError {
      throw const MediaContractException('Malformed capture handle.');
    }
  }

  final String previewViewType;
  final CameraFacing cameraFacing;
}

class InspectedMedia {
  InspectedMedia({
    required this.durationUs,
    required this.audioTrackStartUs,
    required this.width,
    required this.height,
    required this.rotation,
  }) {
    if (durationUs < 300000 ||
        audioTrackStartUs < 0 ||
        width <= 0 ||
        height <= 0 ||
        !const <int>{0, 90, 180, 270}.contains(rotation)) {
      throw const MediaContractException('Inspected media is invalid.');
    }
  }

  factory InspectedMedia.fromJson(Map<String, Object?> json) {
    try {
      return InspectedMedia(
        durationUs: json['durationUs'] as int,
        audioTrackStartUs: json['audioTrackStartUs'] as int,
        width: json['width'] as int,
        height: json['height'] as int,
        rotation: json['rotation'] as int,
      );
    } on TypeError {
      throw const MediaContractException('Malformed inspected media.');
    }
  }

  final int durationUs;
  final int audioTrackStartUs;
  final int width;
  final int height;
  final int rotation;
}

final class CapturedMedia extends InspectedMedia {
  CapturedMedia({
    required this.operationId,
    required this.assetId,
    required this.relativePath,
    required super.durationUs,
    required super.audioTrackStartUs,
    required super.width,
    required super.height,
    required super.rotation,
  }) {
    if (operationId.isEmpty ||
        assetId.isEmpty ||
        !relativePath.startsWith('staging/') ||
        relativePath.contains(r'\') ||
        relativePath.split('/').contains('..')) {
      throw const MediaContractException('Captured media identity is invalid.');
    }
  }

  factory CapturedMedia.fromJson(Map<String, Object?> json) {
    try {
      return CapturedMedia(
        operationId: json['operationId'] as String,
        assetId: json['assetId'] as String,
        relativePath: json['relativePath'] as String,
        durationUs: json['durationUs'] as int,
        audioTrackStartUs: json['audioTrackStartUs'] as int,
        width: json['width'] as int,
        height: json['height'] as int,
        rotation: json['rotation'] as int,
      );
    } on TypeError {
      throw const MediaContractException('Malformed captured media.');
    }
  }

  final String operationId;
  final String assetId;
  final String relativePath;
}

final class MediaEvent {
  const MediaEvent({
    required this.operationId,
    required this.type,
    this.progress,
    this.errorCode,
  });

  factory MediaEvent.fromJson(Map<String, Object?> json) {
    final type = MediaEventType.values
        .where((value) => value.name == json['type'])
        .firstOrNull;
    if (type == null) {
      throw const MediaContractException('Unsupported media event.');
    }
    try {
      final event = MediaEvent(
        operationId: json['operationId'] as String,
        type: type,
        progress: (json['progress'] as num?)?.toDouble(),
        errorCode: json['errorCode'] as String?,
      );
      if (event.operationId.isEmpty ||
          (event.progress != null &&
              (!event.progress!.isFinite ||
                  event.progress! < 0 ||
                  event.progress! > 1))) {
        throw const MediaContractException('Invalid media event.');
      }
      return event;
    } on TypeError {
      throw const MediaContractException('Malformed media event.');
    }
  }

  final String operationId;
  final MediaEventType type;
  final double? progress;
  final String? errorCode;
}

final class MediaContractException implements Exception {
  const MediaContractException(this.message);

  final String message;

  @override
  String toString() => 'MediaContractException: $message';
}

final class MediaAnalysisRequest {
  MediaAnalysisRequest({
    required this.assetId,
    required this.relativePath,
    required this.selectionStartUs,
    required this.selectionDurationUs,
    this.audioTrackStartUs = 0,
  }) {
    if (assetId.isEmpty || relativePath.isEmpty) {
      throw const MediaContractException('Asset identity cannot be empty.');
    }
    if (audioTrackStartUs < 0 ||
        audioTrackStartUs > _maxInt64 ||
        selectionStartUs < 0 ||
        selectionStartUs > _maxInt64 ||
        selectionDurationUs <= 0 ||
        selectionDurationUs > _maxInt64 ||
        selectionStartUs > _maxInt64 - selectionDurationUs) {
      throw const MediaContractException('Analysis selection is out of range.');
    }
  }

  factory MediaAnalysisRequest.fromJson(Map<String, Object?> json) {
    _requireVersion(json, 'schemaVersion', 1);
    try {
      return MediaAnalysisRequest(
        assetId: json['assetId'] as String,
        relativePath: json['relativePath'] as String,
        selectionStartUs: json['selectionStartUs'] as int,
        selectionDurationUs: json['selectionDurationUs'] as int,
        audioTrackStartUs: json['audioTrackStartUs'] as int,
      );
    } on TypeError {
      throw const MediaContractException('Malformed analysis request JSON.');
    }
  }

  factory MediaAnalysisRequest.forAsset(ClipAsset asset) =>
      MediaAnalysisRequest(
        assetId: asset.id,
        relativePath: asset.relativePath,
        selectionStartUs: asset.selectionStartUs,
        selectionDurationUs: asset.selectionDurationUs,
        audioTrackStartUs: asset.audioTrackStartUs,
      );

  static const int schemaVersion = 1;
  final String assetId;
  final String relativePath;
  final int selectionStartUs;
  final int selectionDurationUs;
  final int audioTrackStartUs;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'assetId': assetId,
    'relativePath': relativePath,
    'selectionStartUs': selectionStartUs,
    'selectionDurationUs': selectionDurationUs,
    'audioTrackStartUs': audioTrackStartUs,
  };
}

const int _maxInt64 = 0x7fffffffffffffff;

final class AudibleRegion {
  const AudibleRegion({
    required this.startSample,
    required this.durationSamples,
    this.fundamentalMidiNote,
  });

  final int startSample;
  final int durationSamples;
  final double? fundamentalMidiNote;

  factory AudibleRegion.fromJson(Map<String, Object?> json) => AudibleRegion(
    startSample: json['startSample'] as int,
    durationSamples: json['durationSamples'] as int,
    fundamentalMidiNote: (json['fundamentalMidiNote'] as num?)?.toDouble(),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'startSample': startSample,
    'durationSamples': durationSamples,
    if (fundamentalMidiNote != null) 'fundamentalMidiNote': fundamentalMidiNote,
  };
}

final class AnalyzedClip {
  AnalyzedClip({
    required this.assetId,
    this.sourceStartSample = 0,
    required this.durationSamples,
    required this.sampleRate,
    required List<int> onsetSamples,
    List<AudibleRegion> audibleRegions = const <AudibleRegion>[],
    required this.peak,
    required this.rms,
    required this.suggestedRole,
    this.fundamentalMidiNote,
    this.registerMidiNote,
    this.analysisVersion = 1,
  }) : onsetSamples = List<int>.unmodifiable(onsetSamples),
       audibleRegions = List<AudibleRegion>.unmodifiable(audibleRegions) {
    if (assetId.isEmpty) {
      throw const MediaContractException('Asset id cannot be empty.');
    }
    if (analysisVersion != 1 || sampleRate != 48000) {
      throw const MediaContractException('Unsupported analysis contract.');
    }
    if (sourceStartSample < 0 ||
        sourceStartSample > _maxInt64 ||
        durationSamples <= 0 ||
        durationSamples > _maxInt64 ||
        sourceStartSample > _maxInt64 - durationSamples ||
        onsetSamples.any(
          (sample) =>
              sample < sourceStartSample ||
              sample >= sourceStartSample + durationSamples,
        ) ||
        audibleRegions.length > 16 ||
        audibleRegions.any(
          (region) =>
              region.startSample < sourceStartSample ||
              region.durationSamples <= 0 ||
              (region.fundamentalMidiNote != null &&
                  (!region.fundamentalMidiNote!.isFinite ||
                      region.fundamentalMidiNote! < 24 ||
                      region.fundamentalMidiNote! > 100)) ||
              region.startSample >
                  sourceStartSample + durationSamples - region.durationSamples,
        )) {
      throw const MediaContractException('Analysis sample range is invalid.');
    }
    if (!peak.isFinite ||
        !rms.isFinite ||
        peak < 0 ||
        peak > 1 ||
        rms < 0 ||
        rms > 1) {
      throw const MediaContractException(
        'Analysis levels must be finite and normalized.',
      );
    }
    if (registerMidiNote != null &&
        (!registerMidiNote!.isFinite ||
            registerMidiNote! < 24 ||
            registerMidiNote! > 100)) {
      throw const MediaContractException('Voice register is out of range.');
    }
    if (fundamentalMidiNote != null &&
        (!fundamentalMidiNote!.isFinite ||
            fundamentalMidiNote! < 24 ||
            fundamentalMidiNote! > 100)) {
      throw const MediaContractException('Fundamental note is out of range.');
    }
  }

  factory AnalyzedClip.fromJson(Map<String, Object?> json) {
    _requireVersion(json, 'schemaVersion', 1);
    _requireVersion(json, 'analysisVersion', 1);
    final roleName = json['suggestedRole'];
    final role = SuggestedRole.values
        .where((value) => value.name == roleName)
        .firstOrNull;
    if (role == null) {
      throw const MediaContractException('Unsupported suggested role.');
    }
    try {
      return AnalyzedClip(
        assetId: json['assetId'] as String,
        sourceStartSample: json['sourceStartSample'] as int,
        durationSamples: json['durationSamples'] as int,
        sampleRate: json['sampleRate'] as int,
        onsetSamples: (json['onsetSamples'] as List<Object?>).cast<int>(),
        audibleRegions: (json['audibleRegions'] as List<Object?>? ?? const [])
            .map(
              (value) => AudibleRegion.fromJson(
                (value as Map<Object?, Object?>).cast(),
              ),
            )
            .toList(),
        peak: (json['peak'] as num).toDouble(),
        rms: (json['rms'] as num).toDouble(),
        suggestedRole: role,
        fundamentalMidiNote: (json['fundamentalMidiNote'] as num?)?.toDouble(),
        registerMidiNote: (json['registerMidiNote'] as num?)?.toDouble(),
        analysisVersion: json['analysisVersion'] as int,
      );
    } on TypeError {
      throw const MediaContractException('Malformed analysis JSON.');
    }
  }

  static const int schemaVersion = 1;
  final int analysisVersion;
  final String assetId;
  final int sourceStartSample;
  final int durationSamples;
  final int sampleRate;
  final List<int> onsetSamples;
  final List<AudibleRegion> audibleRegions;
  final double peak;
  final double rms;
  final SuggestedRole suggestedRole;
  final double? fundamentalMidiNote;
  final double? registerMidiNote;

  bool get isUsable => peak >= 0.001 || rms >= 0.0001;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'analysisVersion': analysisVersion,
    'assetId': assetId,
    'sourceStartSample': sourceStartSample,
    'durationSamples': durationSamples,
    'sampleRate': sampleRate,
    'onsetSamples': onsetSamples,
    if (audibleRegions.isNotEmpty)
      'audibleRegions': audibleRegions
          .map((region) => region.toJson())
          .toList(),
    'peak': peak,
    'rms': rms,
    'suggestedRole': suggestedRole.name,
    if (fundamentalMidiNote != null) 'fundamentalMidiNote': fundamentalMidiNote,
    if (registerMidiNote != null) 'registerMidiNote': registerMidiNote,
  };
}

void _requireVersion(Map<String, Object?> json, String key, int supported) {
  if (json[key] != supported) {
    throw MediaContractException('Unsupported $key: ${json[key]}.');
  }
}
