enum SuggestedRole { transient, sustain, texture }

enum RenderQuality { preview, full }

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

final class AnalyzedClip {
  AnalyzedClip({
    required this.assetId,
    this.sourceStartSample = 0,
    required this.durationSamples,
    required this.sampleRate,
    required List<int> onsetSamples,
    required this.peak,
    required this.rms,
    required this.suggestedRole,
    this.analysisVersion = 1,
  }) : onsetSamples = List<int>.unmodifiable(onsetSamples) {
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
        peak: (json['peak'] as num).toDouble(),
        rms: (json['rms'] as num).toDouble(),
        suggestedRole: role,
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
  final double peak;
  final double rms;
  final SuggestedRole suggestedRole;

  bool get isUsable => peak >= 0.001 || rms >= 0.0001;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'analysisVersion': analysisVersion,
    'assetId': assetId,
    'sourceStartSample': sourceStartSample,
    'durationSamples': durationSamples,
    'sampleRate': sampleRate,
    'onsetSamples': onsetSamples,
    'peak': peak,
    'rms': rms,
    'suggestedRole': suggestedRole.name,
  };
}

void _requireVersion(Map<String, Object?> json, String key, int supported) {
  if (json[key] != supported) {
    throw MediaContractException('Unsupported $key: ${json[key]}.');
  }
}
