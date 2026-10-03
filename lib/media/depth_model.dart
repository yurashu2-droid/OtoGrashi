import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_media_gateway.dart';

enum DepthModelPhase { unknown, absent, downloading, ready, failed }

@immutable
final class DepthModelState {
  const DepthModelState(this.phase, {this.progress = 0, this.message});

  final DepthModelPhase phase;
  final double progress;
  final String? message;
}

/// The depth model behind とびだす is not part of the app: the form is added by
/// downloading it once (about 50 MB). This tracks whether it is on the phone.
final class DepthModel extends ValueNotifier<DepthModelState> {
  DepthModel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(PlatformMediaGateway.channelName),
      super(const DepthModelState(DepthModelPhase.unknown));

  static final instance = DepthModel();
  static const megabytes = 50;

  final MethodChannel _channel;
  Timer? _poll;

  bool get isReady => value.phase == DepthModelPhase.ready;

  Future<void> refresh() async {
    try {
      final status = await _channel.invokeMapMethod<String, Object?>(
        'depthModelStatus',
      );
      _apply(status);
    } on MissingPluginException {
      value = const DepthModelState(DepthModelPhase.absent);
    } on PlatformException catch (error) {
      value = DepthModelState(DepthModelPhase.failed, message: error.message);
    }
  }

  /// Downloads and prepares the model; true when it is ready to use.
  Future<bool> download() async {
    if (isReady) return true;
    value = const DepthModelState(DepthModelPhase.downloading);
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 400), (_) => refresh());
    try {
      final status = await _channel.invokeMapMethod<String, Object?>(
        'downloadDepthModel',
      );
      _poll?.cancel();
      _apply(status);
    } on PlatformException catch (error) {
      _poll?.cancel();
      value = DepthModelState(DepthModelPhase.failed, message: error.message);
    } on MissingPluginException {
      _poll?.cancel();
      value = const DepthModelState(
        DepthModelPhase.failed,
        message: 'この端末では使えません',
      );
    }
    return isReady;
  }

  void _apply(Map<String, Object?>? status) {
    final state = status?['state'];
    value = switch (state) {
      'ready' => const DepthModelState(DepthModelPhase.ready),
      'downloading' => DepthModelState(
        DepthModelPhase.downloading,
        progress: (status?['progress'] as num?)?.toDouble() ?? 0,
      ),
      'failed' => DepthModelState(
        DepthModelPhase.failed,
        message: status?['message'] as String?,
      ),
      _ => const DepthModelState(DepthModelPhase.absent),
    };
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
