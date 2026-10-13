import 'dart:convert';
import 'dart:typed_data';

/// One note of a MIDI file. Ticks are the file's own: [MidiFile.division] of
/// them make a quarter note.
final class MidiNote {
  const MidiNote._({
    required this.start,
    required this.duration,
    required this.pitch,
    required this.velocity,
    required this.channel,
  });

  final int start;
  final int duration;

  /// MIDI note number, 0 to 127 (60 is middle C).
  final int pitch;

  /// How hard the key was struck, 1 to 127.
  final int velocity;

  /// Zero-based, 0 to 15. Channel 9 (the tenth) is General MIDI percussion.
  final int channel;

  int get end => start + duration;
}

/// From [tick] on, a quarter note lasts [microsecondsPerQuarter].
final class MidiTempo {
  const MidiTempo._(this.tick, this.microsecondsPerQuarter);

  final int tick;
  final int microsecondsPerQuarter;

  double get bpm => 60000000 / microsecondsPerQuarter;
}

/// From [tick] on, a bar holds [numerator] notes of 1/[denominator].
final class MidiTimeSignature {
  const MidiTimeSignature._(this.tick, this.numerator, this.denominator);

  final int tick;
  final int numerator;

  /// A power of two from 1 to 128: 4 for quarter notes, 8 for eighths.
  final int denominator;
}

/// A track as the file stores it. A format 0 file has a single track that
/// carries every channel; see [MidiFile.parts] for the instrument lines.
final class MidiTrack {
  const MidiTrack._(this.name, this.notes);

  /// The track name event, or null when there is none or it cannot be read.
  final String? name;

  /// In order of start.
  final List<MidiNote> notes;
}

/// One instrument line: what one channel plays in one track.
final class MidiPart {
  const MidiPart._({
    required this.track,
    required this.channel,
    required this.name,
    required this.notes,
  });

  /// Index into [MidiFile.tracks].
  final int track;
  final int channel;

  /// The name of the track. Null in a format 0 file, whose only track is
  /// named after the song rather than after an instrument.
  final String? name;

  /// In order of start; never empty.
  final List<MidiNote> notes;
}

/// A Standard MIDI File (format 0 or 1) reduced to what a score needs: notes,
/// track names, tempo and time signatures. Controllers, pitch bend, lyrics
/// and everything else are read past.
final class MidiFile {
  MidiFile._({
    required this.format,
    required this.division,
    required List<MidiTrack> tracks,
    required List<MidiTempo> tempos,
    required List<MidiTimeSignature> timeSignatures,
  }) : tracks = List.unmodifiable(tracks),
       tempos = List.unmodifiable(tempos),
       timeSignatures = List.unmodifiable(timeSignatures);

  /// Reads [bytes]. Throws a [FormatException] with a short reason when they
  /// are not a MIDI file this reader supports, are cut short or are damaged,
  /// and never anything else, whatever the bytes.
  factory MidiFile.parse(Uint8List bytes) => _Reader(bytes).read();

  /// A song is a few tens of kilobytes; anything larger is refused unread.
  static const maxBytes = 1 << 20;

  /// More notes than any song has; a file with more is refused.
  static const maxNotes = 50000;

  /// 0: one track with every channel. 1: simultaneous tracks.
  final int format;

  /// Ticks per quarter note.
  final int division;
  final List<MidiTrack> tracks;

  /// Tempo changes of every track, in order of tick. Empty means 120 BPM.
  final List<MidiTempo> tempos;

  /// Time signatures of every track, in order of tick. Empty means 4/4.
  final List<MidiTimeSignature> timeSignatures;

  /// The song's own name: the first track's name when that track is the
  /// whole song (format 0) or is the conductor track that holds no notes.
  /// A first track with notes is named after its instrument instead.
  String? get songName =>
      tracks.isEmpty || (format != 0 && tracks.first.notes.isNotEmpty)
      ? null
      : tracks.first.name;

  /// Every track split by channel, in track then channel order, leaving out
  /// tracks without notes. This is where a format 0 file's single track
  /// becomes separate instruments.
  late final List<MidiPart> parts = List.unmodifiable([
    for (final (index, track) in tracks.indexed)
      for (var channel = 0; channel < 16; channel++)
        if (track.notes.any((note) => note.channel == channel))
          MidiPart._(
            track: index,
            channel: channel,
            name: format == 0 ? null : track.name,
            notes: List.unmodifiable(
              track.notes.where((note) => note.channel == channel),
            ),
          ),
  ]);
}

/// Walks the bytes once. Every read goes through [_byte] or [_skip], which
/// stop at [_end], and every event consumes at least one byte, so damaged
/// input ends in a [FormatException] instead of a range error or a loop.
final class _Reader {
  _Reader(this._bytes);

  static const _headerChunk = 0x4d546864; // 'MThd'
  static const _trackChunk = 0x4d54726b; // 'MTrk'

  /// Far beyond any song, and small enough that scaled ticks stay exact.
  static const _maxTick = 0x7fffffff;
  static const _maxNameLength = 80;
  static const _cutShort = FormatException('MIDI file is cut short.');

  final Uint8List _bytes;
  final _tempos = <MidiTempo>[];
  final _timeSignatures = <MidiTimeSignature>[];
  var _at = 0;
  var _end = 0;
  var _noteCount = 0;

  MidiFile read() {
    if (_bytes.length > MidiFile.maxBytes) {
      throw const FormatException('MIDI file is larger than 1 MB.');
    }
    _end = _bytes.length;
    if (_bytes.length < 4 || _number(4) != _headerChunk) {
      throw const FormatException('Not a MIDI file.');
    }
    final headerLength = _number(4);
    if (headerLength < 6) {
      throw const FormatException('MIDI header is too short.');
    }
    final format = _number(2);
    final trackCount = _number(2);
    final division = _number(2);
    _skip(headerLength - 6);
    if (format > 1) {
      throw FormatException('MIDI format $format is not supported.');
    }
    if (division >= 0x8000) {
      throw const FormatException('SMPTE time division is not supported.');
    }
    if (division == 0) {
      throw const FormatException('MIDI time division is zero.');
    }
    final tracks = <MidiTrack>[];
    // Chunks of other kinds may sit between tracks and are skipped; a file
    // that ends before all its tracks is cut short.
    while (tracks.length < trackCount) {
      final kind = _number(4);
      final length = _number(4);
      if (length > _bytes.length - _at) throw _cutShort;
      final next = _at + length;
      if (kind == _trackChunk) {
        _end = next;
        tracks.add(_track());
        _end = _bytes.length;
      }
      _at = next;
    }
    return MidiFile._(
      format: format,
      division: division,
      tracks: tracks,
      tempos: _inOrder(_tempos, (tempo) => tempo.tick),
      timeSignatures: _inOrder(_timeSignatures, (signature) => signature.tick),
    );
  }

  MidiTrack _track() {
    final starts = <int>[];
    final lengths = <int>[];
    final keys = <int>[];
    final velocities = <int>[];
    // Channel and pitch of each sounding key, to its index in the lists.
    final sounding = <int, int>{};
    String? name;
    var tick = 0;
    var running = 0;

    void release(int key) {
      final index = sounding.remove(key);
      if (index != null) lengths[index] = tick - starts[index];
    }

    while (_at < _end) {
      tick += _variable();
      if (tick > _maxTick) {
        throw const FormatException('MIDI file is too long.');
      }
      var status = _byte();
      if (status < 0x80) {
        // Running status: a data byte here repeats the last channel status.
        // Meta and system-exclusive events do not cancel it, as lenient
        // players accept.
        if (running == 0) {
          throw const FormatException('MIDI event has no status.');
        }
        _at--;
        status = running;
      } else if (status < 0xf0) {
        running = status;
      }
      if (status == 0xff) {
        final type = _byte();
        final length = _variable();
        final from = _at;
        _skip(length);
        switch (type) {
          case 0x03:
            name ??= _text(from, length);
          case 0x51 when length >= 3:
            final value =
                _bytes[from] << 16 | _bytes[from + 1] << 8 | _bytes[from + 2];
            if (value > 0) _tempos.add(MidiTempo._(tick, value));
          case 0x58 when length >= 2:
            // A bar of no notes, or of notes shorter than a 128th, is noise.
            if (_bytes[from] > 0 && _bytes[from + 1] <= 7) {
              _timeSignatures.add(
                MidiTimeSignature._(tick, _bytes[from], 1 << _bytes[from + 1]),
              );
            }
          case 0x2f:
            _at = _end; // end of track: whatever follows is not music
        }
      } else if (status == 0xf0 || status == 0xf7) {
        _skip(_variable());
      } else if (status > 0xf0) {
        throw const FormatException('MIDI file has an unexpected message.');
      } else {
        // Program change and channel pressure carry one data byte, every
        // other channel message two.
        final kind = status & 0xf0;
        final first = _data();
        final second = kind == 0xc0 || kind == 0xd0 ? 0 : _data();
        final key = (status & 0x0f) << 7 | first;
        if (kind == 0x90 && second > 0) {
          // A key struck again while it is down starts a new note and ends
          // the old one there, as it would on an instrument; the notes of
          // one key never overlap.
          release(key);
          if (++_noteCount > MidiFile.maxNotes) {
            throw const FormatException('MIDI file has too many notes.');
          }
          sounding[key] = starts.length;
          starts.add(tick);
          lengths.add(0);
          keys.add(key);
          velocities.add(second);
        } else if (kind == 0x80 || kind == 0x90) {
          // Note off, or note on with velocity 0. One for a key that is not
          // down has nothing to end.
          release(key);
        }
      }
    }
    // Notes never released last until the track ends.
    for (final index in sounding.values) {
      lengths[index] = tick - starts[index];
    }
    return MidiTrack._(
      name,
      List.unmodifiable([
        for (var i = 0; i < starts.length; i++)
          MidiNote._(
            start: starts[i],
            duration: lengths[i],
            pitch: keys[i] & 0x7f,
            velocity: velocities[i],
            channel: keys[i] >> 7,
          ),
      ]),
    );
  }

  int _byte() {
    if (_at >= _end) throw _cutShort;
    return _bytes[_at++];
  }

  int _data() {
    final value = _byte();
    if (value > 0x7f) {
      throw const FormatException('MIDI event data is out of range.');
    }
    return value;
  }

  /// A big-endian number of [width] bytes.
  int _number(int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = value << 8 | _byte();
    }
    return value;
  }

  /// A variable-length quantity: seven bits per byte, at most four bytes.
  int _variable() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final byte = _byte();
      value = value << 7 | (byte & 0x7f);
      if (byte < 0x80) return value;
    }
    throw const FormatException('MIDI file has an overlong number.');
  }

  void _skip(int length) {
    if (length > _end - _at) throw _cutShort;
    _at += length;
  }

  /// Names are UTF-8 in files written today, Shift_JIS from Japanese
  /// sequencers (read as far as [_kana] goes) and Latin-1 in older Western
  /// files. Anything else would show as control characters in Latin-1 and
  /// is dropped: no name is better than noise.
  String? _text(int from, int length) {
    final raw = Uint8List.sublistView(_bytes, from, from + length);
    String? text;
    try {
      text = utf8.decode(raw);
    } on FormatException {
      text = _kana(raw);
      if (text == null) {
        if (raw.any((byte) => byte >= 0x80 && byte < 0xa0)) return null;
        text = latin1.decode(raw);
      }
    }
    // Padding and stray control characters become spaces.
    final clean = String.fromCharCodes([
      for (final rune in text.runes)
        rune < 0x20 || (rune >= 0x7f && rune < 0xa0) ? 0x20 : rune,
    ]).trim();
    if (clean.isEmpty) return null;
    return clean.runes.length > _maxNameLength
        ? String.fromCharCodes(clean.runes.take(_maxNameLength)).trim()
        : clean;
  }

  /// The part of Shift_JIS that maps to Unicode without a table: lead byte,
  /// first and last trail byte, first code point.
  static const _shiftJisRuns = [
    (0x81, 0x40, 0x40, 0x3000), // wide space
    (0x81, 0x45, 0x45, 0x30fb), // middle dot
    (0x81, 0x5b, 0x5b, 0x30fc), // long vowel mark
    (0x82, 0x4f, 0x58, 0xff10), // wide digits
    (0x82, 0x60, 0x79, 0xff21), // wide capitals
    (0x82, 0x81, 0x9a, 0xff41), // wide small letters
    (0x82, 0x9f, 0xf1, 0x3041), // hiragana
    (0x83, 0x40, 0x7e, 0x30a1), // katakana, first half
    (0x83, 0x80, 0x96, 0x30e0), // katakana, second half
  ];

  /// [raw] as Shift_JIS when it holds only ASCII, kana and wide letters,
  /// which covers names such as メロディ and ベース; null otherwise. Kanji
  /// need a table of thousands of entries that Dart does not bring.
  static String? _kana(Uint8List raw) {
    final text = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final lead = raw[i];
      if (lead < 0x80) {
        text.writeCharCode(lead);
        continue;
      }
      if (++i == raw.length) return null;
      final trail = raw[i];
      final run = _shiftJisRuns
          .where((run) => run.$1 == lead && run.$2 <= trail && trail <= run.$3)
          .firstOrNull;
      if (run == null) return null;
      text.writeCharCode(run.$4 + trail - run.$2);
    }
    return text.toString();
  }

  /// Sorted by tick; events of one tick stay in file order.
  static List<T> _inOrder<T>(List<T> events, int Function(T) tick) {
    final order = events.indexed.toList()
      ..sort((a, b) {
        final byTick = tick(a.$2).compareTo(tick(b.$2));
        return byTick != 0 ? byTick : a.$1.compareTo(b.$1);
      });
    return [for (final (_, event) in order) event];
  }
}
