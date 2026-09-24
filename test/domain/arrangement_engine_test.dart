import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/video_recipe.dart';

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

  test(
    'song templates assign recorded sounds to distinct roles and persist',
    () {
      final measuredFixtures = [
        threeFixtures[0],
        _clip(
          'hum',
          role: SuggestedRole.sustain,
          onsets: const [12000],
          pitch: 57,
        ),
        threeFixtures[2],
      ];
      for (final style in ArrangementStyle.values) {
        for (final melody in MelodyTemplate.values.where(
          (value) =>
              value != MelodyTemplate.none && value != MelodyTemplate.midiScore,
        )) {
          final arrangement = arrange(
            clips: measuredFixtures,
            style: style,
            melodyTemplate: melody,
            seed: 7,
          );
          expect(arrangement.melodyTemplate, melody);
          expect(arrangement.songRoles?.beat, 'tap');
          expect(arrangement.songRoles?.bass, 'hum');
          expect(arrangement.songRoles?.keys, 'room');
          expect(arrangement.songRoles?.melody, 'hum');
          expect(
            arrangement.events.length,
            lessThanOrEqualTo(Arrangement.maxEvents),
          );
          expect(arrangement.videoEvents.length, arrangement.events.length);
          expect(arrangement.events.every(_fitsDestination), isTrue);
          expect(
            arrangement.events.every(
              (event) => _fitsSource(event, measuredFixtures),
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
            arrangement.events.any((event) => event.targetMidiNote != null),
            isTrue,
          );
          expect(
            arrangement.events
                .where((event) => event.assetId == 'tap')
                .every((event) => event.pitchSemitones == 0),
            isTrue,
          );
          expect(
            arrangement.events.every(
              (event) => event.pitchSemitones.abs() <= 3,
            ),
            isTrue,
          );
          expect(
            Arrangement.fromJson(arrangement.toJson()).toJson(),
            arrangement.toJson(),
          );
        }
      }

      final patterns = MelodyTemplate.values
          .where(
            (value) =>
                value != MelodyTemplate.none &&
                value != MelodyTemplate.midiScore,
          )
          .map((melody) {
            final arranged = arrange(
              clips: measuredFixtures,
              style: ArrangementStyle.sparse,
              melodyTemplate: melody,
              seed: 7,
            );
            return arranged.events
                .map(
                  (event) => [
                    event.assetId,
                    event.destinationStartSample,
                    event.targetMidiNote,
                  ],
                )
                .toList()
                .toString();
          })
          .toSet();
      expect(patterns.length, 3);

      final noMelody = arrange(
        clips: threeFixtures,
        style: ArrangementStyle.sparse,
        seed: 7,
      );
      expect(noMelody.melodyTemplate, MelodyTemplate.none);
      expect(
        noMelody.events.every((event) => event.pitchSemitones == 0),
        isTrue,
      );

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

      oldEvents.first['pitchSemitones'] = 13;
      expect(
        () => Arrangement.fromJson({...oldJson, 'events': oldEvents}),
        throwsA(isA<MediaContractException>()),
      );
    },
  );

  test('short taps can be musical bass and melody without a stable pitch', () {
    final sounds = [
      for (var i = 0; i < 3; i++)
        _clip('tap-$i', role: SuggestedRole.transient),
    ];
    final result = arrange(
      clips: sounds,
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.hop,
      seed: 7,
    );
    expect(result.songRoles?.bass, isNotNull);
    expect(result.songRoles?.melody, isNotNull);
    expect(
      result.events.any(
        (e) => e.targetMidiNote != null && e.durationSamples >= 42000,
      ),
      isTrue,
    );
    expect(
      result.events.where((e) => e.treatment == SoundTreatment.phrase).length,
      3,
    );
  });

  test(
    'unmeasured and distant pitches are retuned instead of silently bypassed',
    () {
      for (final measured in [false, true]) {
        final result = arrange(
          clips: [
            _clip('tap', role: SuggestedRole.transient),
            _clip('voice', pitch: measured ? 57.0144 : null),
            _clip('other-tone', pitch: measured ? 81.2 : null),
          ],
          style: ArrangementStyle.sparse,
          melodyTemplate: MelodyTemplate.hop,
          seed: 7,
        );
        expect(result.songRoles?.melody, isNotNull);
        expect(
          result.events.where((e) => e.targetMidiNote != null).length,
          greaterThan(10),
        );
        expect(
          result.events.any(
            (e) =>
                e.treatment == SoundTreatment.phrase &&
                e.targetMidiNote == null,
          ),
          isTrue,
        );
        expect(Arrangement.fromJson(result.toJson()).toJson(), result.toJson());
      }
    },
  );

  test('fractional measured pitch does not disable boundary notes', () {
    final input = _clip('voice', pitch: 57.35);
    final result = arrange(
      clips: [input],
      style: ArrangementStyle.sparse,
      melodyTemplate: MelodyTemplate.hop,
      seed: 7,
    );
    final tuned = result.events.where((e) => e.targetMidiNote != null);
    expect(tuned.any((e) => (e.targetMidiNote! - 57.35).abs() > 3), isTrue);
    expect(tuned.every((e) => e.sourceDurationSamples != null), isTrue);
    expect(AnalyzedClip.fromJson(input.toJson()).fundamentalMidiNote, 57.35);
    expect(
      () => AnalyzedClip.fromJson({
        ...input.toJson(),
        'fundamentalMidiNote': double.nan,
      }),
      throwsA(isA<MediaContractException>()),
    );
  });

  test('six user clips all sound in the busiest song template', () {
    final clips = [
      _clip('beat', role: SuggestedRole.transient),
      _clip('bass', role: SuggestedRole.sustain),
      _clip('keys', role: SuggestedRole.texture),
      _clip('extra-1', role: SuggestedRole.transient),
      _clip('extra-2', role: SuggestedRole.texture),
      _clip('extra-3', role: SuggestedRole.transient),
    ];
    final arranged = arrange(
      clips: clips,
      style: ArrangementStyle.lively,
      melodyTemplate: MelodyTemplate.answer,
      seed: 7,
    );
    expect(arranged.events.length, lessThanOrEqualTo(Arrangement.maxEvents));
    expect(
      arranged.events.map((event) => event.assetId).toSet(),
      clips.map((clip) => clip.assetId).toSet(),
    );
    expect(arranged.events.every(_fitsDestination), isTrue);
    expect(arranged.events.every((event) => _fitsSource(event, clips)), isTrue);
  });

  test('song intro displays the same recorded source that sounds', () {
    final clips = [threeFixtures[2], threeFixtures[1], threeFixtures[0]];
    final arranged = arrange(
      clips: clips,
      style: ArrangementStyle.swaying,
      melodyTemplate: MelodyTemplate.hop,
      seed: 7,
    );
    final recipe = VideoRecipe.fromArrangement(
      arrangement: arranged,
      layout: VideoLayout.buildUp,
    );
    expect(recipe.events.first.primaryAssetId, clips.first.assetId);
    for (final scene in recipe.events.take(3)) {
      expect(
        arranged.events.any(
          (event) =>
              event.assetId == scene.primaryAssetId &&
              event.destinationStartSample < scene.destinationEndSample &&
              event.destinationStartSample + event.durationSamples >
                  scene.destinationStartSample,
        ),
        isTrue,
      );
    }
  });

  test(
    'persisted arrangement rejects more than six assets or the event budget',
    () {
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
          'events': List<Object?>.filled(Arrangement.maxEvents + 1, audio),
          'videoEvents': List<Object?>.filled(Arrangement.maxEvents + 1, video),
        }),
        throwsA(isA<MediaContractException>()),
      );
    },
  );

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
            event.sourceStartSample + event.effectiveSourceDurationSamples <=
                144000,
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

  test('late onset cannot move an event beyond its audible region', () {
    final clips = [
      _clip('tap', role: SuggestedRole.transient),
      AnalyzedClip(
        assetId: 'voice',
        durationSamples: 144000,
        sampleRate: 48000,
        onsetSamples: const [95000],
        audibleRegions: const [
          AudibleRegion(startSample: 72000, durationSamples: 24000),
        ],
        peak: .7,
        rms: .2,
        suggestedRole: SuggestedRole.sustain,
      ),
      _clip('room', role: SuggestedRole.texture),
    ];
    final arranged = arrange(
      clips: clips,
      style: ArrangementStyle.sparse,
      melodyTemplate: MelodyTemplate.hop,
      seed: 3,
    );
    final voiceEvents = arranged.events.where(
      (event) => event.assetId == 'voice',
    );
    expect(voiceEvents, isNotEmpty);
    expect(
      voiceEvents.every(
        (event) =>
            event.sourceStartSample >= 72000 &&
            event.sourceStartSample + event.effectiveSourceDurationSamples <=
                96000,
      ),
      isTrue,
    );
  });

  test('sustained voice keeps the beginning of its audible phrase', () {
    final arranged = arrange(
      clips: [
        _clip('tap', role: SuggestedRole.transient),
        AnalyzedClip(
          assetId: 'voice',
          durationSamples: 144000,
          sampleRate: 48000,
          onsetSamples: const [84000, 90000],
          audibleRegions: const [
            AudibleRegion(startSample: 72000, durationSamples: 36000),
          ],
          peak: .7,
          rms: .2,
          suggestedRole: SuggestedRole.sustain,
        ),
        _clip('room', role: SuggestedRole.texture),
      ],
      style: ArrangementStyle.sparse,
      seed: 3,
    );
    final voiceEvents = arranged.events.where(
      (event) => event.assetId == 'voice',
    );
    expect(voiceEvents, isNotEmpty);
    expect(
      voiceEvents.every((event) => event.sourceStartSample == 72000),
      isTrue,
    );
  });

  test(
    'song roles include short unpitched sounds while legacy analyses work',
    () {
      AnalyzedClip analyzed(
        String id,
        SuggestedRole role,
        int audibleLength,
        double rms,
      ) => AnalyzedClip(
        assetId: id,
        durationSamples: 144000,
        sampleRate: 48000,
        onsetSamples: const [],
        audibleRegions: [
          AudibleRegion(startSample: 48000, durationSamples: audibleLength),
        ],
        peak: .7,
        rms: rms,
        suggestedRole: role,
      );
      final song = arrange(
        clips: [
          _clip('tap', role: SuggestedRole.transient),
          analyzed('short-voice', SuggestedRole.sustain, 8000, .4),
          analyzed('long-voice', SuggestedRole.sustain, 24000, .2),
          analyzed('short-room', SuggestedRole.texture, 8000, .4),
          analyzed('long-room', SuggestedRole.texture, 16000, .2),
        ],
        style: ArrangementStyle.swaying,
        melodyTemplate: MelodyTemplate.hop,
        seed: 4,
      );
      expect(song.songRoles?.bass, 'long-voice');
      expect(song.songRoles?.melody, isNotNull);
      expect(song.songRoles?.keys, isNotNull);
      expect(song.events.map((event) => event.assetId).toSet(), {
        'tap',
        'short-voice',
        'long-voice',
        'short-room',
        'long-room',
      });
      // Unknown F0 no longer means the source cannot carry a melody.
      expect(
        song.events.where((event) => event.targetMidiNote != null),
        isNotEmpty,
      );
      expect(
        song.events.where((event) => event.assetId == 'short-voice'),
        isNotEmpty,
      );

      final legacy = arrange(
        clips: [
          _clip('tap', role: SuggestedRole.transient),
          _clip('old-voice', role: SuggestedRole.sustain),
          _clip('room', role: SuggestedRole.texture),
        ],
        style: ArrangementStyle.sparse,
        melodyTemplate: MelodyTemplate.hop,
        seed: 4,
      );
      expect(legacy.songRoles?.melody, 'old-voice');
    expect(legacy.songRoles?.bass, 'room');
    },
  );

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
  double? pitch,
}) => AnalyzedClip(
  assetId: id,
  durationSamples: 288000,
  sampleRate: 48000,
  onsetSamples: onsets,
  peak: peak,
  rms: rms,
  suggestedRole: role,
  fundamentalMidiNote: pitch,
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
      event.sourceStartSample + event.effectiveSourceDurationSamples <=
          clip.sourceStartSample + clip.durationSamples;
}
