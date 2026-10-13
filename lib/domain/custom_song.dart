import 'melody_template.dart';

/// Where a song that is not built into the app came from.
enum SongOrigin {
  /// read from a MIDI file on this phone
  imported,

  /// taken from the catalogue that everyone posts to
  catalog,
}

/// A song that is not built into the app: its name, who it is credited to, and
/// its score (melody, bass, chords) in the format of the bundled songs. A
/// project made with it carries a copy, so the song keeps playing even after
/// it leaves the catalogue or the phone's song list.
final class CustomSong {
  CustomSong({
    required this.id,
    required String title,
    required List<List<List<int>>> lanes,
    String credit = '',
    this.author,
    this.remoteId,
    this.origin = SongOrigin.imported,
  }) : title = _clean(title, maxTitleLength, fallback: 'よみこんだ曲'),
       credit = _clean(credit, maxCreditLength),
       lanes = fitScore(lanes);

  static const maxTitleLength = 40;
  static const maxCreditLength = 60;

  /// Stable on this phone; a catalogue song keeps its catalogue id in
  /// [remoteId] as well.
  final String id;
  final String title;

  /// The composer or source, as whoever added the song wrote it.
  final String credit;

  /// The display name of the person who posted it, for catalogue songs.
  final String? author;
  final String? remoteId;
  final SongOrigin origin;

  /// `[melody, bass, chords]`, each note `[start tick, duration tick, pitch]`
  /// at 480 ticks per beat, eight bars long.
  final List<List<List<int>>> lanes;

  bool get hasMelody => lanes.first.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    if (credit.isNotEmpty) 'credit': credit,
    'author': ?author,
    'remoteId': ?remoteId,
    'origin': origin.name,
    'lanes': [
      for (final lane in lanes) [for (final note in lane) List<int>.of(note)],
    ],
  };

  /// Null unless [json] is a song with at least a melody; anything stored or
  /// received is checked again here.
  static CustomSong? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final title = json['title'];
    final lanes = json['lanes'];
    if (id is! String || id.isEmpty || title is! String || lanes is! List) {
      return null;
    }
    final score = <List<List<int>>>[];
    for (final lane in lanes.take(3)) {
      if (lane is! List) return null;
      final notes = <List<int>>[];
      for (final note in lane) {
        if (note is! List ||
            note.length != 3 ||
            note.any((value) => value is! int)) {
          return null;
        }
        notes.add(note.cast<int>());
      }
      score.add(notes);
    }
    final credit = json['credit'];
    final author = json['author'];
    final remoteId = json['remoteId'];
    final song = CustomSong(
      id: id,
      title: title,
      lanes: score,
      credit: credit is String ? credit : '',
      author: author is String && author.isNotEmpty ? author : null,
      remoteId: remoteId is String && remoteId.isNotEmpty ? remoteId : null,
      origin: SongOrigin.values.asNameMap()[json['origin']] ??
          SongOrigin.imported,
    );
    return song.hasMelody ? song : null;
  }

  static String _clean(String raw, int maximum, {String fallback = ''}) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) return fallback;
    return String.fromCharCodes(line.runes.take(maximum));
  }
}
