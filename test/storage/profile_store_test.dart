import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/domain/arrangement.dart';
import 'package:otogurashi/domain/arrangement_engine.dart';
import 'package:otogurashi/domain/melody_template.dart';
import 'package:otogurashi/domain/video_recipe.dart';
import 'package:otogurashi/storage/profile_store.dart';

void main() {
  test('the cover name is kept on the device, tidied and bounded', () async {
    final root = await Directory.systemTemp.createTemp('otogurashi-profile-');
    addTearDown(() => root.delete(recursive: true));
    final store = ProfileStore(File('${root.path}/owner_name.txt'));
    expect(await store.loadName(), isNull);
    expect(await store.saveName('  ゆうた \n'), 'ゆうた');
    expect(await store.loadName(), 'ゆうた');
    expect(await store.saveName('あいうえおかきくけこさしすせそ'), 'あいうえおかきくけこさし');
    expect(await store.saveName('   '), isNull);
    expect(await store.loadName(), isNull);
  });

  test('a recipe carries the owner name to the renderer', () {
    final clip = AnalyzedClip(
      assetId: 'voice',
      durationSamples: 96000,
      sampleRate: 48000,
      onsetSamples: const [4800],
      peak: .8,
      rms: .2,
      suggestedRole: SuggestedRole.sustain,
    );
    final arrangement = arrange(
      clips: [clip],
      style: ArrangementStyle.lively,
      seed: 1,
      melodyTemplate: MelodyTemplate.none,
      durationSeconds: 15,
    );
    final json = VideoRecipe.fromArrangement(
      arrangement: arrangement,
      layout: VideoLayout.buildUp,
    ).toJson()..['ownerName'] = 'ゆうた';
    final recipe = VideoRecipe.fromJson(json);
    expect(recipe.ownerName, 'ゆうた');
    expect(recipe.toJson()['ownerName'], 'ゆうた');
    expect(
      () => VideoRecipe.fromJson({...json, 'ownerName': ' '}),
      throwsA(isA<MediaContractException>()),
    );
  });
}
