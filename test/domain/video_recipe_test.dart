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
