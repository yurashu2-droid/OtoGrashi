import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/video_recipe.dart';

void main() {
  test('148 score events survive the direct render payload and round trip', () {
    final arrangement = _arrangement(148);
    final decoded = Arrangement.fromJson(arrangement.toJson());
    final recipe = VideoRecipe.fromArrangement(
      arrangement: decoded,
      layout: VideoLayout.stacked,
    );

    expect(decoded.events, hasLength(148));
    expect(decoded.videoEvents, hasLength(148));
    expect(decoded.events.first.pitchSemitones, -12);
    expect(decoded.events.last.pitchSemitones, 12);
    expect(VideoRecipe.fromJson(recipe.toJson()).events, isNotEmpty);
    for (var index = 0; index < decoded.events.length; index++) {
      expect(
        decoded.videoEvents[index].destinationStartSample,
        decoded.events[index].destinationStartSample,
      );
      expect(
        decoded.videoEvents[index].durationSamples,
        decoded.events[index].durationSamples,
      );
    }
  });

  test('512 events fit but 513 and mismatched video events are rejected', () {
    expect(
      Arrangement.fromJson(_arrangement(Arrangement.maxEvents).toJson()).events,
      hasLength(Arrangement.maxEvents),
    );
    final json = _arrangement(Arrangement.maxEvents).toJson();
    final audio = (json['events'] as List<Object?>).first;
    final video = (json['videoEvents'] as List<Object?>).first;
    expect(
      () => Arrangement.fromJson({
        ...json,
        'events': List<Object?>.filled(Arrangement.maxEvents + 1, audio),
        'videoEvents': List<Object?>.filled(Arrangement.maxEvents + 1, video),
      }),
      throwsA(isA<MediaContractException>()),
    );
    expect(
      () => Arrangement.fromJson({
        ...json,
        'videoEvents': (json['videoEvents'] as List<Object?>).sublist(1),
      }),
      throwsA(isA<MediaContractException>()),
    );
  });

  test('pitch outside one octave and nonfinite pitch are rejected', () {
    final json = _arrangement(1).toJson();
    for (final invalid in <double>[12.01, -12.01, double.nan]) {
      final event = Map<String, Object?>.from(
        (json['events'] as List<Object?>).first! as Map,
      )..['pitchSemitones'] = invalid;
      expect(
        () => Arrangement.fromJson({
          ...json,
          'events': [event],
        }),
        throwsA(isA<MediaContractException>()),
      );
    }
  });

  test('source sample end cannot overflow the native integer range', () {
    final json = _arrangement(1).toJson();
    final event = Map<String, Object?>.from(
      (json['events'] as List<Object?>).first! as Map,
    )..['sourceStartSample'] = 9223372036854775807;
    final video =
        Map<String, Object?>.from(
            (json['videoEvents'] as List<Object?>).first! as Map,
          )
          ..['sourceVideoStartTime'] = {
            'numerator': 9223372036854775807,
            'denominator': 48000,
          };
    expect(
      () => Arrangement.fromJson({
        ...json,
        'events': [event],
        'videoEvents': [video],
      }),
      throwsA(isA<MediaContractException>()),
    );
  });
}

Arrangement _arrangement(int count) {
  final events = List<SoundEvent>.generate(count, (index) {
    final start = index * 1_000;
    return SoundEvent(
      assetId: 'one',
      sourceStartSample: 0,
      destinationStartSample: start,
      durationSamples: 1_000,
      gain: 0.5,
      fades: const EventFades(fadeInSamples: 120, fadeOutSamples: 120),
      pitchSemitones: index.isEven ? -12 : 12,
    );
  });
  return Arrangement(
    templateId: 'score-fixture',
    templateVersion: 1,
    analysisVersion: 1,
    rendererVersion: 1,
    seed: 1,
    style: ArrangementStyle.sparse,
    sourceAssetIds: const ['one', 'two', 'three'],
    unusableAssetIds: const [],
    events: events,
    videoEvents: [
      for (final event in events)
        VideoEvent(
          assetId: event.assetId,
          destinationStartSample: event.destinationStartSample,
          durationSamples: event.durationSamples,
          sourceVideoStartTime: const RationalTime(0, 48000),
          crop: NormalizedCrop.fullFrame,
          loopMode: VideoLoopMode.once,
        ),
    ],
  );
}
