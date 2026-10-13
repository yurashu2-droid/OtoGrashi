import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/imported_score.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/midi_file.dart';
import 'package:otogurashi/domain/midi_score_data.dart';
import 'package:otogurashi/domain/public_domain_scores.dart';

// A tiny MIDI writer: each track is a name, a channel and notes given as
// [start tick, duration tick, pitch], the form the score itself uses.

typedef _Track = ({String? name, int channel, List<List<int>> notes});

_Track _track(List<List<int>> notes, {String? name, int channel = 0}) =>
    (name: name, channel: channel, notes: notes);

List<int> _vlq(int value) {
  final bytes = [value & 0x7f];
  for (var rest = value >> 7; rest > 0; rest >>= 7) {
    bytes.insert(0, rest & 0x7f | 0x80);
  }
  return bytes;
}

List<int> _chunk(String kind, List<int> body) => [
  ...ascii.encode(kind),
  for (final shift in const [24, 16, 8, 0]) body.length >> shift & 0xff,
  ...body,
];

/// A track body from events at absolute ticks. At one tick note offs go
/// first, so a repeated note is not ended by its own predecessor.
List<int> _body(List<(int, List<int>)> events) {
  final sorted = events.toList()
    ..sort(
      (a, b) => a.$1 != b.$1
          ? a.$1.compareTo(b.$1)
          : a.$2.first.compareTo(b.$2.first),
    );
  final body = <int>[];
  var last = 0;
  for (final (tick, bytes) in sorted) {
    body
      ..addAll(_vlq(tick - last))
      ..addAll(bytes);
    last = tick;
  }
  return body..addAll(const [0, 0xff, 0x2f, 0]);
}

(int, List<int>) _named(String name) =>
    (0, [0xff, 0x03, ..._vlq(utf8.encode(name).length), ...utf8.encode(name)]);

/// Format 1 puts [title], [signatures] ([tick, numerator, power of two of
/// the denominator]) and [tempos] ([tick, microseconds per beat]) on a
/// conductor track of their own; format 0 puts everything on one track.
Uint8List _midi(
  List<_Track> tracks, {
  int division = 480,
  int format = 1,
  String? title,
  List<List<int>> signatures = const [],
  List<List<int>> tempos = const [],
}) {
  final conductor = [
    if (title != null) _named(title),
    for (final [tick, numerator, power] in signatures)
      (tick, [0xff, 0x58, 4, numerator, power, 24, 8]),
    for (final [tick, micros] in tempos)
      (tick, [0xff, 0x51, 3, micros >> 16, micros >> 8 & 0xff, micros & 0xff]),
  ];
  List<(int, List<int>)> notes(_Track track) => [
    for (final [start, duration, pitch] in track.notes) ...[
      (start, [0x90 | track.channel, pitch, 100]),
      (start + duration, [0x80 | track.channel, pitch, 0]),
    ],
  ];
  final bodies = format == 0
      ? [
          _body([...conductor, for (final track in tracks) ...notes(track)]),
        ]
      : [
          _body(conductor),
          for (final track in tracks)
            _body([
              if (track.name != null) _named(track.name!),
              ...notes(track),
            ]),
        ];
  return Uint8List.fromList([
    ..._chunk('MThd', [
      0,
      format,
      0,
      bodies.length,
      division >> 8,
      division & 0xff,
    ]),
    for (final body in bodies) ..._chunk('MTrk', body),
  ]);
}

ScoreImport _import(
  List<_Track> tracks, {
  int division = 480,
  int format = 1,
  String? fileTitle,
  List<List<int>> signatures = const [],
  List<List<int>> tempos = const [],
  String? title,
  int beats = 32,
  double? startBeat,
  int? melodyPart,
  int? bassPart,
  int? chordsPart,
}) => ImportedScore.fromMidi(
  MidiFile.parse(
    _midi(
      tracks,
      division: division,
      format: format,
      title: fileTitle,
      signatures: signatures,
      tempos: tempos,
    ),
  ),
  title: title,
  beats: beats,
  startBeat: startBeat,
  melodyPart: melodyPart,
  bassPart: bassPart,
  chordsPart: chordsPart,
);

ScoreImported _imported(ScoreImport result) {
  expect(
    result,
    isA<ScoreImported>(),
    reason: result is ScoreImportFailed ? '${result.reason}' : '',
  );
  return result as ScoreImported;
}

ScoreImportFailure? _failure(ScoreImport result) =>
    result is ScoreImportFailed ? result.reason : null;

List<int?> _partsOf(ScoreImported result) => [
  result.melody.part,
  result.bass.part,
  result.chords.part,
];

List<LaneSource> _sourcesOf(ScoreImported result) => [
  result.melody.source,
  result.bass.source,
  result.chords.source,
];

MidiFile _bundled(String path) => MidiFile.parse(File(path).readAsBytesSync());

// Eight bars of a tune, a bass line, chords and a drum pattern.
final _tune = [
  for (var i = 0; i < 32; i++)
    [
      i * 480,
      400,
      72 + const [0, 2, 4, 5, 7, 5, 4, 2][i % 8],
    ],
];
final _low = [
  for (var i = 0; i < 16; i++)
    [
      i * 960,
      900,
      36 + const [0, 5, 7, 5][i % 4],
    ],
];
final _triads = [
  for (var i = 0; i < 16; i++)
    for (final pitch in const [60, 64, 67]) [i * 960, 800, pitch],
];
final _kit = [
  for (var i = 0; i < 32; i++) [i * 480, 60, i.isEven ? 36 : 38],
];

List<List<int>> _raised(List<List<int>> notes, int semitones) => [
  for (final [start, duration, pitch] in notes)
    [start, duration, pitch + semitones],
];

void main() {
  final songs = MelodyTemplate.values
      .where((song) => song.scoreId != null)
      .toList();

  group('the bundled MIDI files', () {
    test('each song comes out as its generated score', () {
      final manifest = jsonDecode(
        File('assets/music/public_domain/manifest.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final templates = (manifest['templates'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(songs, hasLength(6));
      for (final song in songs) {
        final id = song.scoreId!;
        final listed = templates.singleWhere((entry) => entry['id'] == id);
        final file = _bundled('assets/music/public_domain/$id.mid');
        final result = _imported(ImportedScore.fromMidi(file));

        expect(result.score.lanes, publicDomainScores[id], reason: id);
        expect(result.score.beats, 32);
        expect(result.score.title, listed['title'], reason: id);
        // The lanes are found by the names of the tracks, in the order
        // Melody, Bass, Chords, whatever order the file keeps them in.
        expect(_partsOf(result).map((part) => result.parts[part!].name), [
          'Melody',
          'Bass',
          'Chords',
        ]);
        expect(_sourcesOf(result), everyElement(LaneSource.name));
        expect(result.parts.map((part) => part.looksLikeDrums), [
          false,
          false,
          false,
          true,
        ]);
        // Nothing had to be changed or assumed.
        for (final (index, lane) in [
          result.melody,
          result.bass,
          result.chords,
        ].indexed) {
          expect(lane.notes, publicDomainScores[id]![index].length);
          expect(
            [lane.clipped, lane.cut, lane.dropped, lane.overLimit],
            everyElement(0),
            reason: id,
          );
        }
        expect(result.startBeat, 0);
        expect(result.barBeats, 4);
        expect(result.filledBeats, 32);
        expect(result.songBeats, 32);
        expect(result.tempoBpm, closeTo(listed['bpm'] as num, .001));
        expect(result.meterAssumed, isFalse);
        expect(result.timingRounded, isFalse);
      }
    });

    test('nameless and in one track, the notes alone give the same lanes', () {
      // Other channels and another order, so nothing but the notes can tell.
      const moved = {0: 5, 1: 0, 2: 3, 9: 9};
      for (final song in songs) {
        final file = _bundled('assets/music/public_domain/${song.scoreId}.mid');
        final copy = MidiFile.parse(
          _midi([
            for (final part in file.parts)
              _track([
                for (final note in part.notes)
                  [note.start, note.duration, note.pitch],
              ], channel: moved[part.channel]!),
          ], format: 0),
        );
        expect(copy.parts.map((part) => part.channel), [0, 3, 5, 9]);
        expect(copy.parts.map((part) => part.name), everyElement(isNull));

        final result = _imported(ImportedScore.fromMidi(copy));
        expect(result.score.lanes, song.scoreNotes, reason: song.name);
        expect(_partsOf(result), [2, 1, 0]);
        expect(_sourcesOf(result), everyElement(LaneSource.content));
        expect(result.score.title, isEmpty);
      }
    });

    test('the three-part score comes out as its first eight bars', () {
      final file = _bundled('assets/music/score_image_3part_transcription.mid');
      final result = _imported(ImportedScore.fromMidi(file));
      expect(result.score.lanes, midiScoreNotes);
      expect(_partsOf(result).map((part) => result.parts[part!].name), [
        'Melody',
        'Bass',
        'Piano',
      ]);
      // Its conductor track is called "Tempo", which is not a song title.
      expect(file.songName, 'Tempo');
      expect(result.score.title, isEmpty);
      expect(result.songBeats, closeTo(96, .1));

      // Sixteen bars begin with the same eight.
      final longer = _imported(ImportedScore.fromMidi(file, beats: 64));
      expect(longer.score.beats, 64);
      for (final (index, lane) in longer.score.lanes.indexed) {
        expect(lane.length, greaterThan(midiScoreNotes[index].length));
        expect(lane.where((note) => note[0] < 15360), midiScoreNotes[index]);
        expect(lane.every((note) => note[0] + note[1] <= 30720), isTrue);
      }
    });
  });

  group('choosing the lanes', () {
    test('track names decide, in any order, case and language', () {
      for (final names in const [
        ['Melody', 'Bass', 'Chords'],
        ['LEAD VOCAL', 'E.Bass 2', 'Grand Piano'],
        ['vox', 'Synth Bass', 'Keys'],
        ['メロディ', 'ベース', 'コード'],
        ['ボーカル', 'ウッドベース', 'ピアノ'],
      ]) {
        // The notes say otherwise: the names are believed all the same.
        final result = _imported(
          _import([
            _track(_tune, name: names[2]),
            _track(_triads, name: names[1], channel: 1),
            _track(_kit, name: 'Drums', channel: 9),
            _track(_low, name: names[0], channel: 2),
          ]),
        );
        expect(_partsOf(result), [3, 1, 0], reason: '$names');
        expect(_sourcesOf(result), everyElement(LaneSource.name));
        expect(result.score.melody, _low);
        expect(result.score.chords, _tune);
        // the bass keeps the lowest note of each chord
        expect(result.score.bass, [
          for (var i = 0; i < 16; i++) [i * 960, 800, 60],
        ]);
      }
    });

    test('names in Shift_JIS, as Japanese sequencers write them, count', () {
      List<int> track(List<int> name, List<List<int>> notes, int channel) =>
          _chunk(
            'MTrk',
            _body([
              (0, [0xff, 0x03, name.length, ...name]),
              for (final [start, duration, pitch] in notes) ...[
                (start, [0x90 | channel, pitch, 100]),
                (start + duration, [0x80 | channel, pitch, 0]),
              ],
            ]),
          );
      final file = MidiFile.parse(
        Uint8List.fromList([
          ..._chunk('MThd', [0, 1, 0, 3, 1, 0xe0]),
          ...track(const [0x83, 0x52, 0x81, 0x5b, 0x83, 0x68], _tune, 0),
          ...track(const [0x83, 0x78, 0x81, 0x5b, 0x83, 0x58], _triads, 1),
          ...track(
            const [0x83, 0x81, 0x83, 0x8d, 0x83, 0x66, 0x83, 0x42],
            _low,
            2,
          ),
        ]),
      );
      expect(file.parts.map((part) => part.name), ['コード', 'ベース', 'メロディ']);
      final result = _imported(ImportedScore.fromMidi(file));
      expect(_partsOf(result), [2, 1, 0]);
      expect(_sourcesOf(result), everyElement(LaneSource.name));
    });

    test('a name that says bass is a bass, whatever else it says', () {
      final result = _imported(
        _import([
          _track(_tune, name: 'Lead Bass'),
          _track(_low, name: 'Piano Melody', channel: 1),
        ]),
      );
      expect(_partsOf(result), [1, 0, null]);
      expect(_sourcesOf(result), [
        LaneSource.name,
        LaneSource.name,
        LaneSource.none,
      ]);
    });

    test('without telling names the notes decide', () {
      final result = _imported(
        _import([
          _track(_kit, name: 'Track 1', channel: 9),
          // higher on average than the tune, but chords
          _track(_raised(_triads, 24), name: 'Track 2'),
          _track(_low, name: 'Track 3', channel: 1),
          _track(_tune, name: 'Track 4', channel: 2),
        ]),
      );
      expect(_partsOf(result), [3, 2, 1]);
      expect(_sourcesOf(result), everyElement(LaneSource.content));
      expect(result.score.lanes, [_tune, _low, _raised(_triads, 24)]);
    });

    test('of several parts with the same name the notes pick one', () {
      final result = _imported(
        _import([
          _track(_low, name: 'Piano'),
          _track(_triads, name: 'Piano', channel: 1),
          _track(_tune, name: 'Piano', channel: 2),
        ]),
      );
      // The chords are the one with the most notes together; of the other
      // two the lower is kept for the bass.
      expect(_partsOf(result), [2, 0, 1]);
      expect(_sourcesOf(result), [
        LaneSource.content,
        LaneSource.content,
        LaneSource.name,
      ]);
    });

    test(
      'the lowest part is the bass even when it alone sounds like a tune',
      () {
        final result = _imported(
          _import([_track(_low), _track(_triads, channel: 1)]),
        );
        expect(_partsOf(result), [1, 0, null]);
        expect(_sourcesOf(result), [
          LaneSource.content,
          LaneSource.content,
          LaneSource.none,
        ]);
        // the melody is the top of the chords
        expect(result.score.melody, [
          for (var i = 0; i < 16; i++) [i * 960, 800, 67],
        ]);
        expect(result.score.bass, _low);
        expect(result.score.chords, isEmpty);
        expect(result.chords.notes, 0);
      },
    );

    test('a single part is the melody, whatever it is called', () {
      for (final name in const [null, 'Piano', 'Bass', 'Chords']) {
        final result = _imported(_import([_track(_triads, name: name)]));
        expect(_partsOf(result), [0, null, null], reason: '$name');
        expect(_sourcesOf(result), [
          LaneSource.content,
          LaneSource.none,
          LaneSource.none,
        ]);
        expect(result.score.melody, hasLength(16));
        expect(result.score.bass, isEmpty);
        expect(result.score.chords, isEmpty);
      }
    });

    test('a piano and a bass: the piano has the tune', () {
      final result = _imported(
        _import([
          _track(_low, name: 'Bass'),
          _track(_triads, name: 'Piano', channel: 1),
        ]),
      );
      expect(_partsOf(result), [1, 0, null]);
      expect(_sourcesOf(result), [
        LaneSource.content,
        LaneSource.name,
        LaneSource.none,
      ]);
    });

    test('drums are passed over, by channel or by name', () {
      final result = _imported(
        _import([
          _track(_kit, channel: 9),
          _track(_raised(_kit, 40), name: 'ドラム', channel: 3),
          _track(_raised(_kit, 50), name: 'Percussion', channel: 4),
          _track(_tune, channel: 1),
        ]),
      );
      expect(result.parts.map((part) => part.looksLikeDrums), [
        true,
        true,
        true,
        false,
      ]);
      expect(_partsOf(result), [3, null, null]);
    });

    test('the caller can put any part on any lane', () {
      final tracks = [
        _track(_tune, name: 'Melody'),
        _track(_low, name: 'Bass', channel: 1),
        _track(_triads, name: 'Chords', channel: 2),
        _track(_kit, name: 'Rhythm', channel: 9),
      ];
      // all three, against the names
      var result = _imported(
        _import(tracks, melodyPart: 2, bassPart: 0, chordsPart: 1),
      );
      expect(_partsOf(result), [2, 0, 1]);
      expect(_sourcesOf(result), everyElement(LaneSource.caller));
      expect(result.score.chords, _low);

      // one of them: the others are chosen as if that part were not there
      result = _imported(_import(tracks, bassPart: 2));
      expect(_partsOf(result), [0, 2, 1]);
      expect(_sourcesOf(result), [
        LaneSource.name,
        LaneSource.caller,
        LaneSource.content,
      ]);

      // a lane left out on purpose
      result = _imported(_import(tracks, chordsPart: ImportedScore.emptyLane));
      expect(_partsOf(result), [0, 1, null]);
      expect(result.chords.source, LaneSource.caller);
      expect(result.score.chords, isEmpty);

      // one part on two lanes: top line and bottom line of the chords
      result = _imported(
        _import(
          tracks,
          melodyPart: 2,
          bassPart: 2,
          chordsPart: ImportedScore.emptyLane,
        ),
      );
      expect(result.score.melody.map((note) => note[2]), everyElement(67));
      expect(result.score.bass.map((note) => note[2]), everyElement(60));

      // even the drums
      result = _imported(_import(tracks, melodyPart: 3));
      expect(result.melody.part, 3);
      expect(result.score.melody, hasLength(32));

      // a bass taken by the caller leaves the melody what remains
      result = _imported(_import([_track(_triads)], bassPart: 0));
      expect(_partsOf(result), [0, 0, null]);
    });

    test('arguments that make no sense throw', () {
      final tracks = [_track(_tune), _track(_low, channel: 1)];
      expect(() => _import(tracks, melodyPart: 2), throwsRangeError);
      expect(() => _import(tracks, chordsPart: -2), throwsRangeError);
      expect(
        () => _import(tracks, melodyPart: ImportedScore.emptyLane),
        throwsRangeError,
      );
      expect(() => _import(tracks, beats: 16), throwsArgumentError);
      expect(() => _import(tracks, startBeat: -1), throwsArgumentError);
      expect(() => _import(tracks, startBeat: double.nan), throwsArgumentError);
      expect(
        () => _import(tracks, startBeat: double.infinity),
        throwsArgumentError,
      );
    });

    test('every part is listed for a screen to offer', () {
      final result = _imported(
        _import([
          _track(_tune, name: 'Flute', channel: 4),
          _track(_kit, name: 'Kit', channel: 9),
          _track(_low, channel: 1),
        ]),
      );
      expect(
        result.parts.map(
          (part) => [
            part.index,
            part.name,
            part.channel,
            part.noteCount,
            part.lowestPitch,
            part.highestPitch,
            part.looksLikeDrums,
          ],
        ),
        [
          [0, 'Flute', 4, 32, 72, 79, false],
          [1, 'Kit', 9, 32, 36, 38, true],
          [2, null, 1, 16, 36, 43, false],
        ],
      );
    });
  });

  group('the window', () {
    // An introduction of two bars before the tune comes in on beat 9.5.
    final late = [
      for (var i = 0; i < 40; i++) [4560 + i * 480, 240, 72 + i % 5],
    ];
    final pedal = [
      for (var i = 0; i < 24; i++) [i * 960, 960, 36 + i % 3],
    ];

    test('starts with the bar in which the melody first sounds', () {
      final result = _imported(
        _import([
          _track(late, name: 'Melody'),
          _track(pedal, name: 'Bass', channel: 1),
        ]),
      );
      expect(result.startBeat, 8);
      expect(result.barBeats, 4);
      expect(result.meterAssumed, isTrue);
      expect(result.songBeats, 49);
      // Everything moves so that the window starts at tick 0.
      expect(result.score.melody, [
        for (var i = 0; i < 31; i++) [720 + i * 480, 240, 72 + i % 5],
      ]);
      expect(result.score.bass, [
        for (var i = 4; i < 20; i++) [(i - 4) * 960, 960, 36 + i % 3],
      ]);
      expect(result.filledBeats, 32);
      // What lies outside is not counted as dropped.
      expect(result.melody.dropped, 0);
      expect(result.bass.dropped, 0);
    });

    test('does not start at a note too short to keep', () {
      final result = _imported(
        _import([
          _track([
            [100, 5, 90],
            for (var i = 0; i < 8; i++) [7920 + i * 480, 480, 60 + i],
          ]),
        ]),
      );
      expect(result.startBeat, 16);
      expect(result.score.melody.first, [240, 480, 60]);
    });

    test('counts bars by the time signatures of the file', () {
      // 3/4: beat 9.5 is in the bar that starts at beat 9.
      var result = _imported(
        _import(
          [_track(late)],
          signatures: [
            [0, 3, 2],
          ],
        ),
      );
      expect([result.startBeat, result.barBeats], [9, 3]);
      expect(result.meterAssumed, isFalse);
      expect(result.score.melody.first, [240, 240, 72]);

      // 7/8: bars of three and a half beats, so beat 9.5 is in the bar at 7.
      result = _imported(
        _import(
          [_track(late)],
          signatures: [
            [0, 7, 3],
          ],
        ),
      );
      expect([result.startBeat, result.barBeats], [7, 3.5]);
      expect(result.score.melody.first, [1200, 240, 72]);

      // Two bars of 4/4, then 6/8 from beat 8: bars of three beats from there.
      result = _imported(
        _import(
          [
            _track([
              for (var i = 0; i < 20; i++) [6000 + i * 480, 240, 72],
            ]),
          ],
          signatures: [
            [0, 4, 2],
            [3840, 6, 3],
          ],
        ),
      );
      expect([result.startBeat, result.barBeats], [11, 3]);

      // A signature that only comes later does not reach back.
      result = _imported(
        _import(
          [_track(late)],
          signatures: [
            [19200, 3, 2],
          ],
        ),
      );
      expect([result.startBeat, result.barBeats], [8, 4]);
      expect(result.meterAssumed, isTrue);
    });

    test('starts where the caller says', () {
      final tracks = [_track(late), _track(pedal, channel: 1)];
      var result = _imported(_import(tracks, startBeat: 16));
      expect(result.startBeat, 16);
      expect(result.score.melody.first, [240, 240, 74]);
      expect(result.score.bass.first, [0, 960, 38]);
      expect(result.filledBeats, 32);

      // near the end: the song is over before the window is
      result = _imported(_import(tracks, startBeat: 40));
      expect(result.melody.notes, 9);
      expect(result.bass.notes, 4);
      expect(result.filledBeats, 9);

      // not on a beat, and before the melody comes in
      result = _imported(_import(tracks, startBeat: 0.25));
      expect(result.startBeat, .25);
      expect(result.score.melody.first, [4440, 240, 72]);
      // the bass note at tick 0 started before the window and is left out
      expect(result.score.bass.first, [840, 960, 37]);
    });

    test('leaves out what starts outside and clips what runs past the end', () {
      final result = _imported(
        _import([
          _track([
            [1800, 400, 70], // sounds into the window but starts before it
            [1920, 480, 72],
            [9000, 600, 73],
            [17000, 1000, 74], // runs past the end
            [17280, 480, 76], // starts at the end
            [20000, 480, 77],
          ]),
        ], startBeat: 4),
      );
      expect(result.score.melody, [
        [0, 480, 72],
        [7080, 600, 73],
        [15080, 280, 74],
      ]);
      expect(result.melody.notes, 3);
      expect(result.melody.clipped, 1);
      expect(result.melody.dropped, 0);
      expect(result.filledBeats, 32);
    });

    test('is 64 beats when asked', () {
      final long = [
        for (var i = 0; i < 80; i++) [i * 480, 480, 60 + i % 12],
      ];
      final result = _imported(_import([_track(long)], beats: 64));
      expect(result.score.beats, 64);
      expect(result.score.melody, long.take(64));
      expect(_imported(_import([_track(long)])).score.melody, long.take(32));
    });

    test('reports the tempo of the file where it starts', () {
      final tempos = [
        [0, 500000],
        [3840, 750000],
        [9600, 250000],
      ];
      expect(_imported(_import([_track(late)], tempos: tempos)).tempoBpm, 80);
      expect(
        _imported(_import([_track(late)], tempos: tempos, startBeat: 0))
            .tempoBpm,
        120,
      );
      expect(_imported(_import([_track(late)])).tempoBpm, 120);
    });
  });

  group('timing', () {
    test('is exact when the division divides a beat into 480', () {
      final result = _imported(
        _import([
          _track([
            [0, 96, 60],
            [96, 48, 62],
            [156, 12, 64],
            [191, 1, 65],
            [192, 192, 67],
          ]),
        ], division: 96),
      );
      expect(result.score.melody, [
        [0, 480, 60],
        [480, 240, 62],
        [780, 60, 64],
        [960, 960, 67],
      ]);
      expect(result.timingRounded, isFalse);
      // one tick of 96 is five of 480: too short to keep
      expect(result.melody.dropped, 1);
    });

    test('is exact for a finer division whenever the ticks allow', () {
      final result = _imported(
        _import([
          _track([
            [0, 1920, 60],
            [1920, 960, 62],
            [3840, 3840, 64],
          ]),
        ], division: 1920),
      );
      expect(result.score.melody, [
        [0, 480, 60],
        [480, 240, 62],
        [960, 960, 64],
      ]);
      expect(result.timingRounded, isFalse);
    });

    test('is rounded to the nearest tick otherwise', () {
      var result = _imported(
        _import([
          _track([
            [0, 100, 60], // 480
            [100, 33, 62], // 480 + 158.4
            [133, 67, 64], // 638.4 to 960
            [200, 400, 65],
          ]),
        ], division: 100),
      );
      expect(result.score.melody, [
        [0, 480, 60],
        [480, 158, 62],
        [638, 322, 64],
        [960, 1920, 65],
      ]);
      expect(result.timingRounded, isTrue);

      // Halves round up, and notes that touch still touch.
      result = _imported(
        _import([
          _track([
            [0, 961, 60],
            [961, 961, 62],
            [1922, 1918, 64],
          ]),
        ], division: 960),
      );
      expect(result.score.melody, [
        [0, 481, 60],
        [481, 480, 62],
        [961, 959, 64],
      ]);
      expect(result.timingRounded, isTrue);
      expect(result.melody.cut, 0);
    });
  });

  group('one note at a time', () {
    final voices = [
      // a chord
      [0, 480, 60], [0, 480, 64], [0, 480, 67],
      // a low note held while a higher one starts
      [960, 960, 60], [1440, 480, 72],
      // a low note that starts under a higher one and outlasts it
      [2880, 480, 76], [3120, 720, 65],
      // a low note that starts and ends under a higher one
      [4800, 960, 79], [5040, 240, 62],
      // a low note held long after a higher one has come and gone
      [6720, 1920, 55], [7200, 480, 74],
      // a chord rolled upwards, ten ticks apart
      [9600, 480, 60], [9610, 470, 64], [9620, 460, 67],
    ];

    test('the melody keeps the higher note', () {
      final result = _imported(_import([_track(voices)]));
      expect(result.score.melody, [
        [0, 480, 67],
        [960, 480, 60], // stops where the higher one starts
        [1440, 480, 72],
        [2880, 480, 76],
        [3360, 480, 65], // waits for the higher one to end
        [4800, 960, 79],
        [6720, 480, 55], // and does not sound again afterwards
        [7200, 480, 74],
        [9620, 460, 67], // the stubs of the roll are too short to keep
      ]);
      expect(result.melody.notes, 9);
      expect(result.melody.cut, 3);
      expect(result.melody.dropped, 5);
    });

    test('the bass keeps the lower note', () {
      final result = _imported(
        _import([_track(voices)], melodyPart: 0, bassPart: 0),
      );
      expect(result.score.bass, [
        [0, 480, 60],
        [960, 960, 60],
        [2880, 240, 76],
        [3120, 720, 65],
        [4800, 240, 79],
        [5040, 240, 62],
        [6720, 1920, 55],
        [9600, 480, 60],
      ]);
      expect(result.bass.notes, 8);
      expect(result.bass.cut, 2);
      expect(result.bass.dropped, 6);
    });

    test('the chords keep every note, in the order of the bundled scores', () {
      final result = _imported(
        _import([
          _track(_tune),
          _track([
            [0, 480, 67],
            [0, 480, 60],
            [0, 240, 72],
            [0, 480, 64],
            [240, 240, 59],
            [240, 240, 71],
          ], channel: 1),
        ], chordsPart: 1),
      );
      // by start, then duration, then pitch
      expect(result.score.chords, [
        [0, 240, 72],
        [0, 480, 60],
        [0, 480, 64],
        [0, 480, 67],
        [240, 240, 59],
        [240, 240, 71],
      ]);
      expect([result.chords.cut, result.chords.dropped], [0, 0]);
    });

    test('a note too short to hear neither stays nor cuts another', () {
      final result = _imported(
        _import([
          _track([
            [0, 1920, 60],
            [100, 14, 84], // a glitch above the held note
            [1920, 15, 62], // a 128th note: the shortest that stays
            [2400, 14, 64],
            // clipped to less than that by the end of the window
            [15350, 400, 65],
          ]),
        ]),
      );
      expect(result.score.melody, [
        [0, 1920, 60],
        [1920, 15, 62],
      ]);
      expect(result.melody.dropped, 3);
      expect(result.melody.cut, 0);
      expect(result.melody.clipped, 0);
    });
  });

  group('limits', () {
    test('a lane holds no more than maxLaneNotes', () {
      final many = [
        for (var i = 0; i < 600; i++) [i * 24, 24, 60 + i % 24],
      ];
      final result = _imported(
        _import([_track(many), _track(many, channel: 1)], chordsPart: 1),
      );
      expect(ImportedScore.maxLaneNotes, 512);
      for (final (lane, report) in [
        (result.score.melody, result.melody),
        (result.score.chords, result.chords),
      ]) {
        expect(lane, many.take(512));
        expect(report.notes, 512);
        expect(report.overLimit, 88);
        expect(report.dropped, 0);
      }
    });

    test('the title comes from the caller, else from the file', () {
      String titleOf(ScoreImport result) => _imported(result).score.title;
      final tracks = [_track(_tune, name: 'Flute')];

      expect(titleOf(_import(tracks, fileTitle: '  きらきら星 ')), 'きらきら星');
      expect(titleOf(_import(tracks, fileTitle: 'A', title: ' B\n C ')), 'B C');
      expect(titleOf(_import(tracks)), isEmpty);
      // Names that only say what the track is are not titles.
      expect(titleOf(_import(tracks, fileTitle: 'Tempo Track')), isEmpty);
      expect(titleOf(_import(tracks, fileTitle: 'untitled')), isEmpty);
      // but the caller may call the song that
      expect(titleOf(_import(tracks, title: 'Tempo')), 'Tempo');
      // In format 0 the only track is named after the song.
      expect(titleOf(_import(tracks, format: 0, fileTitle: 'Canon')), 'Canon');
      // A first track with notes is named after its instrument.
      final noConductor = Uint8List.fromList([
        ..._chunk('MThd', [0, 1, 0, 1, 1, 0xe0]),
        ..._chunk(
          'MTrk',
          _body([
            _named('Piano'),
            (0, [0x90, 60, 100]),
            (1920, [0x80, 60, 0]),
          ]),
        ),
      ]);
      expect(
        titleOf(ImportedScore.fromMidi(MidiFile.parse(noConductor))),
        isEmpty,
      );
      // Forty characters at most, counted as whole characters.
      expect(titleOf(_import(tracks, title: '長い' * 30)), '長い' * 20);
      expect(titleOf(_import(tracks, title: '🎵' * 50)), '🎵' * 40);
      expect(titleOf(_import(tracks, fileTitle: 'x' * 70)), 'x' * 40);
    });
  });

  group('what cannot be imported says why', () {
    test('no notes at all', () {
      final empty = ImportedScore.fromMidi(
        MidiFile.parse(
          Uint8List.fromList(_chunk('MThd', [0, 1, 0, 0, 1, 0xe0])),
        ),
      );
      expect(_failure(empty), ScoreImportFailure.noNotes);
      expect(empty.parts, isEmpty);
      expect(empty.songBeats, 0);
      // a conductor track alone
      expect(
        _failure(_import(const [], fileTitle: 'Silence')),
        ScoreImportFailure.noNotes,
      );
      // part numbers mean nothing in such a file
      expect(
        _failure(_import(const [], melodyPart: 3)),
        ScoreImportFailure.noNotes,
      );
    });

    test('only drums', () {
      final tracks = [
        _track(_kit, channel: 9),
        _track(_kit, name: 'Drums', channel: 1),
      ];
      final result = _import(tracks);
      expect(_failure(result), ScoreImportFailure.onlyDrums);
      // The parts are still there to choose from, and choosing one works.
      expect(result.parts, hasLength(2));
      expect(result.songBeats, closeTo(31.125, .001));
      expect(_imported(_import(tracks, melodyPart: 1)).melody.part, 1);
      // Putting them elsewhere does not make a melody.
      expect(
        _failure(_import(tracks, bassPart: 0)),
        ScoreImportFailure.onlyDrums,
      );
    });

    test('nothing of the melody in the window', () {
      final tracks = [
        _track(_tune.take(8).toList(), name: 'Melody'),
        _track(
          [
            ..._low,
            for (final [start, duration, pitch] in _low)
              [start + 15360, duration, pitch],
          ],
          name: 'Bass',
          channel: 1,
        ),
      ];
      expect(_imported(_import(tracks)).melody.notes, 8);
      // the bass plays on, the melody is over
      final later = _import(tracks, startBeat: 32);
      expect(_failure(later), ScoreImportFailure.emptyWindow);
      expect(later.parts, hasLength(2));
      // past the end of the file
      expect(
        _failure(_import(tracks, startBeat: 64)),
        ScoreImportFailure.emptyWindow,
      );
      expect(
        _failure(_import(tracks, startBeat: 1e300)),
        ScoreImportFailure.emptyWindow,
      );
      // only notes too short to keep
      expect(
        _failure(
          _import([
            _track([
              [0, 5, 60],
              [480, 5, 62],
            ]),
          ]),
        ),
        ScoreImportFailure.emptyWindow,
      );
    });

    test('too short to fill one bar', () {
      List<_Track> lasting(int ticks) => [
        _track([
          [0, ticks, 60],
        ]),
      ];
      expect(_failure(_import(lasting(480))), ScoreImportFailure.tooShort);
      expect(_failure(_import(lasting(1919))), ScoreImportFailure.tooShort);
      final oneBar = _imported(_import(lasting(1920)));
      expect(oneBar.filledBeats, 4);
      expect(oneBar.score.melody, [
        [0, 1920, 60],
      ]);
      // a bar of 3/4 is shorter
      const waltz = [
        [0, 3, 2],
      ];
      expect(
        _failure(_import(lasting(1439), signatures: waltz)),
        ScoreImportFailure.tooShort,
      );
      expect(_imported(_import(lasting(1440), signatures: waltz)).barBeats, 3);
      // Any lane counts: a long bass note under a short melody is enough.
      expect(
        _imported(
          _import([
            ...lasting(480),
            _track([
              [0, 3840, 48],
            ], channel: 1),
          ]),
        ).filledBeats,
        8,
      );
      // what is left after a late start may be too little
      expect(
        _failure(_import([_track(_tune)], startBeat: 30)),
        ScoreImportFailure.tooShort,
      );
    });
  });

  group('JSON', () {
    ImportedScore score() => _imported(
      _import([
        _track(_tune, name: 'Melody'),
        _track(_low, name: 'Bass', channel: 1),
        _track(_triads, name: 'Chords', channel: 2),
      ], fileTitle: 'きらきら星'),
    ).score;

    test('a score survives being stored and sent', () {
      final original = score();
      final json = original.toJson();
      expect(json.keys, ['schemaVersion', 'title', 'beats', 'lanes']);
      expect(json['schemaVersion'], 1);

      final restored = ImportedScore.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, Object?>,
      );
      expect(restored.title, 'きらきら星');
      expect(restored.beats, 32);
      expect(restored.lanes, [_tune, _low, _triads]);
      expect(restored.toJson(), json);
      expect(restored.melody, same(restored.lanes[0]));
      expect(restored.bass, same(restored.lanes[1]));
      expect(restored.chords, same(restored.lanes[2]));

      // every bundled score is a valid score
      for (final song in MelodyTemplate.values.where((s) => s.isMidiScore)) {
        final bundled = ImportedScore(
          title: song.label,
          beats: 32,
          lanes: song.scoreNotes,
        );
        expect(
          ImportedScore.fromJson(
            jsonDecode(jsonEncode(bundled.toJson())) as Map<String, Object?>,
          ).lanes,
          song.scoreNotes,
        );
      }
    });

    test('a score cannot be changed after the fact', () {
      final lanes = [
        [
          [0, 480, 60],
        ],
        <List<int>>[],
        <List<int>>[],
      ];
      final made = ImportedScore(title: '', beats: 32, lanes: lanes);
      lanes[0][0][2] = 99;
      lanes[1].add([0, 480, 40]);
      expect(made.lanes, [
        [
          [0, 480, 60],
        ],
        isEmpty,
        isEmpty,
      ]);
      expect(() => made.lanes.add([]), throwsUnsupportedError);
      expect(() => made.melody.add([0, 1, 2]), throwsUnsupportedError);
      expect(() => made.melody[0][2] = 61, throwsUnsupportedError);
    });

    test('invalid JSON is rejected', () {
      Map<String, Object?> valid() =>
          jsonDecode(jsonEncode(score().toJson())) as Map<String, Object?>;
      List<Object?> lanesOf(Map<String, Object?> json) =>
          json['lanes'] as List<Object?>;
      List<Object?> laneOf(Map<String, Object?> json, int lane) =>
          lanesOf(json)[lane] as List<Object?>;

      final broken = <String, void Function(Map<String, Object?>)>{
        'no version': (json) => json.remove('schemaVersion'),
        'a later version': (json) => json['schemaVersion'] = 2,
        'no title': (json) => json.remove('title'),
        'a title that is not text': (json) => json['title'] = 7,
        'a title too long': (json) => json['title'] = 'x' * 41,
        'no length': (json) => json.remove('beats'),
        'a length that is not whole': (json) => json['beats'] = 32.0,
        'a length the app does not play': (json) => json['beats'] = 16,
        'no lanes': (json) => json.remove('lanes'),
        'lanes that are not a list': (json) => json['lanes'] = {'melody': []},
        'two lanes': (json) => lanesOf(json).removeLast(),
        'four lanes': (json) => lanesOf(json).add(<Object?>[]),
        'a lane that is not a list': (json) => lanesOf(json)[1] = 'bass',
        'no melody': (json) => laneOf(json, 0).clear(),
        'a note that is not a list': (json) => laneOf(json, 2)[0] = 60,
        'a note of two values': (json) => laneOf(json, 2)[0] = [0, 480],
        'a note of four values': (json) =>
            laneOf(json, 2)[0] = [0, 480, 60, 100],
        'a value that is not whole': (json) =>
            laneOf(json, 2)[0] = [0, 480.5, 60],
        'a value that is text': (json) => laneOf(json, 2)[0] = [0, '480', 60],
        'a null value': (json) => laneOf(json, 2)[0] = [0, null, 60],
        'a negative start': (json) => laneOf(json, 2)[0] = [-1, 480, 60],
        'no duration': (json) => laneOf(json, 2)[0] = [0, 0, 60],
        'a duration too short to hear': (json) =>
            laneOf(json, 2)[0] = [0, 14, 60],
        'a negative duration': (json) => laneOf(json, 2)[0] = [0, -480, 60],
        'a pitch below the MIDI range': (json) =>
            laneOf(json, 2)[0] = [0, 480, -1],
        'a pitch above the MIDI range': (json) =>
            laneOf(json, 2)[0] = [0, 480, 128],
        'a note past the end': (json) => laneOf(json, 2).add([15000, 361, 60]),
        'a note starting after the end': (json) =>
            laneOf(json, 2).add([15360, 480, 60]),
        'a huge start': (json) =>
            laneOf(json, 2).add([0x7fffffffffffffff, 480, 60]),
        'notes out of order': (json) =>
            laneOf(json, 2).insert(1, [5000, 480, 60]),
        'a melody of two notes at once': (json) =>
            laneOf(json, 0).insert(1, [240, 100, 80]),
        'a bass of two notes at once': (json) =>
            laneOf(json, 1).insert(1, [899, 30, 30]),
        'too many notes': (json) => lanesOf(json)[2] = [
          for (var i = 0; i < 513; i++) [i * 20, 20, 60],
        ],
      };
      for (final MapEntry(key: what, value: damage) in broken.entries) {
        final json = valid();
        damage(json);
        expect(
          () => ImportedScore.fromJson(json),
          throwsFormatException,
          reason: what,
        );
      }
      // A length the app does not play is refused even when the notes fit.
      expect(
        () => ImportedScore(
          title: '',
          beats: 16,
          lanes: const [
            [
              [0, 480, 60],
            ],
            [],
            [],
          ],
        ),
        throwsFormatException,
      );
      // The same rules, less the mistake, pass.
      final json = valid();
      laneOf(json, 2).add([15000, 360, 60]);
      laneOf(json, 0).insert(1, [400, 80, 80]);
      lanesOf(json)[1] = <Object?>[];
      expect(ImportedScore.fromJson(json).chords.last, [15000, 360, 60]);
    });
  });

  test('whatever the file, the import returns a valid score or a reason', () {
    final random = Random(20261014);
    var imported = 0;
    final failures = <ScoreImportFailure>{};
    void run(MidiFile file) {
      final count = file.parts.length;
      int? pick() => count == 0 || random.nextInt(3) > 0
          ? null
          : random.nextInt(count + 1) - 1;
      final melody = pick();
      final result = ImportedScore.fromMidi(
        file,
        beats: random.nextBool() ? 32 : 64,
        startBeat: random.nextInt(3) == 0 ? random.nextInt(40) / 2 : null,
        melodyPart: melody == ImportedScore.emptyLane ? null : melody,
        bassPart: pick(),
        chordsPart: pick(),
      );
      expect(result.parts, hasLength(count));
      switch (result) {
        case ScoreImported(:final score):
          imported++;
          // The constructor checks every rule of a score once more.
          expect(ImportedScore.fromJson(score.toJson()).lanes, score.lanes);
          expect(result.filledBeats, lessThanOrEqualTo(score.beats));
          for (final (lane, report) in [
            (score.melody, result.melody),
            (score.bass, result.bass),
            (score.chords, result.chords),
          ]) {
            expect(report.notes, lane.length);
            if (report.part == null) expect(lane, isEmpty);
          }
        case ScoreImportFailed(:final reason):
          failures.add(reason);
      }
    }

    // Songs of random notes in random parts, divisions and meters.
    for (var round = 0; round < 300; round++) {
      final division = const [
        24,
        96,
        100,
        384,
        480,
        960,
        1000,
      ][random.nextInt(7)];
      final beat = division;
      run(
        MidiFile.parse(
          _midi(
            [
              for (var part = random.nextInt(5); part > 0; part--)
                _track(
                  [
                    for (var note = random.nextInt(120); note > 0; note--)
                      [
                        random.nextInt(48 * beat),
                        1 + random.nextInt(2 * beat),
                        random.nextInt(128),
                      ],
                  ],
                  name: const [
                    null,
                    'Melody',
                    'Bass',
                    'Piano',
                    'Drums',
                  ][random.nextInt(5)],
                  channel: const [0, 1, 2, 9][random.nextInt(4)],
                ),
            ],
            division: division,
            format: random.nextInt(2),
            signatures: [
              if (random.nextBool())
                [0, 1 + random.nextInt(12), random.nextInt(5)],
            ],
          ),
        ),
      );
    }
    // A bundled song with a few bytes changed.
    final bytes = File('assets/music/public_domain/canon_in_d.mid')
        .readAsBytesSync();
    for (var round = 0; round < 2000; round++) {
      final damaged = Uint8List.fromList(bytes);
      for (var i = random.nextInt(4); i >= 0; i--) {
        damaged[random.nextInt(damaged.length)] = random.nextInt(256);
      }
      try {
        run(MidiFile.parse(damaged));
      } on FormatException {
        // not a file the reader accepts
      }
    }
    expect(imported, greaterThan(300));
    expect(failures, containsAll(ScoreImportFailure.values));
  });
}
