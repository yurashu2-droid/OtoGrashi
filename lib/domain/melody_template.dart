import 'midi_score_data.dart';
import 'public_domain_scores.dart';

/// Original song patterns made only from the recorded clips. Each melody slot
/// is half a bar at 128 BPM; null is a deliberate rest.
/// Casual speech and noisy recordings are musicalized at the target notes;
/// natural phrase spotlights preserve the recognizable original voices.
enum MelodyTemplate {
  none,
  hop,
  wink,
  answer,
  midiScore,
  // Public-domain songs, played from the bundled MIDI like midiScore.
  odeToJoy,
  twinkle,
  furElise,
  jingleBells,
  fate,
  canon,
}

extension MelodyTemplateDetails on MelodyTemplate {
  /// Songs driven by a bundled three-lane score (melody, bass, keys).
  bool get isMidiScore => scoreId != null || this == MelodyTemplate.midiScore;

  /// Key into [publicDomainScores], or null for the built-in patterns.
  String? get scoreId => switch (this) {
    MelodyTemplate.odeToJoy => 'ode_to_joy',
    MelodyTemplate.twinkle => 'twinkle_twinkle',
    MelodyTemplate.furElise => 'fur_elise',
    MelodyTemplate.jingleBells => 'jingle_bells',
    MelodyTemplate.fate => 'beethoven_fifth_motif',
    MelodyTemplate.canon => 'canon_in_d',
    _ => null,
  };

  /// [melody, bass, keys] notes as [start tick, duration tick, MIDI pitch].
  List<List<List<int>>> get scoreNotes =>
      publicDomainScores[scoreId] ?? midiScoreNotes;

  String get label => switch (this) {
    MelodyTemplate.none => 'リズムだけ',
    MelodyTemplate.hop => 'はねる',
    MelodyTemplate.wink => 'スキップ',
    MelodyTemplate.answer => 'かけあい',
    MelodyTemplate.midiScore => '3パート楽譜',
    MelodyTemplate.odeToJoy => '歓喜の歌',
    MelodyTemplate.twinkle => 'きらきら星',
    MelodyTemplate.furElise => 'エリーゼのために',
    MelodyTemplate.jingleBells => 'ジングルベル',
    MelodyTemplate.fate => '運命',
    MelodyTemplate.canon => 'カノン',
  };

  String get description => switch (this) {
    MelodyTemplate.none => '撮った音からリズムをつくる',
    MelodyTemplate.hop => '声や生活音が、はねるメロディに変わる',
    MelodyTemplate.wink => '小刻みな音と反転カットで、MAD風に',
    MelodyTemplate.answer => '友達の声を残して、音でかけあい',
    MelodyTemplate.midiScore => '提供されたMIDIの旋律・低音・ピアノを撮った音で演奏',
    MelodyTemplate.odeToJoy => 'ベートーヴェン。みんな知ってるあのメロディ',
    MelodyTemplate.twinkle => 'フランスの古いうた。やさしく、ゆっくり',
    MelodyTemplate.furElise => 'ベートーヴェン。ゆれる旋律をひとふし',
    MelodyTemplate.jingleBells => 'ピアポント。にぎやかに鈴を鳴らそう',
    MelodyTemplate.fate => 'ベートーヴェン「交響曲第5番」の動機',
    MelodyTemplate.canon => 'パッヘルベル。定番の低音進行で',
  };

  /// Sample offsets in one 90,000-sample bar. The third beat is used by the
  /// lively style; sparse and swaying keep the first two.
  List<int> get beatOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [0, 45000, 67500],
    MelodyTemplate.wink => const [0, 33750, 67500],
    MelodyTemplate.answer => const [0, 22500, 67500],
    _ => const [],
  };

  List<int> get bassOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [0, 45000],
    MelodyTemplate.wink => const [0, 56250],
    MelodyTemplate.answer => const [0, 45000],
    _ => const [],
  };

  List<int> get keysOffsets => switch (this) {
    MelodyTemplate.none => const [],
    MelodyTemplate.hop => const [22500, 67500],
    MelodyTemplate.wink => const [11250, 56250],
    MelodyTemplate.answer => const [33750, 78750],
    _ => const [],
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
    _ => const [],
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
