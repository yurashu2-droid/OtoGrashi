final class ClipAsset {
  const ClipAsset({
    required this.id,
    required this.relativePath,
    required this.durationUs,
    this.audioTrackStartUs = 0,
    required this.selectionStartUs,
    required this.selectionDurationUs,
    required this.width,
    required this.height,
    required this.rotation,
    required this.sha256,
    required this.label,
  });

  final String id;
  final String relativePath;
  final int durationUs;
  final int audioTrackStartUs;
  final int selectionStartUs;
  final int selectionDurationUs;
  final int width;
  final int height;
  final int rotation;
  final String sha256;
  final String label;
}
