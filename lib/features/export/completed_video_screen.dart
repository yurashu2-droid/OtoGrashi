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
  double? _scrubValue;

  void _selectVersion(CompletedExport value) {
    if (value == _active) return;
    unawaited(playback.pause());
    setState(() {
      _active = value;
      _saved = false;
      _message = null;
      _scrubValue = null;
    });
  }

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
    appBar: AppBar(title: const Text('できあがり！'), centerTitle: true),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
        children: [
          Text(
            widget.project.title.isEmpty ? '無題の作品' : widget.project.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 3),
          Text(
            '${_active.createdAt.toLocal().month}月${_active.createdAt.toLocal().day}日の完成版 · ${widget.project.clipIds.length}つの音',
            style: const TextStyle(color: AppTokens.mutedInk),
          ),
          if (widget.versions.length > 1) ...[
            const SizedBox(height: 13),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.versions.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final version = widget.versions[index];
                  return ChoiceChip(
                    label: Text('完成版 ${widget.versions.length - index}'),
                    selected: version == _active,
                    onSelected: (_) => _selectVersion(version),
                    selectedColor: AppTokens.paper,
                    side: BorderSide(
                      color: version == _active
                          ? AppTokens.coral
                          : const Color(0xFFE7DCD2),
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 13),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: PlaybackChrome(
                child: AspectRatio(
                  aspectRatio: 9 / 16,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NativeMovieView(
                        key: ValueKey(_active.id),
                        relativePath: _active.relativePath,
                        gateway: widget.presentation,
                        controller: playback,
                        fallback: const ColoredBox(color: AppTokens.ink),
                      ),
                      AnimatedBuilder(
                        animation: playback,
                        builder: (context, _) => Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: playback.toggle,
                            child: Center(
                              child: playback.isPlaying
                                  ? const SizedBox.shrink()
                                  : Container(
                                      width: 62,
                                      height: 62,
                                      decoration: const BoxDecoration(
                                        color: Color(0xEFFFFFFF),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 42,
                                        color: AppTokens.ink,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedBuilder(
            animation: playback,
            builder: (context, _) {
              final duration = playback.duration.inMilliseconds;
              final ratio = duration <= 0
                  ? 0.0
                  : (playback.position.inMilliseconds / duration).clamp(
                      0.0,
                      1.0,
                    );
              return Column(
                children: [
                  Row(
                    children: [
                      Text(_time(playback.position)),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 3,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                          ),
                          child: Slider(
                            value: _scrubValue ?? ratio,
                            onChanged: playback.isReady
                                ? (value) => setState(() => _scrubValue = value)
                                : null,
                            onChangeEnd: (value) {
                              setState(() => _scrubValue = null);
                              unawaited(
                                playback.seek(
                                  Duration(
                                    milliseconds: (duration * value).round(),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      Text(_time(playback.duration)),
                    ],
                  ),
                  if (playback.error != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('動画を再生できませんでした。'),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        decoration: const BoxDecoration(
          color: AppTokens.surfaceColor,
          border: Border(top: BorderSide(color: Color(0xFFE7DCD2))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(_message!, textAlign: TextAlign.center),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _saved
                        ? null
                        : () => _deliver(save: true),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(_saved ? '保存済み' : '保存する'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                    ),
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
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 52),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
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

  String _time(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
}
