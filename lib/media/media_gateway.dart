import '../domain/arrangement.dart';
import '../domain/video_recipe.dart';

abstract interface class MediaAnalysisGateway {
  Future<AnalyzedClip> analyze(MediaAnalysisRequest request);
}

abstract interface class MediaGateway implements MediaAnalysisGateway {
  Future<RenderedMedia> render(RenderRequest request);
  Future<void> cancel(String operationId);
}

final class RenderRequest {
  const RenderRequest({
    required this.operationId,
    required this.projectId,
    required this.revision,
    required this.arrangement,
    required this.video,
    required this.quality,
  });

  final String operationId;
  final String projectId;
  final int revision;
  final Arrangement arrangement;
  final VideoRecipe video;
  final RenderQuality quality;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'operationId': operationId,
    'projectId': projectId,
    'revision': revision,
    'arrangement': arrangement.toJson(),
    'video': video.toJson(),
    'quality': quality.name,
  };
}

final class RenderedMedia {
  RenderedMedia({
    required this.operationId,
    required this.projectId,
    required this.revision,
    required this.relativePath,
    required this.durationUs,
    required this.width,
    required this.height,
  }) {
    if (operationId.isEmpty ||
        projectId.isEmpty ||
        revision < 0 ||
        relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.contains(r'\') ||
        relativePath.contains(':') ||
        relativePath.split(RegExp(r'[/\\]+')).contains('..') ||
        durationUs <= 0 ||
        width <= 0 ||
        height <= 0) {
      throw const MediaContractException('Rendered media is invalid.');
    }
  }

  final String operationId;
  final String projectId;
  final int revision;
  final String relativePath;
  final int durationUs;
  final int width;
  final int height;

  factory RenderedMedia.fromJson(Map<String, Object?> json) {
    try {
      return RenderedMedia(
        operationId: json['operationId'] as String,
        projectId: json['projectId'] as String,
        revision: json['revision'] as int,
        relativePath: json['relativePath'] as String,
        durationUs: json['durationUs'] as int,
        width: json['width'] as int,
        height: json['height'] as int,
      );
    } on TypeError {
      throw const MediaContractException('Malformed rendered media JSON.');
    }
  }
}
