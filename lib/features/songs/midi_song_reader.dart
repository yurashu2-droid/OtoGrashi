import 'dart:math' as math;

import '../../domain/custom_song.dart';
import '../../domain/imported_score.dart';
import '../../domain/midi_file.dart';
import '../../media/midi_file_picker.dart';

/// A MIDI file that could not become a song; [message] is ready to show.
final class MidiSongProblem implements Exception {
  const MidiSongProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Turns a chosen MIDI file into a song, or says in the person's words why
/// it cannot ([MidiSongProblem]).
typedef MidiSongReader =
    MidiSongReading Function(PickedMidiFile file, String id);

/// A part of a MIDI file that the melody can be taken from.
final class MidiMelodyChoice {
  const MidiMelodyChoice({
    required this.part,
    required this.label,
    required this.notes,
  });

  /// What [MidiSongReading.withMelody] takes.
  final int part;

  /// The track's own name, or 「パート2」 when it has none.
  final String label;
  final int notes;
}

/// A MIDI file read as a song, with what could be read from it instead:
/// another part as the melody, or the bars from somewhere else in the file.
/// Places in the file are in beats; a start is always the start of a bar.
final class MidiSongReading {
  /// A song with nothing left to choose about it.
  const MidiSongReading.only(this.song)
    : melodies = const [],
      melody = null,
      barStarts = const [],
      bar = 0,
      startBeat = 0,
      windowBeats = 32,
      songBeats = 0,
      outline = const [],
      _source = null,
      _parts = const [],
      _moved = false;

  const MidiSongReading._({
    required this.song,
    required this.melodies,
    required this.melody,
    required this.barStarts,
    required this.bar,
    required this.startBeat,
    required this.windowBeats,
    required this.songBeats,
    required this.outline,
    required _MidiSource this._source,
    required this._parts,
    required this._moved,
  });

  final CustomSong song;

  /// The parts the melody can come from; fewer than two leave no choice.
  final List<MidiMelodyChoice> melodies;

  /// [MidiMelodyChoice.part] of the one in use.
  final int? melody;

  /// Where each bar of the file starts. Empty when the start cannot be
  /// chosen.
  final List<double> barStarts;

  /// The bar the song starts at, counted from 0.
  final int bar;

  /// Where the song starts in the file, how much of the file it takes and
  /// where the file's last note ends.
  final double startBeat;
  final double windowBeats;
  final double songBeats;

  /// The melody part through the whole file, each note `(start, length,
  /// pitch)` in order of start: a picture of where the tune is.
  final List<(double, double, int)> outline;

  final _MidiSource? _source;

  /// The part on each lane, as [ImportedScore.fromMidi] takes them, so that
  /// moving the start never changes which instruments play.
  final List<int> _parts;

  /// The person chose where the song starts.
  final bool _moved;

  /// Where the file's last bar ends: a song may run up to there.
  double get fileBeats {
    final count = barStarts.length;
    return count < 2
        ? songBeats
        : math.max(songBeats, 2 * barStarts[count - 1] - barStarts[count - 2]);
  }

  /// The last bar a song can start at and still lie inside the file, or the
  /// present one when the song already starts later than that.
  int get lastBar {
    final end = fileBeats;
    var last = 0;
    while (last + 1 < barStarts.length &&
        barStarts[last + 1] + windowBeats <= end) {
      last++;
    }
    return math.max(last, bar);
  }

  /// The next start later in the file from which the melody sounds, passing
  /// over the bars where it rests; null at the end.
  int? get barAfter {
    final next = bar + 1;
    if (barStarts.isEmpty || next > lastBar) return null;
    if (_sounds(next)) return next;
    final from = barStarts[next] + windowBeats;
    final later = outline.where((note) => note.$1 >= from).firstOrNull;
    return later == null ? null : math.min(barAt(later.$1), lastBar);
  }

  /// The same, earlier in the file; null at the beginning.
  int? get barBefore {
    final previous = bar - 1;
    if (barStarts.isEmpty || previous < 0) return null;
    if (_sounds(previous)) return previous;
    final before = barStarts[previous];
    final earlier = outline.where((note) => note.$1 < before).lastOrNull;
    return earlier == null ? null : barAt(earlier.$1);
  }

  /// The start can be somewhere else in the file.
  bool get canMove => barAfter != null || barBefore != null;

  /// The bar that [beat] lies in, among those a song can start at.
  int barAt(double beat) {
    var at = 0;
    final last = lastBar;
    while (at < last && barStarts[at + 1] <= beat) {
      at++;
    }
    return at;
  }

  bool _sounds(int from) {
    final start = barStarts[from];
    return outline.any(
      (note) => note.$1 >= start && note.$1 < start + windowBeats,
    );
  }

  /// The song from [bar] of the file instead; null when the melody rests
  /// through everything that would be taken from there.
  MidiSongReading? from(int bar) => barStarts.isEmpty
      ? null
      : _source?.read(
          parts: _parts,
          startBeat: barStarts[bar.clamp(0, lastBar)],
        );

  /// The song with another part as its melody, from the same place when that
  /// part sounds there and from where it begins otherwise. Null when the
  /// part has nothing that can be a melody.
  MidiSongReading? withMelody(int part) {
    final source = _source;
    if (source == null) return null;
    // the bass and the chords are chosen again around the new melody
    final here = source.read(parts: [part], startBeat: _moved ? startBeat : null);
    return here != null || !_moved
        ? here
        : source.read(parts: [part], startBeat: null);
  }
}

/// Reads a chosen MIDI file into a song: eight bars from where the melody
/// starts, with the parts the file's own names or notes point to. Throws a
/// [MidiSongProblem], worded for the person, when the file cannot be a song.
MidiSongReading readMidiSong(PickedMidiFile file, String id) {
  final MidiFile midi;
  try {
    midi = MidiFile.parse(file.bytes);
  } on FormatException {
    throw const MidiSongProblem('このファイルはMIDIとして読めませんでした。別のファイルで試してください。');
  }
  final source = _MidiSource(midi, id, file.name.trim());
  switch (source.import(parts: const [], startBeat: null)) {
    case final ScoreImported read:
      return source.reading(read, moved: false);
    case ScoreImportFailed(:final reason):
      throw MidiSongProblem(switch (reason) {
        ScoreImportFailure.noNotes => 'このMIDIには音が入っていません。',
        ScoreImportFailure.onlyDrums => 'このMIDIはドラムだけなので、メロディにできません。',
        ScoreImportFailure.emptyWindow => 'このMIDIからメロディを見つけられませんでした。',
        ScoreImportFailure.tooShort => 'この曲は短すぎます。1小節より長いMIDIで試してください。',
      });
  }
}

/// An opened file, read again each time the person chooses differently.
final class _MidiSource {
  _MidiSource(this.midi, this.id, this.name);

  final MidiFile midi;
  final String id;

  /// What the person chose the file by; track names inside are often just
  /// "Piano".
  final String name;

  late final barStarts = List<double>.unmodifiable(
    ImportedScore.barStarts(midi),
  );
  final _outlines = <int, List<(double, double, int)>>{};

  /// [parts] names the melody, the bass and the chords; what it leaves out
  /// is chosen from the file.
  ScoreImport import({required List<int> parts, required double? startBeat}) =>
      ImportedScore.fromMidi(
        midi,
        startBeat: startBeat,
        melodyPart: parts.elementAtOrNull(0),
        bassPart: parts.elementAtOrNull(1),
        chordsPart: parts.elementAtOrNull(2),
      );

  MidiSongReading? read({
    required List<int> parts,
    required double? startBeat,
  }) => switch (import(parts: parts, startBeat: startBeat)) {
    final ScoreImported read => reading(read, moved: startBeat != null),
    ScoreImportFailed() => null,
  };

  MidiSongReading reading(ScoreImported read, {required bool moved}) {
    final melody = read.melody.part;
    // a start that is not one of the listed bars cannot be stepped from
    final bar = barStarts.indexOf(read.startBeat);
    return MidiSongReading._(
      song: CustomSong(
        id: id,
        title: name.isEmpty ? read.score.title : name,
        lanes: read.score.lanes,
      ),
      melodies: [
        for (final (index, part)
            in read.parts.where((part) => !part.looksLikeDrums).indexed)
          MidiMelodyChoice(
            part: part.index,
            label: switch (singleLine(part.name ?? '', 16)) {
              '' => 'パート${index + 1}',
              final name => name,
            },
            notes: part.noteCount,
          ),
      ],
      melody: melody,
      barStarts: bar < 0 ? const [] : barStarts,
      bar: math.max(bar, 0),
      startBeat: read.startBeat,
      windowBeats: read.score.beats.toDouble(),
      songBeats: read.songBeats,
      outline: melody == null ? const [] : _outline(melody),
      source: this,
      parts: [
        for (final lane in [read.melody, read.bass, read.chords])
          lane.part ?? ImportedScore.emptyLane,
      ],
      moved: moved,
    );
  }

  List<(double, double, int)> _outline(int part) =>
      _outlines[part] ??= List.unmodifiable([
        for (final note in midi.parts[part].notes)
          (
            note.start / midi.division,
            note.duration / midi.division,
            note.pitch,
          ),
      ]);
}
