import '../../domain/custom_song.dart';
import '../../domain/imported_score.dart';
import '../../domain/midi_file.dart';
import '../../media/midi_file_picker.dart';
import 'song_library.dart';

/// Reads a chosen MIDI file into a song: eight bars from where the melody
/// starts, with the parts the file's own names or notes point to. Throws a
/// [MidiSongProblem], worded for the person, when the file cannot be a song.
CustomSong readMidiSong(PickedMidiFile file, String id) {
  final MidiFile midi;
  try {
    midi = MidiFile.parse(file.bytes);
  } on FormatException {
    throw const MidiSongProblem('このファイルはMIDIとして読めませんでした。別のファイルで試してください。');
  }
  switch (ImportedScore.fromMidi(midi)) {
    case ScoreImported(:final score):
      // the file's name is what the person chose it by; track names inside
      // are often just "Piano"
      final name = file.name.trim();
      return CustomSong(
        id: id,
        title: name.isEmpty ? score.title : name,
        lanes: score.lanes,
      );
    case ScoreImportFailed(:final reason):
      throw MidiSongProblem(switch (reason) {
        ScoreImportFailure.noNotes => 'このMIDIには音が入っていません。',
        ScoreImportFailure.onlyDrums => 'このMIDIはドラムだけなので、メロディにできません。',
        ScoreImportFailure.emptyWindow => 'このMIDIからメロディを見つけられませんでした。',
        ScoreImportFailure.tooShort => 'この曲は短すぎます。1小節より長いMIDIで試してください。',
      });
  }
}
