import 'dart:math' as math;

import 'midi_file.dart';

/// Why a MIDI file could not become a score. Each value is one sentence on
/// an import screen.
enum ScoreImportFailure {
  /// The file holds no notes at all.
  noNotes,

  /// Every part is percussion, which has no tune to play.
  onlyDrums,

  /// No melody note starts in the chosen stretch of the song.
  emptyWindow,

  /// The music stops before the first bar of the stretch is over.
  tooShort,
}

/// How a lane came by its part.
enum LaneSource {
  /// The caller asked for it.
  caller,

  /// The track's name says what it plays.
  name,

  /// Guessed from the notes: how high they are and how many sound together.
  content,

  /// No part was left for the lane.
  none,
}

/// One part of a MIDI file as an import screen lists it.
final class ScorePart {
  const ScorePart._({
    required this.index,
    required this.name,
    required this.channel,
    required this.noteCount,
    required this.lowestPitch,
    required this.highestPitch,
    required this.looksLikeDrums,
  });

  /// What [ImportedScore.fromMidi] takes to put this part on a lane.
  final int index;

  /// The track name, when the file gives its tracks readable names.
  final String? name;

  /// Zero-based MIDI channel.
  final int channel;
  final int noteCount;
  final int lowestPitch;
  final int highestPitch;

  /// On the percussion channel, or named like a drum kit. Such a part is
  /// never chosen for a lane unless the caller asks for it.
  final bool looksLikeDrums;
}

/// What happened to one lane on the way in.
final class LaneReport {
  const LaneReport._({
    required this.part,
    required this.source,
    this.notes = 0,
    this.clipped = 0,
    this.cut = 0,
    this.dropped = 0,
    this.overLimit = 0,
  });

  /// [ScorePart.index] of the part on this lane, or null when it is empty.
  final int? part;
  final LaneSource source;

  /// Notes the lane holds.
  final int notes;

  /// Of those, the ones that ran past the end of the window and stop there.
  final int clipped;

  /// Of those, the ones shortened or delayed by another note of the lane,
  /// so that the melody and the bass play one note at a time.
  final int cut;

  /// Notes of the window left out: covered by another note of the lane, or
  /// shorter than [ImportedScore.minNoteTicks].
  final int dropped;

  /// Notes left out because the lane was full.
  final int overLimit;
}

/// What [ImportedScore.fromMidi] made of a file: [ScoreImported] with the
/// score, or [ScoreImportFailed] with the reason. Both list the file's
/// parts, so that the person can choose differently and try again.
sealed class ScoreImport {
  const ScoreImport._({required this.parts, required this.songBeats});

  /// Every part of the file, drums included.
  final List<ScorePart> parts;

  /// How long the file is, in beats: a start beyond this finds nothing.
  final double songBeats;
}

/// The score, with what was chosen, changed and assumed to make it.
final class ScoreImported extends ScoreImport {
  const ScoreImported._({
    required super.parts,
    required super.songBeats,
    required this.score,
    required this.melody,
    required this.bass,
    required this.chords,
    required this.startBeat,
    required this.barBeats,
    required this.filledBeats,
    required this.tempoBpm,
    required this.meterAssumed,
    required this.timingRounded,
  }) : super._();

  final ImportedScore score;
  final LaneReport melody;
  final LaneReport bass;
  final LaneReport chords;

  /// Where in the file the score starts, in beats.
  final double startBeat;

  /// Length of the bar at [startBeat], in beats: the step that moves the
  /// start by one bar.
  final double barBeats;

  /// Where the last note of the score ends. Less than [ImportedScore.beats]
  /// when the song is over before the window is.
  final double filledBeats;

  /// The file's own tempo at [startBeat]. It is not kept: the app plays
  /// every score on its 128 BPM clock.
  final double tempoBpm;

  /// The file gives no time signature for [startBeat], so bars were counted
  /// in 4/4.
  final bool meterAssumed;

  /// The file's ticks do not divide a beat into 480, and some notes moved
  /// to the nearest tick.
  final bool timingRounded;
}

/// The file has nothing the app can play as asked; [reason] says why.
final class ScoreImportFailed extends ScoreImport {
  const ScoreImportFailed._({
    required super.parts,
    required super.songBeats,
    required this.reason,
  }) : super._();

  final ScoreImportFailure reason;
}

/// A song brought in from outside, in the form the arrangers play: the
/// [melody, bass, chords] lanes of `publicDomainScores`, each note
/// [start tick, duration tick, MIDI pitch] at 480 ticks per beat.
///
/// Every instance keeps these rules: there is a melody, while the bass and
/// the chords may be empty; the melody and the bass play one note at a
/// time; notes are in order of start and end inside [beats]; and no note
/// or lane is outside the limits below.
final class ImportedScore {
  /// Throws a [FormatException] when the values break those rules.
  ImportedScore({
    required this.title,
    required this.beats,
    required List<List<List<int>>> lanes,
  }) : lanes = List.unmodifiable([
         for (final lane in lanes)
           List<List<int>>.unmodifiable([
             for (final note in lane) List<int>.unmodifiable(note),
           ]),
       ]) {
    if (title.runes.length > maxTitleLength) {
      throw const FormatException('Score title is too long.');
    }
    if (!supportedBeats.contains(beats)) {
      throw const FormatException('Score must be 32 or 64 beats long.');
    }
    if (lanes.length != 3) {
      throw const FormatException('Score needs melody, bass and chords.');
    }
    if (lanes.first.isEmpty) {
      throw const FormatException('Score has no melody.');
    }
    final end = beats * ticksPerBeat;
    for (final (index, lane) in lanes.indexed) {
      if (lane.length > maxLaneNotes) {
        throw const FormatException('Score lane has too many notes.');
      }
      var lastStart = 0;
      var lastEnd = 0;
      for (final note in lane) {
        if (note.length != 3) {
          throw const FormatException('Score note is malformed.');
        }
        final [start, duration, pitch] = note;
        if (start < 0 ||
            duration < minNoteTicks ||
            duration > end - start ||
            pitch < 0 ||
            pitch > 127) {
          throw const FormatException('Score note is out of range.');
        }
        if (start < lastStart) {
          throw const FormatException('Score notes are out of order.');
        }
        if (index != 2 && start < lastEnd) {
          throw const FormatException('Score melody or bass overlaps.');
        }
        lastStart = start;
        lastEnd = start + duration;
      }
    }
  }

  /// Reads what [toJson] wrote. Throws a [FormatException] for anything
  /// else, so a stored or received song is checked before it is played.
  factory ImportedScore.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported score schema: ${json['schemaVersion']}.',
      );
    }
    final title = json['title'];
    final beats = json['beats'];
    final lanes = json['lanes'];
    if (title is! String || beats is! int || lanes is! List<Object?>) {
      throw const FormatException('Malformed score JSON.');
    }
    return ImportedScore(
      title: title,
      beats: beats,
      lanes: [
        for (final lane in lanes)
          [
            for (final note in _list(lane))
              [
                for (final value in _list(note))
                  value is int
                      ? value
                      : throw const FormatException('Malformed score JSON.'),
              ],
          ],
      ],
    );
  }

  /// Turns a parsed MIDI file into a score.
  ///
  /// Each lane takes one part of the file: the one the caller names with
  /// [melodyPart], [bassPart] or [chordsPart] (a [ScorePart.index], which
  /// may be the same for two lanes, or [emptyLane] to leave the bass or the
  /// chords out), otherwise the one whose track name says so, otherwise a
  /// guess from the notes. Drums are passed over. The lowest part is kept
  /// for the bass, the melody is the highest part that mostly plays one
  /// note at a time, and the chords are what remains with the most notes
  /// sounding together. A file with one part gives a melody alone.
  ///
  /// The score is the [beats] beats from [startBeat], by default the start
  /// of the bar in which the melody first sounds. Notes that start outside
  /// are left out, notes that run past the end stop there, and overlapping
  /// notes are thinned until the melody (highest wins) and the bass (lowest
  /// wins) play one at a time. [title] defaults to the name the file gives
  /// the song.
  ///
  /// What is wrong with the song comes back as a [ScoreImportFailed];
  /// arguments that make no sense throw.
  static ScoreImport fromMidi(
    MidiFile file, {
    String? title,
    int beats = 32,
    double? startBeat,
    int? melodyPart,
    int? bassPart,
    int? chordsPart,
  }) {
    if (!supportedBeats.contains(beats)) {
      throw ArgumentError.value(beats, 'beats', 'Must be 32 or 64');
    }
    if (startBeat != null && !(startBeat >= 0 && startBeat.isFinite)) {
      throw ArgumentError.value(startBeat, 'startBeat', 'Must be 0 or more');
    }
    return _Importer(file).run(
      title: title,
      beats: beats,
      startBeat: startBeat,
      asked: [melodyPart, bassPart, chordsPart],
    );
  }

  /// Where the bars of [file] start, in beats, counted as [fromMidi] counts
  /// them: from each time signature, and in 4/4 when the file gives none.
  /// Every bar up to the end of the last note, but never more than [limit],
  /// which only a damaged file reaches.
  static List<double> barStarts(MidiFile file, {int limit = 2000}) =>
      _Importer(file).barStarts(limit);

  static const schemaVersion = 1;
  static const ticksPerBeat = 480;

  /// Eight or sixteen bars of 4/4: the 15 and 30 second songs at 128 BPM.
  static const supportedBeats = [32, 64];

  /// A bound on size, not a promise that the arrangers can play as many:
  /// an arrangement holds 512 events in all.
  static const maxLaneNotes = 512;

  /// A 128th note, 15 ms on the app's clock. Anything shorter is the stub
  /// of an overlap or a glitch rather than a pitch, and a melody of such
  /// notes would overflow the 128 pitch steps an arranged phrase may have.
  static const minNoteTicks = 15;

  /// What a song title may be in an arrangement.
  static const maxTitleLength = 40;

  /// Passed as `bassPart` or `chordsPart` to leave that lane empty.
  static const emptyLane = -1;

  /// The song's name, or empty when neither the file nor the caller has one.
  final String title;
  final int beats;

  /// [melody, bass, chords], unmodifiable all the way down.
  final List<List<List<int>>> lanes;

  List<List<int>> get melody => lanes[0];
  List<List<int>> get bass => lanes[1];
  List<List<int>> get chords => lanes[2];

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'title': title,
    'beats': beats,
    'lanes': lanes,
  };

  static List<Object?> _list(Object? value) => value is List<Object?>
      ? value
      : throw const FormatException('Malformed score JSON.');
}

const _melodyWords = [
  'melody',
  'lead',
  'vocal',
  'vox',
  'メロディ',
  '主旋律',
  'ボーカル',
  'ヴォーカル',
  'リード',
  '歌',
  'うた',
];
const _bassWords = ['bass', 'ベース'];
const _chordWords = [
  'chord',
  'piano',
  'keys',
  'keyboard',
  'harmony',
  'コード',
  'ピアノ',
  'キーボード',
  '和音',
  '伴奏',
];
const _drumWords = ['drum', 'percussion', 'ドラム', 'パーカッション', '打楽器'];

/// What sequencers call the conductor track when the song has no name.
const _conductorNames = {'tempo', 'tempo track', 'conductor', 'untitled'};

bool _says(String? name, List<String> words) {
  if (name == null) return false;
  final text = name.toLowerCase();
  return words.any(text.contains);
}

/// The lane a track name asks for, or null when it does not say. A name
/// that says bass is a bass even when it also says lead or keys.
int? _laneNamed(String? name) => _says(name, _bassWords)
    ? 1
    : _says(name, _melodyWords)
    ? 0
    : _says(name, _chordWords)
    ? 2
    : null;

/// A note being fitted into a lane, in score ticks from the window start.
final class _Note {
  _Note(
    this.start,
    this.end,
    this.pitch, {
    required this.clipped,
    this.cut = false,
  });

  final int start;
  final int end;
  final int pitch;

  /// Ran past the end of the window and stops there.
  final bool clipped;

  /// Shortened or delayed by another note of the lane.
  final bool cut;

  /// Has had its turn as the one voice.
  var heard = false;

  int get length => end - start;
}

/// A finished lane and the account of how it was made.
final class _Lane {
  const _Lane(this.notes, this.report);

  final List<List<int>> notes;
  final LaneReport report;
}

/// One import, from the parts of a file to the lanes of a score.
final class _Importer {
  _Importer(this.file) : sources = file.parts;

  static const ticksPerBeat = ImportedScore.ticksPerBeat;

  final MidiFile file;
  final List<MidiPart> sources;

  /// Set once a note of a lane had to move to land on the score's grid.
  var rounded = false;

  late final parts = List<ScorePart>.unmodifiable([
    for (final (index, part) in sources.indexed)
      ScorePart._(
        index: index,
        name: part.name,
        channel: part.channel,
        noteCount: part.notes.length,
        lowestPitch: part.notes.map((note) => note.pitch).reduce(math.min),
        highestPitch: part.notes.map((note) => note.pitch).reduce(math.max),
        looksLikeDrums: part.channel == 9 || _says(part.name, _drumWords),
      ),
  ]);

  /// Per part: average pitch, the share of its sounding time in which one
  /// note sounds alone, and how many notes sound together on average.
  late final textures = [for (final part in sources) texture(part.notes)];

  /// Where the last note of the file ends, in score ticks.
  late final songEnd = sources.fold(
    0,
    (end, part) =>
        math.max(end, at(part.notes.map((n) => n.end).reduce(math.max))),
  );

  /// A tick of the file on the score's grid of 480 per beat: exact when the
  /// file's division allows it, the nearest tick otherwise.
  int at(int tick) =>
      (2 * ticksPerBeat * tick + file.division) ~/ (2 * file.division);

  bool exact(int tick) => ticksPerBeat * tick % file.division == 0;

  ScoreImport run({
    required String? title,
    required int beats,
    required double? startBeat,
    required List<int?> asked,
  }) {
    ScoreImport failed(ScoreImportFailure reason) => ScoreImportFailed._(
      parts: parts,
      songBeats: songEnd / ticksPerBeat,
      reason: reason,
    );

    if (sources.isEmpty) return failed(ScoreImportFailure.noNotes);
    for (final (lane, part) in asked.indexed) {
      if (part == null || (part == ImportedScore.emptyLane && lane != 0)) {
        continue;
      }
      RangeError.checkValidIndex(
        part,
        sources,
        const ['melodyPart', 'bassPart', 'chordsPart'][lane],
      );
    }
    final lanes = choose(asked);
    final melody = lanes.first.$1;
    if (melody == null) return failed(ScoreImportFailure.onlyDrums);
    if (startBeat != null && startBeat * ticksPerBeat >= songEnd) {
      return failed(ScoreImportFailure.emptyWindow);
    }

    final from = startBeat == null
        ? bar(at(firstKept(sources[melody].notes).start)).$1
        : (startBeat * ticksPerBeat).round();
    final to = from + beats * ticksPerBeat;
    final built = [
      fill(lanes[0], from, to, lowWins: false),
      fill(lanes[1], from, to, lowWins: true),
      fill(lanes[2], from, to),
    ];
    if (built.first.notes.isEmpty) {
      return failed(ScoreImportFailure.emptyWindow);
    }
    final filled = built
        .expand((lane) => lane.notes)
        .map((note) => note[0] + note[1])
        .reduce(math.max);
    final barTicks = bar(from).$2;
    if (filled < math.min(barTicks, to - from)) {
      return failed(ScoreImportFailure.tooShort);
    }
    return ScoreImported._(
      parts: parts,
      songBeats: songEnd / ticksPerBeat,
      score: ImportedScore(
        title: titled(title),
        beats: beats,
        lanes: [for (final lane in built) lane.notes],
      ),
      melody: built[0].report,
      bass: built[1].report,
      chords: built[2].report,
      startBeat: from / ticksPerBeat,
      barBeats: barTicks / ticksPerBeat,
      filledBeats: filled / ticksPerBeat,
      tempoBpm:
          file.tempos
              .where((tempo) => at(tempo.tick) <= from)
              .lastOrNull
              ?.bpm ??
          120,
      meterAssumed: !file.timeSignatures.any((s) => at(s.tick) <= from),
      timingRounded: rounded,
    );
  }

  /// The part of each lane and how it was found. Names are trusted before
  /// notes, and no part is given to two lanes unless the caller says so.
  List<(int?, LaneSource)> choose(List<int?> asked) {
    final chosen = <(int?, LaneSource)>[
      for (final part in asked)
        part == null
            ? (null, LaneSource.none)
            : (
                part == ImportedScore.emptyLane ? null : part,
                LaneSource.caller,
              ),
    ];
    bool open(int lane) => chosen[lane].$2 == LaneSource.none;
    final playable = [
      for (final part in parts)
        if (!part.looksLikeDrums) part.index,
    ];
    List<int> free() => [
      for (final part in playable)
        if (!chosen.any((lane) => lane.$1 == part)) part,
    ];

    for (var lane = 0; lane < 3; lane++) {
      final named = [
        for (final part in free())
          if (_laneNamed(sources[part].name) == lane) part,
      ];
      if (open(lane) && named.isNotEmpty) {
        chosen[lane] = (best(named, lane), LaneSource.name);
      }
    }
    if (open(0)) {
      final pool = free();
      if (pool.isNotEmpty) {
        // The lowest part is the bass, however much it sounds like a tune.
        if (open(1) && pool.length > 1) pool.remove(best(pool, 1));
        chosen[0] = (best(pool, 0), LaneSource.content);
      } else {
        // Nothing is left to sing. A part named for the keys or the bass
        // may well carry the tune, so the melody takes it over; failing
        // that it shares what the caller put elsewhere.
        final named = chosen[2].$2 == LaneSource.name
            ? 2
            : chosen[1].$2 == LaneSource.name
            ? 1
            : null;
        if (named != null) {
          chosen[0] = (chosen[named].$1, LaneSource.content);
          chosen[named] = (null, LaneSource.none);
        } else if (playable.isNotEmpty) {
          chosen[0] = (best(playable, 0), LaneSource.content);
        }
      }
    }
    for (final lane in const [1, 2]) {
      if (open(lane) && free().isNotEmpty) {
        chosen[lane] = (best(free(), lane), LaneSource.content);
      }
    }
    return chosen;
  }

  /// The part of [pool] that suits [lane] best; the earliest one on a tie.
  int best(Iterable<int> pool, int lane) {
    double score(int part) {
      final (:pitch, :solo, :voices) = textures[part];
      return switch (lane) {
        0 => (solo > .5 ? 128 : 0) + pitch,
        1 => -pitch,
        _ => voices,
      };
    }

    return pool.reduce((a, b) => score(b) > score(a) ? b : a);
  }

  static ({double pitch, double solo, double voices}) texture(
    List<MidiNote> notes,
  ) {
    final edges =
        <(int, int)>[
          for (final note in notes)
            if (note.duration > 0) ...[(note.start, 1), (note.end, -1)],
        ]..sort(
          (a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
        );
    var sounding = 0;
    var last = 0;
    var heard = 0;
    var alone = 0;
    var held = 0;
    for (final (tick, step) in edges) {
      if (sounding > 0) {
        heard += tick - last;
        held += (tick - last) * sounding;
        if (sounding == 1) alone += tick - last;
      }
      sounding += step;
      last = tick;
    }
    return (
      pitch: notes.fold(0, (sum, note) => sum + note.pitch) / notes.length,
      solo: heard == 0 ? 1 : alone / heard,
      voices: heard == 0 ? 1 : held / heard,
    );
  }

  /// The first note long enough to stay in a lane, where the melody is
  /// taken to begin.
  MidiNote firstKept(List<MidiNote> notes) => notes.firstWhere(
    (note) => at(note.end) - at(note.start) >= ImportedScore.minNoteTicks,
    orElse: () => notes.first,
  );

  /// Start and length of the bar that holds [tick], in score ticks. Bars are
  /// counted from each time signature; a file without one is in 4/4.
  (int, int) bar(int tick) {
    var origin = 0;
    var length = 4 * ticksPerBeat;
    for (final signature in file.timeSignatures) {
      final start = at(signature.tick);
      if (start > tick) break;
      origin = start;
      length = 4 * ticksPerBeat * signature.numerator ~/ signature.denominator;
    }
    return (origin + (tick - origin) ~/ length * length, length);
  }

  /// The start of every bar that begins before the song ends, in beats.
  List<double> barStarts(int limit) {
    final starts = <double>[];
    for (var tick = 0; tick < songEnd && starts.length < limit;) {
      final (start, length) = bar(tick);
      starts.add(start / ticksPerBeat);
      var next = start + length;
      // a new time signature may begin before the bar it interrupts is over
      for (final signature in file.timeSignatures) {
        final change = at(signature.tick);
        if (change > start && change < next) next = change;
      }
      tick = next;
    }
    return starts;
  }

  /// The notes of one part between [from] and [to], moved to start at 0.
  /// [lowWins] says which note wins where the lane must play one at a time;
  /// null leaves chords as they are.
  _Lane fill((int?, LaneSource) choice, int from, int to, {bool? lowWins}) {
    final (part, source) = choice;
    if (part == null) {
      return _Lane(const [], LaneReport._(part: null, source: source));
    }
    final window = <_Note>[];
    for (final note in sources[part].notes) {
      final start = at(note.start);
      if (start < from || start >= to) continue;
      final end = at(note.end);
      rounded = rounded || !exact(note.start) || !exact(note.end);
      window.add(
        _Note(
          start - from,
          math.min(end, to) - from,
          note.pitch,
          clipped: end > to,
        ),
      );
    }
    bool audible(_Note note) => note.length >= ImportedScore.minNoteTicks;
    // Too-short notes go first, so that a glitch cannot cut a real note.
    var notes = window.where(audible).toList();
    if (lowWins != null) {
      notes = oneVoice(notes, lowWins: lowWins).where(audible).toList();
    }
    // The order of the bundled scores: by start, then duration, then pitch.
    notes.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : a.length != b.length
          ? a.length.compareTo(b.length)
          : a.pitch.compareTo(b.pitch),
    );
    final kept = notes.take(ImportedScore.maxLaneNotes).toList();
    return _Lane(
      [
        for (final note in kept) [note.start, note.length, note.pitch],
      ],
      LaneReport._(
        part: part,
        source: source,
        notes: kept.length,
        clipped: kept.where((note) => note.clipped).length,
        cut: kept.where((note) => note.cut).length,
        dropped: window.length - notes.length,
        overLimit: notes.length - kept.length,
      ),
    );
  }

  /// One note at a time: at every moment the highest sounding note wins
  /// (the lowest when [lowWins]), and each note keeps the first stretch in
  /// which it wins. So a chord becomes its top note, a note held under a
  /// higher one stops where that one starts, and a note that starts under a
  /// higher one waits for it to end. A note that comes back out from under
  /// another stays silent: sounding it again would be an attack the song
  /// never had.
  static List<_Note> oneVoice(List<_Note> notes, {required bool lowWins}) {
    final starting = [...notes]..sort((a, b) => a.start.compareTo(b.start));
    final ending = [...notes]..sort((a, b) => a.end.compareTo(b.end));
    // By pitch. A key struck again takes the place of its earlier note.
    final sounding = List<_Note?>.filled(128, null);
    final kept = <_Note>[];
    _Note? winner;
    var since = 0;
    var i = 0;
    var j = 0;
    while (j < ending.length) {
      final now = i < starting.length && starting[i].start < ending[j].end
          ? starting[i].start
          : ending[j].end;
      for (; j < ending.length && ending[j].end == now; j++) {
        final note = ending[j];
        if (identical(sounding[note.pitch], note)) sounding[note.pitch] = null;
      }
      for (; i < starting.length && starting[i].start == now; i++) {
        sounding[starting[i].pitch] = starting[i];
      }
      final top = (lowWins ? sounding : sounding.reversed).firstWhere(
        (note) => note != null,
        orElse: () => null,
      );
      if (identical(top, winner)) continue;
      final old = winner;
      if (old != null && !old.heard) {
        old.heard = true;
        kept.add(
          _Note(
            since,
            now,
            old.pitch,
            clipped: old.clipped && now == old.end,
            cut: since > old.start || now < old.end,
          ),
        );
      }
      winner = top;
      since = now;
    }
    return kept;
  }

  /// The caller's title, else the file's unless it only names the track.
  String titled(String? given) {
    var text = given ?? file.songName ?? '';
    if (given == null && _conductorNames.contains(text.toLowerCase())) {
      text = '';
    }
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.runes.length > ImportedScore.maxTitleLength
        ? String.fromCharCodes(text.runes.take(ImportedScore.maxTitleLength))
              .trim()
        : text;
  }
}
