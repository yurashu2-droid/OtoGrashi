import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/playback_chrome.dart';
import '../../design/tokens.dart';
import '../../domain/project.dart';
import '../../media/media_delivery_gateway.dart';
import '../../media/media_presentation_gateway.dart';
import '../../storage/project_repository.dart';
import 'media_playback.dart';

/// Opens a previously exported video without regenerating the arrangement.
class CompletedVideoScreen extends StatefulWidget {
  const CompletedVideoScreen({
    required this.project,
    required this.export,
    this.versions = const <CompletedExport>[],
    required this.presentation,
    required this.delivery,
    super.key,
  });

  final Project project;
  final CompletedExport export;
  final List<CompletedExport> versions;
  final MediaPresentationGateway presentation;
  final MediaDeliveryGateway delivery;

  @override
  State<CompletedVideoScreen> createState() => _CompletedVideoScreenState();
}

class _CompletedVideoScreenState extends State<CompletedVideoScreen> {
  late final MediaPlaybackController playback = MediaPlaybackController(
    widget.presentation,
  );
  late CompletedExport _active = widget.export;
  bool _busy = false;
  bool _saved = false;
  String? _message;

  @override
  void dispose() {
    unawaited(playback.pause());
    playback.dispose();
    super.dispose();
  }

  Future<void> _deliver({required bool save}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (save) {
        await widget.delivery.saveToPhotos(_active.relativePath);
        if (mounted) {
          setState(() {
            _saved = true;
            _message = '写真に保存しました';
          });
        }
      } else {
        await widget.delivery.share(_active.relativePath);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = save
              ? '保存できませんでした。もう一度お試しください。'
              : '共有できませんでした。もう一度お試しください。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.project.title)),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          const Text(
            'あの瞬間が、曲になった',
            style: TextStyle(
              color: AppTokens.coral,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          if (widget.versions.length > 1) ...[
            DropdownButtonFormField<CompletedExport>(
              initialValue: _active,
              decoration: const InputDecoration(labelText: '完成版'),
              items: [
                for (var index = 0; index < widget.versions.length; index++)
                  DropdownMenuItem(
                    value: widget.versions[index],
                    child: Text('完成版 ${widget.versions.length - index}'),
                  ),
              ],
              onChanged: (value) {
                if (value == null || value == _active) return;
                unawaited(playback.pause());
                setState(() {
                  _active = value;
                  _saved = false;
                  _message = null;
                });
              },
            ),
            const SizedBox(height: 12),
          ],
          Center(
            child: SizedBox(
              width: 300,
              child: PlaybackChrome(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: NativeMovieView(
                    key: ValueKey(_active.id),
                    relativePath: _active.relativePath,
                    gateway: widget.presentation,
                    controller: playback,
                    fallback: const ColoredBox(color: AppTokens.ink),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedBuilder(
            animation: playback,
            builder: (context, _) => Row(
              children: [
                IconButton.filledTonal(
                  onPressed: playback.toggle,
                  tooltip: playback.isPlaying ? '一時停止' : '再生',
                  icon: Icon(
                    playback.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(child: Text('完成した15秒')),
                Text(
                  '${playback.position.inSeconds} / '
                  '${playback.duration.inSeconds}秒',
                ),
              ],
            ),
          ),
          AnimatedBuilder(
            animation: playback,
            builder: (context, _) => playback.error == null
                ? const SizedBox.shrink()
                : const Text('動画を再生できませんでした。'),
          ),
        ],
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_message != null) Text(_message!, textAlign: TextAlign.center),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _saved
                        ? null
                        : () => _deliver(save: true),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(_saved ? '保存済み' : '保存する'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : () => _deliver(save: false),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('シェアする'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTokens.coral,
                      foregroundColor: AppTokens.ink,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
