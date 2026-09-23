import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';

void main() {
  final threeFixtures = <AnalyzedClip>[
    _clip('tap', role: SuggestedRole.transient, onsets: const [2400, 24000]),
    _clip('hum', role: SuggestedRole.sustain, onsets: const [12000]),
    _clip('room', role: SuggestedRole.texture, onsets: const []),
  ];

  test('arrangement is deterministic and fits exactly 15 seconds', () {
    final a = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 42,
    );
    final b = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 42,
    );

    expect(a.toJson(), b.toJson());
    expect(a.sampleRate, 48000);
    expect(a.totalSamples, 720000);
    expect(a.events.every(_fitsDestination), isTrue);
    expect(
      a.events.every((event) => _fitsSource(event, threeFixtures)),
      isTrue,
    );
    expect(
      a.events.map((event) => event.assetId).toSet(),
      threeFixtures.map((clip) => clip.assetId).toSet(),
    );
    expect(a.videoEvents, hasLength(a.events.length));
    for (var i = 0; i < a.events.length; i++) {
      expect(a.videoEvents[i].assetId, a.events[i].assetId);
      expect(
        a.videoEvents[i].destinationStartSample,
        a.events[i].destinationStartSample,
      );
      expect(a.videoEvents[i].durationSamples, a.events[i].durationSamples);
      expect(
        a.videoEvents[i].sourceVideoStartTime,
        RationalTime(a.events[i].sourceStartSample, 48000),
      );
    }
  });

  test('all three style templates have explicit bounded behavior', () {
    final sparse = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 7,
    );
    final swaying = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.swaying,
      seed: 7,
    );
    final lively = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.lively,
      seed: 7,
    );

    expect(sparse.templateId, 'sparse-128bpm-8bar');
    expect(swaying.templateId, 'swaying-128bpm-8bar');
    expect(lively.templateId, 'lively-128bpm-8bar');
    expect(sparse.events.length, lessThan(swaying.events.length));
    expect(swaying.events.length, lessThan(lively.events.length));
    expect(
      swaying.events.any(
        (event) => event.destinationStartSample % Arrangement.beatSamples != 0,
      ),
      isTrue,
    );
    expect(
      lively.events.map((event) => event.gain).reduce((a, b) => a > b ? a : b),
      greaterThan(
        sparse.events
            .map((event) => event.gain)
            .reduce((a, b) => a > b ? a : b),
      ),
    );
  });

  test('chosen original motifs change only sustained sounds and persist', () {
    for (final style in ArrangementStyle.values) {
      for (final melody in MelodyTemplate.values.skip(1)) {
        final arrangement = arrange(
          clips: threeFixtures,
          style: style,
          melodyTemplate: melody,
          seed: 7,
        );
        expect(arrangement.melodyTemplate, melody);
        expect(arrangement.events.length, lessThanOrEqualTo(64));
        expect(arrangement.videoEvents.length, arrangement.events.length);
        expect(arrangement.events.every(_fitsDestination), isTrue);
        expect(
          arrangement.events.every(
            (event) => _fitsSource(event, threeFixtures),
          ),
          isTrue,
        );
        for (var i = 0; i < arrangement.events.length; i++) {
          expect(
            arrangement.videoEvents[i].assetId,
            arrangement.events[i].assetId,
          );
          expect(
            arrangement.videoEvents[i].destinationStartSample,
            arrangement.events[i].destinationStartSample,
          );
        }
        expect(
          arrangement.events.any((event) => event.pitchSemitones != 0),
          isTrue,
        );
        expect(
          arrangement.events
              .where((event) => event.assetId != 'hum')
              .every((event) => event.pitchSemitones == 0),
          isTrue,
        );
        expect(
          arrangement.events.every((event) => event.pitchSemitones.abs() <= 3),
          isTrue,
        );
        expect(
          Arrangement.fromJson(arrangement.toJson()).toJson(),
          arrangement.toJson(),
        );
      }
    }

    final patterns = MelodyTemplate.values.skip(1).map((melody) {
      final arranged = arrange(
        clips: threeFixtures,
        style: ArrangementStyle.sparse,
        melodyTemplate: melody,
        seed: 7,
      );
      return arranged.events
          .where((event) => event.assetId == 'hum' && event.gain == 0.62)
          .map((event) => [event.destinationStartSample, event.pitchSemitones])
          .toList()
          .toString();
    }).toSet();
    expect(patterns.length, 3);

    final noMelody = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 7,
    );
    expect(noMelody.melodyTemplate, MelodyTemplate.none);
    expect(noMelody.events.every((event) => event.pitchSemitones == 0), isTrue);

    final oldJson = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 7,
    ).toJson();
    final oldEvents = (oldJson['events'] as List<Object?>)
        .map(
          (value) =>
              Map<String, Object?>.from(value! as Map)
                ..remove('pitchSemitones'),
        )
        .toList();
    final oldArrangement = Arrangement.fromJson({
      ...oldJson,
      'events': oldEvents,
    });
    expect(
      oldArrangement.events.every((event) => event.pitchSemitones == 0),
      isTrue,
    );

    oldEvents.first['pitchSemitones'] = 4;
    expect(
      () => Arrangement.fromJson({...oldJson, 'events': oldEvents}),
      throwsA(isA<MediaContractException>()),
    );
  });

  test('a motif does not turn short taps or texture into fake notes', () {
    final onlyShortSounds = [
      _clip('tap-1', role: SuggestedRole.transient),
      _clip('tap-2', role: SuggestedRole.transient),
      _clip('room', role: SuggestedRole.texture),
    ];
    final arrangement = arrange(
      clips: onlyShortSounds,
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.hop,
      seed: 7,
    );
    expect(
      arrangement.events.every((event) => event.pitchSemitones == 0),
      isTrue,
    );
    expect(arrangement.events.length, lessThanOrEqualTo(64));
  });

  test('persisted arrangement rejects more than six assets or 64 events', () {
    final valid = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.lively,
      seed: 7,
    ).toJson();
    expect(
      () => Arrangement.fromJson({
        ...valid,
        'sourceAssetIds': List<String>.generate(7, (index) => 'asset-$index'),
      }),
      throwsA(isA<MediaContractException>()),
    );

    final audio = (valid['events'] as List<Object?>).first;
    final video = (valid['videoEvents'] as List<Object?>).first;
    expect(
      () => Arrangement.fromJson({
        ...valid,
        'events': List<Object?>.filled(65, audio),
        'videoEvents': List<Object?>.filled(65, video),
      }),
      throwsA(isA<MediaContractException>()),
    );
  });

  test(
    'six sources are all scheduled while the first three lead the intro',
    () {
      final clips = List<AnalyzedClip>.generate(
        6,
        (index) => _clip(
          'clip-$index',
          role: SuggestedRole.values[index % SuggestedRole.values.length],
          onsets: [index * 800],
        ),
      );

      final result = arrange(
        clips: clips,
        style: ArrangementStyle.lively,
        seed: 99,
      );

      expect(result.events.map((event) => event.assetId).toSet(), {
        for (var i = 0; i < 6; i++) 'clip-$i',
      });
      expect(
        result.events
            .where(
              (event) =>
                  event.destinationStartSample < 3 * Arrangement.barSamples,
            )
            .map((event) => event.assetId)
            .toList(),
        [
          'clip-0',
          'clip-0',
          'clip-1',
          'clip-1',
          'clip-1',
          'clip-2',
          'clip-2',
          'clip-2',
          'clip-2',
        ],
      );
    },
  );

  test('repeated audio is still scheduled as distinct source assets', () {
    final clips = List<AnalyzedClip>.generate(
      3,
      (index) => _clip(
        'same-$index',
        role: SuggestedRole.transient,
        onsets: const [1000, 20000],
      ),
    );

    final result = arrange(
      clips: clips,
      style: ArrangementStyle.sparse,
      seed: 42,
    );

    expect(result.events.map((event) => event.assetId).toSet(), {
      'same-0',
      'same-1',
      'same-2',
    });
  });

  test('mixed silence reports unusable IDs and never invents their sound', () {
    final clips = <AnalyzedClip>[
      ...threeFixtures,
      _clip('silent', peak: 0, rms: 0, onsets: const []),
    ];

    final result = arrange(
      clips: clips,
      style: ArrangementStyle.swaying,
      seed: 8,
    );

    expect(result.sourceAssetIds, ['tap', 'hum', 'room', 'silent']);
    expect(result.unusableAssetIds, ['silent']);
    expect(result.events.any((event) => event.assetId == 'silent'), isFalse);
  });

  test('all-silent input is rejected with a recoverable reason', () {
    expect(
      () => arrange(
        clips: [_clip('silent', peak: 0, rms: 0, onsets: const [])],
        style: ArrangementStyle.sparse,
        seed: 1,
      ),
      throwsA(
        isA<ArrangementRejected>()
            .having(
              (error) => error.reason,
              'reason',
              ArrangementRejectionReason.allSilent,
            )
            .having((error) => error.recoverable, 'recoverable', isTrue)
            .having((error) => error.assetIds, 'assetIds', ['silent']),
      ),
    );
  });

  test('silent assets do not count toward the three usable source minimum', () {
    expect(
      () => arrange(
        clips: [
          threeFixtures[0],
          threeFixtures[1],
          _clip('silent', peak: 0, rms: 0, onsets: const []),
        ],
        style: ArrangementStyle.sparse,
        seed: 1,
      ),
      throwsA(
        isA<ArrangementRejected>()
            .having(
              (error) => error.reason,
              'reason',
              ArrangementRejectionReason.insufficientUsableSources,
            )
            .having((error) => error.assetIds, 'assetIds', ['silent']),
      ),
    );
  });

  test(
    'invalid source metadata and unsupported JSON versions are rejected',
    () {
      expect(
        () => AnalyzedClip(
          assetId: 'bad',
          durationSamples: 48000,
          sampleRate: 44100,
          onsetSamples: const [],
          peak: 0.5,
          rms: 0.2,
          suggestedRole: SuggestedRole.sustain,
        ),
        throwsA(isA<MediaContractException>()),
      );
      expect(
        () => AnalyzedClip(
          assetId: 'overflow',
          sourceStartSample: 9223372036854775807,
          durationSamples: 1,
          sampleRate: 48000,
          onsetSamples: const [],
          peak: 0.5,
          rms: 0.2,
          suggestedRole: SuggestedRole.sustain,
        ),
        throwsA(isA<MediaContractException>()),
      );
      final valid = arrange(
        clips: threeFixtures,
        style: ArrangementStyle.sparse,
        seed: 42,
      ).toJson();
      expect(
        () => Arrangement.fromJson({...valid, 'schemaVersion': 2}),
        throwsA(isA<MediaContractException>()),
      );
      expect(
        () => Arrangement.fromJson({...valid, 'rendererVersion': 2}),
        throwsA(isA<MediaContractException>()),
      );
      final videos = (valid['videoEvents'] as List<Object?>)
          .map((value) => Map<String, Object?>.from(value! as Map))
          .toList();
      videos[0]['crop'] = <String, Object?>{
        'x': -0.1,
        'y': 0.0,
        'width': 1.0,
        'height': 1.0,
      };
      expect(
        () => Arrangement.fromJson({...valid, 'videoEvents': videos}),
        throwsA(isA<MediaContractException>()),
      );
    },
  );

  test('analysis request carries selection and audio timeline origin', () {
    final expected = jsonDecode(
      File('test/fixtures/media_analysis_request_v1.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final request = MediaAnalysisRequest.fromJson(expected);

    expect(request.toJson(), expected);
    expect(
      MediaAnalysisRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
  });

  test('video selection may begin before a delayed audio track', () {
    final request = MediaAnalysisRequest(
      assetId: 'delayed-audio',
      relativePath: 'assets/delayed.mov',
      selectionStartUs: 0,
      selectionDurationUs: 20000,
      audioTrackStartUs: 10000,
    );

    expect(request.selectionStartUs, 0);
    expect(request.audioTrackStartUs, 10000);
  });

  test('analysis request rejects timestamp end overflow', () {
    expect(
      () => MediaAnalysisRequest.fromJson({
        'schemaVersion': 1,
        'assetId': 'huge',
        'relativePath': 'assets/huge.mov',
        'selectionStartUs': 9223372036854775807,
        'selectionDurationUs': 1,
        'audioTrackStartUs': 0,
      }),
      throwsA(isA<MediaContractException>()),
    );
  });

  test('selected source bounds remain on the original media timeline', () {
    final selected = <AnalyzedClip>[
      for (var i = 0; i < 3; i++)
        AnalyzedClip(
          assetId: 'selected-$i',
          sourceStartSample: 96000,
          durationSamples: 48000,
          sampleRate: 48000,
          onsetSamples: const [97000],
          peak: 0.8,
          rms: 0.2,
          suggestedRole: SuggestedRole.transient,
        ),
    ];

    final result = arrange(
      clips: selected,
      style: ArrangementStyle.sparse,
      seed: 4,
    );

    expect(
      result.events.every(
        (event) =>
            event.sourceStartSample >= 96000 &&
            event.sourceStartSample + event.durationSamples <= 144000,
      ),
      isTrue,
    );
  });

  test('audible regions avoid quiet tails and bound repeated notes', () {
    final clips = List<AnalyzedClip>.generate(
      3,
      (index) => AnalyzedClip(
        assetId: 'voice-$index',
        durationSamples: 144000,
        sampleRate: 48000,
        onsetSamples: const [],
        audibleRegions: const [
          AudibleRegion(startSample: 72000, durationSamples: 12000),
        ],
        peak: .3,
        rms: .08,
        suggestedRole: SuggestedRole.sustain,
      ),
    );

    final result = arrange(
      clips: clips,
      style: ArrangementStyle.sparse,
      seed: 3,
    );
    expect(
      AnalyzedClip.fromJson(clips.first.toJson()).toJson(),
      clips.first.toJson(),
    );
    expect(
      result.events.every((event) => event.sourceStartSample == 72000),
      isTrue,
    );
    expect(
      result.events.every((event) => event.durationSamples <= 12000),
      isTrue,
    );
  });

  test('seed zero has a stable golden arrangement JSON', () {
    final arrangement = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 0,
    );
    final actual = <String, Object?>{
      'schemaVersion': Arrangement.schemaVersion,
      'templateId': arrangement.templateId,
      'seed': arrangement.seed,
      'events': arrangement.events
          .map(
            (event) => [
              event.assetId,
              event.sourceStartSample,
              event.destinationStartSample,
              event.durationSamples,
              event.gain,
            ],
          )
          .toList(),
    };
    final expected = jsonDecode(
      File('test/fixtures/arrangement_seed_0_v1.json').readAsStringSync(),
    );
    expect(actual, expected);
  });

  test('seeds that normalize to uint32 zero use the defined nonzero state', () {
    final zero = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 0,
    );
    final wrapped = arrange(
      clips: threeFixtures,
      style: ArrangementStyle.sparse,
      seed: 0x100000000,
    );

    expect(wrapped.toJson(), zero.toJson());
  });

  test('checked-in analysis JSON round trips through the Dart contract', () {
    final json = jsonDecode(
      File('test/fixtures/media_analysis_v1.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final clip = AnalyzedClip.fromJson(json);
    expect(clip.toJson(), json);
    expect(clip.assetId, 'fixture-tap');
    expect(clip.onsetSamples, [960, 12000]);
  });
}

AnalyzedClip _clip(
  String id, {
  SuggestedRole role = SuggestedRole.sustain,
  List<int> onsets = const [1000],
  double peak = 0.8,
  double rms = 0.2,
}) => AnalyzedClip(
  assetId: id,
  durationSamples: 288000,
  sampleRate: 48000,
  onsetSamples: onsets,
  peak: peak,
  rms: rms,
  suggestedRole: role,
);

bool _fitsDestination(SoundEvent event) =>
    event.destinationStartSample >= 0 &&
    event.durationSamples > 0 &&
    event.destinationStartSample + event.durationSamples <= 720000;

bool _fitsSource(SoundEvent event, List<AnalyzedClip> clips) {
  final clip = clips.singleWhere(
    (candidate) => candidate.assetId == event.assetId,
  );
  return event.sourceStartSample >= clip.sourceStartSample &&
      event.sourceStartSample + event.durationSamples <=
          clip.sourceStartSample + clip.durationSamples;
}
