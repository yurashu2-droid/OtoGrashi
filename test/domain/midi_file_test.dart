import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/midi_file.dart';

// A tiny MIDI writer: tracks are runs of events, each a delta time and bytes.

/// A variable-length quantity, seven bits per byte.
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

List<int> _header(int format, int trackCount, int division) => _chunk('MThd', [
  0,
  format,
  trackCount >> 8,
  trackCount & 0xff,
  division >> 8,
  division & 0xff,
]);

Uint8List _midi(List<List<int>> tracks, {int format = 1, int division = 480}) =>
    Uint8List.fromList([
      ..._header(format, tracks.length, division),
      for (final track in tracks) ..._chunk('MTrk', track),
    ]);

List<int> _at(int delta, List<int> bytes) => [..._vlq(delta), ...bytes];

List<int> _meta(int delta, int type, List<int> data) =>
    _at(delta, [0xff, type, ..._vlq(data.length), ...data]);

List<int> _name(String text) => _meta(0, 0x03, utf8.encode(text));

final _end = _meta(0, 0x2f, const []);

/// One note with explicit note on and note off, [length] ticks long.
List<int> _note(int delta, int pitch, int length, {int channel = 0}) => [
  ..._at(delta, [0x90 | channel, pitch, 100]),
  ..._at(length, [0x80 | channel, pitch, 0]),
];

List<List<int>> _notes(Iterable<MidiNote> notes) => [
  for (final note in notes)
    [note.start, note.duration, note.pitch, note.velocity, note.channel],
];

/// A file that uses a bit of everything, for cutting and damaging.
Uint8List _sample() => _midi([
  [
    ..._name('Song'),
    ..._meta(0, 0x51, [0x07, 0x27, 0x0e]),
    ..._meta(0, 0x58, [4, 2, 24, 8]),
    ..._meta(1920, 0x2f, const []),
  ],
  [
    ..._name('Melody'),
    ..._at(0, [0xc0, 0]),
    ..._at(0, [0x90, 60, 100]),
    ..._at(480, [60, 0]),
    ..._at(0, [62, 90]),
    ..._at(200, [0xf0, 3, 0x7e, 0x7f, 0xf7]),
    ..._at(280, [0x80, 62, 0]),
    ..._meta(0, 0x7f, [1, 2, 3]),
    ..._note(0, 64, 960),
    ..._end,
  ],
]);

void main() {
  test('reads the division, track names and notes', () {
    final file = MidiFile.parse(
      _midi([
        [..._name('歓喜の歌'), ..._meta(960, 0x2f, const [])],
        [
          ..._name('Melody'),
          ..._at(0, [0x90, 60, 100]),
          ..._at(96, [0x80, 60, 0]),
          ..._at(0, [0x93, 67, 45]),
          ..._at(48, [0x83, 67, 64]),
          ..._end,
        ],
      ], division: 96),
    );
    expect(file.format, 1);
    expect(file.division, 96);
    expect(file.tracks.map((track) => track.name), ['歓喜の歌', 'Melody']);
    expect(file.tracks.first.notes, isEmpty);
    expect(_notes(file.tracks.last.notes), [
      [0, 96, 60, 100, 0],
      [96, 48, 67, 45, 3],
    ]);
    expect(file.tracks.last.notes.last.end, 144);
    // The conductor track names the song and is not an instrument.
    expect(file.songName, '歓喜の歌');
    expect(file.parts.map((part) => [part.track, part.channel, part.name]), [
      [1, 0, 'Melody'],
      [1, 3, 'Melody'],
    ]);
    expect(file.tempos, isEmpty);
    expect(file.timeSignatures, isEmpty);
  });

  test('running status repeats the last channel status', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._at(0, [0x90, 60, 100]),
          ..._at(480, [60, 0]),
          ..._at(0, [62, 100]),
          // a meta event in between does not cancel it
          ..._meta(240, 0x01, utf8.encode('text')),
          ..._at(240, [62, 0]),
          ..._at(0, [64, 70]),
          ..._at(120, [0x80, 64, 0]),
          ..._at(0, [65, 0]),
          ..._end,
        ],
      ]),
    );
    expect(_notes(file.tracks.single.notes), [
      [0, 480, 60, 100, 0],
      [480, 480, 62, 100, 0],
      [960, 120, 64, 70, 0],
    ]);
  });

  test('a note on with velocity 0 is a note off', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._at(0, [0x92, 48, 1]),
          ..._at(10, [0x92, 48, 0]),
          ..._at(0, [0x92, 50, 127]),
          ..._at(20, [0x82, 50, 0]),
          ..._end,
        ],
      ]),
    );
    expect(_notes(file.tracks.single.notes), [
      [0, 10, 48, 1, 2],
      [10, 20, 50, 127, 2],
    ]);
  });

  test('every other channel message is read past by its own length', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._at(0, [0xc0, 5]), // program change: one data byte
          ..._at(0, [6]),
          ..._at(0, [0xd0, 64]), // channel pressure: one
          ..._at(0, [65]),
          ..._at(0, [0xb0, 7, 100]), // control change: two
          ..._at(0, [10, 64]),
          ..._at(0, [0xe0, 0, 64]), // pitch bend: two
          ..._at(0, [1, 64]),
          ..._at(0, [0xa0, 60, 5]), // key pressure: two
          ..._at(0, [60, 6]),
          ..._note(100, 60, 50),
          ..._at(0, [0xb0, 64, 127]),
          ..._at(0, [0x90, 72, 80]),
          ..._at(30, [0xe0, 0, 0]),
          ..._at(30, [0x80, 72, 0]),
          ..._end,
        ],
      ]),
    );
    expect(_notes(file.tracks.single.notes), [
      [100, 50, 60, 100, 0],
      [150, 60, 72, 80, 0],
    ]);
  });

  test('a format 0 track is split into one part per channel', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._name('Song'),
          ..._at(0, [0x90, 72, 100]),
          ..._at(0, [0x99, 36, 110]),
          ..._at(0, [0x92, 40, 90]),
          ..._at(60, [0x89, 36, 0]),
          ..._at(420, [0x80, 72, 0]),
          ..._at(0, [0x90, 74, 100]),
          ..._at(480, [0x80, 74, 0]),
          ..._at(0, [0x82, 40, 0]),
          ..._end,
        ],
      ], format: 0),
    );
    expect(file.format, 0);
    expect(file.tracks, hasLength(1));
    expect(file.tracks.single.notes, hasLength(4));
    // The only track is named after the song, not after an instrument.
    expect(file.songName, 'Song');
    expect(file.parts.map((part) => [part.track, part.channel, part.name]), [
      [0, 0, null],
      [0, 2, null],
      [0, 9, null],
    ]);
    expect(_notes(file.parts[0].notes), [
      [0, 480, 72, 100, 0],
      [480, 480, 74, 100, 0],
    ]);
    expect(_notes(file.parts[1].notes), [
      [0, 960, 40, 90, 2],
    ]);
    expect(_notes(file.parts[2].notes), [
      [0, 60, 36, 110, 9],
    ]);
  });

  test('a first track with notes is an instrument, not the song', () {
    final file = MidiFile.parse(
      _midi([
        [..._name('Piano'), ..._note(0, 60, 480), ..._end],
        [..._name('Bass'), ..._note(0, 36, 480, channel: 1), ..._end],
        [..._name('Empty'), ..._end],
      ]),
    );
    expect(file.songName, isNull);
    expect(file.parts.map((part) => [part.track, part.channel, part.name]), [
      [0, 0, 'Piano'],
      [1, 1, 'Bass'],
    ]);
  });

  test('tempo and time signature changes keep their ticks, in order', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._meta(0, 0x51, [0x07, 0x27, 0x0e]),
          ..._meta(0, 0x58, [3, 2, 24, 8]),
          ..._meta(1440, 0x58, [6, 3, 36, 8]),
          ..._meta(0, 0x51, [0x09, 0x27, 0xc0]),
          ..._end,
        ],
        [
          // any track may carry them
          ..._meta(720, 0x51, [0x0f, 0x42, 0x40]),
          ..._meta(2000, 0x58, [2, 1, 24, 8]),
          // and nonsense is left out: no tempo, no beats, 1/256 notes
          ..._meta(0, 0x51, [0, 0, 0]),
          ..._meta(0, 0x51, [1, 2]),
          ..._meta(0, 0x58, [0, 2, 24, 8]),
          ..._meta(0, 0x58, [4, 8, 24, 8]),
          ..._end,
        ],
      ]),
    );
    expect(
      file.tempos.map((tempo) => [tempo.tick, tempo.microsecondsPerQuarter]),
      [
        [0, 468750],
        [720, 1000000],
        [1440, 600000],
      ],
    );
    expect(file.tempos.map((tempo) => tempo.bpm), [128, 60, 100]);
    expect(
      file.timeSignatures.map((s) => [s.tick, s.numerator, s.denominator]),
      [
        [0, 3, 4],
        [1440, 6, 8],
        [2720, 2, 2],
      ],
    );
  });

  test('system exclusive and unknown meta events are skipped by length', () {
    // Payloads that would read as notes if they were not skipped whole.
    final decoy = [0x90, 60, 100, 0x00, 0x90, 61, 100];
    final long = List.filled(200, 0x40);
    final file = MidiFile.parse(
      _midi([
        [
          ..._at(0, [0xf0, ..._vlq(decoy.length + 1), ...decoy, 0xf7]),
          ..._at(10, [0xf7, ..._vlq(decoy.length), ...decoy]),
          ..._at(0, [0xf0, ..._vlq(long.length), ...long]),
          ..._meta(10, 0x7f, decoy),
          ..._meta(0, 0x01, utf8.encode('words')),
          ..._meta(0, 0x20, [3]),
          ..._meta(0, 0x21, [0]),
          ..._meta(0, 0x54, [0, 0, 0, 0, 0]),
          ..._meta(0, 0x59, [0xfe, 0]),
          ..._meta(0, 0x60, long),
          ..._note(0, 64, 480),
          ..._end,
        ],
      ]),
    );
    expect(_notes(file.tracks.single.notes), [
      [20, 480, 64, 100, 0],
    ]);
  });

  test('a held note ends with its track and a stray note off is ignored', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._at(0, [0x80, 59, 0]),
          ..._at(0, [0x90, 60, 100]),
          ..._at(240, [0x91, 64, 100]),
          ..._at(240, [0x80, 61, 0]),
          ..._meta(480, 0x2f, const []),
        ],
        // no end of track event: the last event is the end
        [
          ..._at(100, [0x90, 72, 100]),
          ..._at(50, [0xb0, 1, 0]),
        ],
      ]),
    );
    expect(_notes(file.tracks.first.notes), [
      [0, 960, 60, 100, 0],
      [240, 720, 64, 100, 1],
    ]);
    expect(_notes(file.tracks.last.notes), [
      [100, 50, 72, 100, 0],
    ]);
  });

  test('a key struck again starts a new note where the old one stops', () {
    final file = MidiFile.parse(
      _midi([
        [
          ..._at(0, [0x90, 60, 100]),
          ..._at(240, [0x90, 60, 80]),
          // another channel's key is another key
          ..._at(0, [0x91, 60, 70]),
          ..._at(240, [0x80, 60, 0]),
          ..._at(240, [0x80, 60, 0]),
          ..._at(0, [0x81, 60, 0]),
          ..._end,
        ],
      ]),
    );
    expect(_notes(file.tracks.single.notes), [
      [0, 240, 60, 100, 0],
      [240, 240, 60, 80, 0],
      [240, 480, 60, 70, 1],
    ]);
  });

  test('delta times use one to four bytes', () {
    const deltas = [0, 0x7f, 0x80, 0x3fff, 0x4000, 0x1fffff, 0x200000];
    final file = MidiFile.parse(
      _midi([
        [
          for (final delta in deltas) ..._note(delta, 60, 1),
          ..._meta(0x0fffffff, 0x2f, const []),
        ],
      ]),
    );
    var tick = 0;
    expect(file.tracks.single.notes.map((note) => note.start), [
      for (final delta in deltas) (tick += delta + 1) - 1,
    ]);
  });

  test('names are cleaned, read in the encoding they come in, or dropped', () {
    String? named(List<int> bytes, [List<int> again = const []]) =>
        MidiFile.parse(
          _midi([
            [
              ..._meta(0, 0x03, bytes),
              if (again.isNotEmpty) ..._meta(0, 0x03, again),
              ..._end,
            ],
          ]),
        ).tracks.single.name;

    expect(named(utf8.encode('  Melody   ')), 'Melody');
    expect(named(utf8.encode('Lead	Vocal')), 'Lead Vocal');
    expect(named(utf8.encode('メロディ')), 'メロディ');
    expect(named(const []), isNull);
    expect(named(utf8.encode('   ')), isNull);
    expect(named(utf8.encode('First'), utf8.encode('Second')), 'First');
    expect(named(utf8.encode('x' * 500)), hasLength(80));

    // Latin-1, from older Western files
    expect(named(latin1.encode('Mélodie')), 'Mélodie');

    // Shift_JIS, from Japanese sequencers: kana and wide letters are read
    expect(
      named(const [0x83, 0x81, 0x83, 0x8d, 0x83, 0x66, 0x83, 0x42]),
      'メロディ',
    );
    expect(named(const [0x83, 0x78, 0x81, 0x5b, 0x83, 0x58]), 'ベース');
    expect(
      named(const [0x83, 0x73, 0x83, 0x41, 0x83, 0x6d, 0x20, 0x31]),
      'ピアノ 1',
    );
    // the first and last character of every run that is decoded
    expect(
      named(const [
        ...[0x83, 0x40, 0x83, 0x7e, 0x83, 0x80, 0x83, 0x96],
        ...[0x82, 0x9f, 0x82, 0xf1],
        ...[0x82, 0x4f, 0x82, 0x58, 0x82, 0x60, 0x82, 0x79, 0x82, 0x81],
        ...[0x82, 0x9a, 0x81, 0x40, 0x81, 0x45, 0x81, 0x5b],
      ]),
      'ァミムヶぁん０９ＡＺａｚ　・ー',
    );
    // kanji are not (主旋律), nor is half a character: no name is better
    // than a wrong one
    expect(named(const [0x8e, 0xe5, 0x90, 0xf9, 0x97, 0xa5]), isNull);
    expect(named(const [0x83, 0x81, 0x83]), isNull);
    expect(named(const [0x83, 0x7f]), isNull);
  });

  test(
    'a longer header, foreign chunks and trailing bytes are passed over',
    () {
      final file = MidiFile.parse(
        Uint8List.fromList([
          ..._chunk('MThd', [0, 1, 0, 1, 1, 0xe0, 0xaa, 0xbb]),
          ..._chunk('XFIH', [1, 2, 3, 4, 5]),
          ..._chunk('MTrk', [..._note(0, 60, 480), ..._end]),
          ..._chunk('MTrk', [..._note(0, 99, 480), ..._end]),
          1,
          2,
          3,
        ]),
      );
      expect(file.division, 480);
      expect(_notes(file.tracks.single.notes), [
        [0, 480, 60, 100, 0],
      ]);
    },
  );

  test('nothing is read after the end of a track', () {
    final file = MidiFile.parse(
      _midi([
        [..._note(0, 60, 480), ..._end, 0xde, 0xad, 0xbe, 0xef],
        [..._note(0, 62, 480), ..._end],
      ]),
    );
    expect(file.tracks.map((track) => _notes(track.notes)), [
      [
        [0, 480, 60, 100, 0],
      ],
      [
        [0, 480, 62, 100, 0],
      ],
    ]);
  });

  test('a file with no tracks is empty rather than wrong', () {
    final file = MidiFile.parse(Uint8List.fromList(_header(1, 0, 480)));
    expect(file.tracks, isEmpty);
    expect(file.parts, isEmpty);
    expect(file.songName, isNull);
  });

  group('rejects with a FormatException', () {
    Matcher saying(String text) => throwsA(
      isA<FormatException>().having(
        (e) => e.message,
        'message',
        contains(text),
      ),
    );
    final track = [..._note(0, 60, 480), ..._end];
    Uint8List withHeader(List<int> header) =>
        Uint8List.fromList([...header, ..._chunk('MTrk', track)]);
    Uint8List withTrack(List<int> body) => _midi([body]);

    test('what is not a MIDI file', () {
      expect(() => MidiFile.parse(Uint8List(0)), saying('Not a MIDI file'));
      expect(
        () => MidiFile.parse(Uint8List.fromList(ascii.encode('MTh'))),
        saying('Not a MIDI file'),
      );
      expect(
        () => MidiFile.parse(
          Uint8List.fromList(ascii.encode('RIFF\x00\x00\x00\x00RMIDdata')),
        ),
        saying('Not a MIDI file'),
      );
    });

    test('SMPTE time division, by name', () {
      // 25 frames per second, 40 ticks per frame
      expect(
        () => MidiFile.parse(
          withHeader(_chunk('MThd', [0, 1, 0, 1, 0xe7, 0x28])),
        ),
        saying('SMPTE'),
      );
    });

    test('headers this reader does not support', () {
      expect(
        () => MidiFile.parse(withHeader(_header(2, 1, 480))),
        saying('format 2'),
      );
      expect(
        () => MidiFile.parse(withHeader(_header(1, 1, 0))),
        saying('division is zero'),
      );
      expect(
        () => MidiFile.parse(withHeader(_chunk('MThd', [0, 1, 0, 1]))),
        saying('header is too short'),
      );
    });

    test('files that end before they should', () {
      // one track fewer than the header promises
      expect(
        () => MidiFile.parse(
          Uint8List.fromList([..._header(1, 2, 480), ..._chunk('MTrk', track)]),
        ),
        saying('cut short'),
      );
      // a track longer than the file
      final bytes = _midi([track]);
      bytes[21] = 0xff;
      expect(() => MidiFile.parse(bytes), saying('cut short'));
      // an event or a meta payload longer than its track
      expect(
        () => MidiFile.parse(withTrack(_at(0, [0x90, 60]))),
        saying('cut short'),
      );
      expect(
        () => MidiFile.parse(withTrack(_at(0, [0xff, 0x03, 5, 0x41]))),
        saying('cut short'),
      );
      expect(
        () => MidiFile.parse(withTrack(_at(0, [0xf0, 0x81, 0x00, 0x41]))),
        saying('cut short'),
      );
      expect(() => MidiFile.parse(withTrack([0x00])), saying('cut short'));
    });

    test('damaged events', () {
      expect(
        () => MidiFile.parse(withTrack(_at(0, [60, 100]))),
        saying('no status'),
      );
      expect(
        () => MidiFile.parse(withTrack(_at(0, [0x90, 60, 0x80]))),
        saying('out of range'),
      );
      expect(
        () => MidiFile.parse(withTrack(_at(0, [0xc0, 0xff]))),
        saying('out of range'),
      );
      expect(
        () => MidiFile.parse(withTrack(_at(0, [0xf8]))),
        saying('unexpected message'),
      );
      expect(
        () => MidiFile.parse(
          withTrack([0x81, 0x80, 0x80, 0x80, 0x00, 0x90, 60, 1]),
        ),
        saying('overlong number'),
      );
    });

    test('files beyond the size, note and length limits', () {
      expect(
        () => MidiFile.parse(Uint8List(MidiFile.maxBytes + 1)),
        saying('larger than 1 MB'),
      );
      List<int> notes(int count) => [
        ..._at(0, [0x90, 60, 100]),
        for (var i = 1; i < 2 * count; i++) ..._at(1, [60, i.isOdd ? 0 : 100]),
      ];
      final most = MidiFile.parse(withTrack(notes(MidiFile.maxNotes)));
      expect(most.tracks.single.notes, hasLength(MidiFile.maxNotes));
      expect(most.tracks.single.notes.last.start, 2 * MidiFile.maxNotes - 2);
      expect(
        () => MidiFile.parse(withTrack(notes(MidiFile.maxNotes + 1))),
        saying('too many notes'),
      );
      expect(
        () => MidiFile.parse(
          withTrack([
            for (var i = 0; i < 9; i++) ..._at(0x0fffffff, [0xb0, 1, 0]),
          ]),
        ),
        saying('too long'),
      );
    });

    test('a valid file cut at every length', () {
      final bytes = _sample();
      expect(MidiFile.parse(bytes).tracks, hasLength(2));
      for (var length = 0; length < bytes.length; length++) {
        expect(
          () => MidiFile.parse(Uint8List.sublistView(bytes, 0, length)),
          throwsFormatException,
          reason: 'cut at $length of ${bytes.length}',
        );
      }
    });
  });

  test('damaged bytes are read or refused, never anything else', () {
    final random = Random(20261014);
    final valid = _sample();
    // Any error other than a FormatException fails the test; a loop that
    // does not end would time it out.
    void read(Uint8List bytes) {
      try {
        final file = MidiFile.parse(bytes);
        for (final part in file.parts) {
          expect(part.notes, isNotEmpty);
          for (final note in part.notes) {
            expect(note.start, greaterThanOrEqualTo(0));
            expect(note.duration, greaterThanOrEqualTo(0));
            expect(note.pitch, inInclusiveRange(0, 127));
            expect(note.velocity, inInclusiveRange(1, 127));
            expect(note.channel, part.channel);
          }
        }
      } on FormatException {
        // refused
      }
    }

    for (var round = 0; round < 4000; round++) {
      // a valid file with a few bytes changed
      final damaged = Uint8List.fromList(valid);
      for (var i = random.nextInt(4); i >= 0; i--) {
        damaged[random.nextInt(damaged.length)] = random.nextInt(256);
      }
      read(damaged);
      // a valid header followed by noise that claims to be a track
      final noise = List.generate(
        random.nextInt(64),
        (_) => random.nextBool() ? random.nextInt(256) : random.nextInt(0x90),
      );
      read(_midi([noise], format: random.nextInt(2)));
      // noise from the header on
      read(Uint8List.fromList([...ascii.encode('MThd'), 0, 0, 0, ...noise]));
    }
  });
}
