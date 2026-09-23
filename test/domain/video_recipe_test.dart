import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/video_recipe.dart';

void main() {
  test('sample timing rounds a half frame toward the later frame', () {
    expect(VideoRecipe.nearestFrameForSample(799), 0);
    expect(VideoRecipe.nearestFrameForSample(800), 1);
    expect(VideoRecipe.nearestFrameForSample(12000), 8);
  });

  test('missing effects decode as no effects', () {
    final json = _recipe(VideoLayout.stacked).toJson()..remove('effects');

    final decoded = VideoRecipe.fromJson(json);

    expect(decoded.effects, VideoEffects.none);
    expect(decoded.toJson()['effects'], <String, Object?>{
      'enabled': <Object?>[],
    });
  });

  test('all layouts use bar-boundary scenes and show every source', () {
    for (final layout in VideoLayout.values) {
      final recipe = VideoRecipe.fromArrangement(
        arrangement: _arrangement(),
        layout: layout,
      );

      expect(
        recipe.events.every(
          (event) => event.destinationStartSample % Arrangement.barSamples == 0,
        ),
        isTrue,
      );
      expect(
        recipe.events.expand((event) => event.assetIds).toSet(),
        _arrangement().sourceAssetIds.toSet(),
      );
      expect(recipe.events.last.destinationEndSample, 720000);
    }
  });

  test('build-up introduces solo clips before the shared frame', () {
    final recipe = VideoRecipe.fromArrangement(
      arrangement: _arrangementWithSourceCount(3),
      layout: VideoLayout.buildUp,
    );
    expect(recipe.events.take(3).map((scene) => scene.assetIds), [
      ['asset-0'],
      ['asset-1'],
      ['asset-2'],
    ]);
    expect(recipe.events[3].assetIds, ['asset-0', 'asset-1']);
    expect(recipe.events[5].assetIds, ['asset-0', 'asset-1', 'asset-2']);
  });

  test('build-up foregrounds the sound heard in each mixed bar', () {
    final recipe = VideoRecipe.fromArrangement(
      arrangement: _arrangementWithSourceCount(
        3,
        events: const [
          SoundEvent(
            assetId: 'asset-2',
            sourceStartSample: 0,
            destinationStartSample: 270000,
            durationSamples: 9000,
            gain: .8,
            fades: EventFades(fadeInSamples: 0, fadeOutSamples: 0),
          ),
        ],
      ),
      layout: VideoLayout.buildUp,
    );
    expect(recipe.events[3].assetIds, ['asset-0', 'asset-2']);
  });

  test('silent rejected source does not take an intro video slot', () {
    final recipe = VideoRecipe.fromArrangement(
      arrangement: _arrangementWithSourceCount(
        4,
        unusableAssetIds: const ['asset-0'],
      ),
      layout: VideoLayout.buildUp,
    );
    expect(recipe.events.take(3).map((scene) => scene.assetIds.single), [
      'asset-1',
      'asset-2',
      'asset-3',
    ]);
    expect(
      recipe.events.expand((scene) => scene.assetIds),
      isNot(contains('asset-0')),
    );
  });

  test(
    'four to six sources switch at the middle boundary and appear by the end',
    () {
      for (var sourceCount = 4; sourceCount <= 6; sourceCount++) {
        final arrangement = _arrangementWithSourceCount(sourceCount);
        for (final layout in VideoLayout.values) {
          final recipe = VideoRecipe.fromArrangement(
            arrangement: arrangement,
            layout: layout,
          );
          final firstHalf = recipe.events
              .where((event) => event.destinationStartSample < 360000)
              .expand((event) => event.assetIds)
              .toSet();
          final secondHalf = recipe.events
              .where((event) => event.destinationEndSample > 360000)
              .expand((event) => event.assetIds)
              .toSet();

          expect(
            recipe.events.any(
              (event) => event.destinationStartSample == 360000,
            ),
            isTrue,
          );
          expect(
            firstHalf,
            isNotEmpty,
            reason: '$layout/$sourceCount first half',
          );
          expect(
            secondHalf,
            isNotEmpty,
            reason: '$layout/$sourceCount second half',
          );
          expect(
            <String>{...firstHalf, ...secondHalf},
            arrangement.sourceAssetIds.toSet(),
            reason: '$layout/$sourceCount all sources by end',
          );
        }
      }
    },
  );
}

VideoRecipe _recipe(VideoLayout layout) =>
    VideoRecipe.fromArrangement(arrangement: _arrangement(), layout: layout);

Arrangement _arrangement() => Arrangement(
  templateId: 'fixture',
  templateVersion: 1,
  analysisVersion: 1,
  rendererVersion: 1,
  seed: 42,
  style: ArrangementStyle.sparse,
  sourceAssetIds: const <String>['one', 'two', 'three', 'four', 'five', 'six'],
  unusableAssetIds: const <String>[],
  events: const <SoundEvent>[],
  videoEvents: const <VideoEvent>[],
);

Arrangement _arrangementWithSourceCount(
  int count, {
  List<SoundEvent> events = const <SoundEvent>[],
  List<String> unusableAssetIds = const <String>[],
}) => Arrangement(
  templateId: 'fixture',
  templateVersion: 1,
  analysisVersion: 1,
  rendererVersion: 1,
  seed: 42,
  style: ArrangementStyle.sparse,
  sourceAssetIds: List<String>.generate(count, (index) => 'asset-$index'),
  unusableAssetIds: unusableAssetIds,
  events: events,
  videoEvents: events
      .map(
        (event) => VideoEvent(
          assetId: event.assetId,
          destinationStartSample: event.destinationStartSample,
          durationSamples: event.durationSamples,
          sourceVideoStartTime: RationalTime(event.sourceStartSample, 48000),
          crop: NormalizedCrop.fullFrame,
          loopMode: VideoLoopMode.once,
        ),
      )
      .toList(),
);
