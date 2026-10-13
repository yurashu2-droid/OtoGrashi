import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/public_domain_scores.dart';
import 'package:otogurashi/features/songs/midi_song_reader.dart';
import 'package:otogurashi/media/midi_file_picker.dart';

void main() {
  test('a MIDI file becomes a song named after the file', () {
    final bytes = File(
      'assets/music/public_domain/twinkle_twinkle.mid',
    ).readAsBytesSync();
    final reading = readMidiSong(
      PickedMidiFile(name: 'きらきら', bytes: bytes),
      'song-1',
    );
    final song = reading.song;
    expect(song.id, 'song-1');
    expect(song.title, 'きらきら');
    // the same notes the app ships for this tune
    expect(song.lanes, publicDomainScores['twinkle_twinkle']);
    // eight bars in all: there is nowhere else to take the song from
    expect(reading.bar, 0);
    expect(reading.canMove, isFalse);
    expect(reading.from(0)?.song.lanes, song.lanes);
  });

  test('a file that is not MIDI, or has no tune, says so plainly', () {
    expect(
      () => readMidiSong(
        PickedMidiFile(name: 'x', bytes: Uint8List.fromList([1, 2, 3, 4])),
        'song-2',
      ),
      throwsA(
        isA<MidiSongProblem>().having(
          (problem) => problem.message,
          'message',
          contains('MIDIとして読めません'),
        ),
      ),
    );
  });
}
