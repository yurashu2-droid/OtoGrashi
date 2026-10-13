import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otogurashi/media/depth_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.otogurashi/depth-model-test');
  final calls = <MethodCall>[];
  // what the phone answers; null stands for a build without the plugin
  String? state;

  setUp(() {
    calls.clear();
    state = 'absent';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (state == null) throw MissingPluginException();
          if (call.method == 'deleteDepthModel') state = 'absent';
          return <String, Object?>{'state': state};
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  DepthModel newModel() {
    final model = DepthModel(channel: channel);
    addTearDown(model.dispose);
    return model;
  }

  test('a phone without the model reports it as absent', () async {
    final model = newModel();
    expect(model.value.phase, DepthModelPhase.unknown);

    await model.refresh();

    expect(model.value.phase, DepthModelPhase.absent);
    expect(model.isReady, isFalse);
    expect(calls.single.method, 'depthModelStatus');
  });

  test('a downloaded model reports as ready', () async {
    state = 'ready';
    final model = newModel();

    await model.refresh();

    expect(model.value.phase, DepthModelPhase.ready);
    expect(model.isReady, isTrue);
  });

  test('delete takes a ready model off the phone', () async {
    state = 'ready';
    final model = newModel();
    await model.refresh();

    expect(await model.delete(), isTrue);

    expect(model.value.phase, DepthModelPhase.absent);
    expect(calls.map((call) => call.method), <String>[
      'depthModelStatus',
      'deleteDepthModel',
    ]);
  });

  test('delete leaves a running download alone', () async {
    state = 'downloading';
    final model = newModel();
    await model.refresh();

    expect(await model.delete(), isFalse);

    expect(model.value.phase, DepthModelPhase.downloading);
    expect(calls.single.method, 'depthModelStatus');
  });

  test('refresh and delete do not throw when the plugin is missing', () async {
    state = null;
    final model = newModel();

    await model.refresh();
    expect(model.value.phase, DepthModelPhase.absent);

    expect(await model.delete(), isTrue);
    expect(model.value.phase, DepthModelPhase.absent);
  });
}
