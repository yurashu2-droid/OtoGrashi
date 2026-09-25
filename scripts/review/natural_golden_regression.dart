import 'dart:convert';
import 'dart:io';

import '../../lib/domain/arrangement.dart';
import '../../lib/domain/arrangement_engine.dart';
import '../../lib/domain/melody_template.dart';

void main(List<String> args) {
  final clips = List.generate(
    3,
    (i) => AnalyzedClip.fromJson({
      'schemaVersion': 1,
      'analysisVersion': 1,
      'assetId': 'voice-$i',
      'sampleRate': 48000,
      'sourceStartSample': 0,
      'durationSamples': 216000,
      'onsetSamples': [9600],
      'audibleRegions': [
        {'startSample': 0, 'durationSamples': 216000},
      ],
      'peak': 0.8,
      'rms': 0.2,
      'suggestedRole': i == 0 ? 'transient' : 'sustain',
      'registerMidiNote': 52.0 + i * 2,
      'fundamentalMidiNote': i == 0 ? null : 52.0 + i * 2,
    }),
  );
  final data = <String, Object?>{};
  for (final template in MelodyTemplate.values) {
    final a = arrange(
      clips: clips,
      style: ArrangementStyle.swaying,
      seed: 12,
      melodyTemplate: template,
    );
    data[template.name] = [
      for (final e in a.events)
        {
          'asset': e.assetId,
          'source': e.sourceStartSample,
          'sourceCount': e.effectiveSourceDurationSamples,
          'at': e.destinationStartSample,
          'count': e.durationSamples,
          'gain': e.gain,
          'target': e.targetMidiNote,
          'pitchSteps': e.pitchSteps.map((p) => p.toJson()).toList(),
          'treatment': e.treatment.name,
          'reverse': e.reverse,
        },
    ];
  }
  final root = File('test/fixtures/natural_d760_events.json').existsSync()
      ? Directory.current
      : File.fromUri(Platform.script).parent.parent.parent;
  final expected = jsonDecode(
    File('${root.path}/test/fixtures/natural_d760_events.json')
        .readAsStringSync(),
  );
  for (final key in data.keys) {
    if (jsonEncode(data[key]) != jsonEncode(expected[key])) {
      throw StateError('Approved natural mode changed: $key');
    }
    print('PASS approved natural events unchanged: $key');
  }
}
