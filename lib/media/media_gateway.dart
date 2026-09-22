import 'media_messages.dart';

abstract interface class MediaAnalysisGateway {
  Future<AnalyzedClip> analyze(MediaAnalysisRequest request);
}
