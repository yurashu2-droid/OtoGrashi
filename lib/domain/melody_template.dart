/// Original song patterns made only from the recorded clips. Each melody slot
/// is half a bar at 128 BPM; null is a deliberate rest.
/// Casual speech and noisy recordings are musicalized at the target notes;
/// natural phrase spotlights preserve the recognizable original voices.
enum MelodyTemplate { none, hop, wink, answer, midiScore }

extension MelodyTemplateDetails on MelodyTemplate {
  String get label => switch (this) {
    MelodyTemplate.none => 'リズムだけ',
    MelodyTemplate.hop => 'はねる',
    MelodyTemplate.wink => 'スキップ',
    MelodyTemplate.answer => 'かけあい',
    MelodyTemplate.midiScore => '3パート楽譜',
  };

  String get description => switch (this) {
    MelodyTemplate.none => '撮った音からリズムをつくる',
    MelodyTemplate.hop => '声や生活音が、はねるメロディに変わる',
    MelodyTemplate.wink => '小刻みな音と反転カットで、MAD風に',
    MelodyTemplate.answer => '友達の声を残して、音でかけあい',
    MelodyTemplate.midiScore => '提供されたMIDIの旋律・低音・ピアノを撮った音で演奏',
  };

  /// Sample offsets in one 90,000-sample bar. The third beat is used by the
  /// lively style; sparse and swaying keep the first two.
  List<int> get beatOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [0, 45000, 67500],
    MelodyTemplate.wink => const [0, 33750, 67500],
    MelodyTemplate.answer => const [0, 22500, 67500],
    MelodyTemplate.midiScore => const [],
  };

  List<int> get bassOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [0, 45000],
    MelodyTemplate.wink => const [0, 56250],
    MelodyTemplate.answer => const [0, 45000],
    MelodyTemplate.midiScore => const [],
  };

  List<int> get keysOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [22500, 67500],
    MelodyTemplate.wink => const [11250, 56250],
    MelodyTemplate.answer => const [33750, 78750],
    MelodyTemplate.midiScore => const [],
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
    // The dedicated MIDI branch uses all 148 notes in midi_score_data.dart.
    MelodyTemplate.midiScore => const [],
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
