import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/public_domain_scores.dart';
import 'package:otogurashi/features/songs/midi_song_reader.dart';
import 'package:otogurashi/features/songs/song_library.dart';
import 'package:otogurashi/media/midi_file_picker.dart';

void main() {
  test('a MIDI file becomes a song named after the file', () {
    final bytes = File(
      'assets/music/public_domain/twinkle_twinkle.mid',
    ).readAsBytesSync();
    final song = readMidiSong(
      PickedMidiFile(name: 'きらきら', bytes: bytes),
      'song-1',
    );
    expect(song.id, 'song-1');
    expect(song.title, 'きらきら');
    // the same notes the app ships for this tune
    expect(song.lanes, publicDomainScores['twinkle_twinkle']);
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
