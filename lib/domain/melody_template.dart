/// Original song patterns made only from the recorded clips. Each melody slot
/// is half a bar at 128 BPM; null is a deliberate rest.
/// Pitches are relative to the recorded voice, so the recorded sound remains
/// recognizable even when its absolute pitch cannot be measured reliably.
enum MelodyTemplate { none, hop, wink, answer }

extension MelodyTemplateDetails on MelodyTemplate {
  String get label => switch (this) {
    MelodyTemplate.none => 'おまかせ',
    MelodyTemplate.hop => 'はねる',
    MelodyTemplate.wink => 'スキップ',
    MelodyTemplate.answer => 'かけあい',
  };

  String get description => switch (this) {
    MelodyTemplate.none => '撮った音からリズムをつくる',
    MelodyTemplate.hop => 'まっすぐな拍に、上がって戻る旋律',
    MelodyTemplate.wink => '裏拍と休符で、跳ねる曲',
    MelodyTemplate.answer => '刻む拍に、短い音が返事する曲',
  };

  /// Sample offsets in one 90,000-sample bar. The third beat is used by the
  /// lively style; sparse and swaying keep the first two.
  List<int> get beatOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [0, 45000, 67500],
    MelodyTemplate.wink => const [0, 33750, 67500],
    MelodyTemplate.answer => const [0, 22500, 67500],
  };

  List<int> get bassOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [0, 45000],
    MelodyTemplate.wink => const [0, 56250],
    MelodyTemplate.answer => const [0, 45000],
  };

  List<int> get keysOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [22500, 67500],
    MelodyTemplate.wink => const [11250, 56250],
    MelodyTemplate.answer => const [33750, 78750],
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

/// The same clip may fill two roles when the user records only one long sound.
/// Missing roles are kept null rather than synthesizing an unrelated source.
final class SongRoles {
  const SongRoles({this.beat, this.bass, this.keys, this.melody});

  final String? beat;
  final String? bass;
  final String? keys;
  final String? melody;

  Map<String, Object?> toJson() => {
    if (beat != null) 'beat': beat,
    if (bass != null) 'bass': bass,
    if (keys != null) 'keys': keys,
    if (melody != null) 'melody': melody,
  };

  factory SongRoles.fromJson(Map<String, Object?> json) => SongRoles(
    beat: json['beat'] as String?,
    bass: json['bass'] as String?,
    keys: json['keys'] as String?,
    melody: json['melody'] as String?,
  );
}

final class MelodyNote {
  const MelodyNote(this.pitchSemitones, {this.delayed = false});

  /// Null denotes a deliberate rest, rather than a silent source segment.
  final int? pitchSemitones;
  final bool delayed;
}
