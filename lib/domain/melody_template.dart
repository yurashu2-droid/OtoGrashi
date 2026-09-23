/// Original four-bar motifs. Each slot is half a bar at 128 BPM; null is a rest.
/// Pitches are relative to the recorded voice, so the recorded sound remains
/// recognizable even when its absolute pitch cannot be measured reliably.
enum MelodyTemplate { none, hop, wink, answer }

extension MelodyTemplateDetails on MelodyTemplate {
  String get label => switch (this) {
    MelodyTemplate.none => 'そのまま',
    MelodyTemplate.hop => 'ぴょん',
    MelodyTemplate.wink => 'ウインク',
    MelodyTemplate.answer => 'かけあい',
  };

  String get description => switch (this) {
    MelodyTemplate.none => '撮った音のリズムだけ',
    MelodyTemplate.hop => '上がって戻る、口ずさみやすい音',
    MelodyTemplate.wink => '休符を挟んで跳ねる音',
    MelodyTemplate.answer => '同じ音に違う高さが返事する',
  };

  List<MelodyNote> get notes => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [
      MelodyNote(0),
      MelodyNote(2),
      MelodyNote(3),
      MelodyNote(2),
      MelodyNote(0),
      MelodyNote(-2),
      MelodyNote(0),
      MelodyNote(3),
    ],
    MelodyTemplate.wink => const [
      MelodyNote(0),
      MelodyNote(null),
      MelodyNote(3, delayed: true),
      MelodyNote(0),
      MelodyNote(-3),
      MelodyNote(null),
      MelodyNote(2, delayed: true),
      MelodyNote(0),
    ],
    MelodyTemplate.answer => const [
      MelodyNote(-2),
      MelodyNote(-2, delayed: true),
      MelodyNote(2),
      MelodyNote(0),
      MelodyNote(-2),
      MelodyNote(3, delayed: true),
      MelodyNote(2),
      MelodyNote(0),
    ],
  };
}

final class MelodyNote {
  const MelodyNote(this.pitchSemitones, {this.delayed = false});

  /// Null denotes a deliberate rest, rather than a silent source segment.
  final int? pitchSemitones;
  final bool delayed;
}
