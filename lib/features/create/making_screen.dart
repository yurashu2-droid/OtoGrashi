import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';

/// Shown while the first preview of a song renders: the collected sounds
/// hop one after another, their colours bounce as a little equaliser, and a
/// line of text says what is happening.
///
/// Driven by a periodic timer plus implicit animations (not a repeating
/// controller), so tests can still settle while a render is pending.
final class MakingScreen extends StatefulWidget {
  const MakingScreen({
    required this.clips,
    required this.thumbnails,
    required this.seconds,
    super.key,
  });

  final List<ClipAsset> clips;
  final Map<String, Uint8List> thumbnails;
  final int seconds;

  @override
  State<MakingScreen> createState() => _MakingScreenState();
}

class _MakingScreenState extends State<MakingScreen> {
  static const _tick = Duration(milliseconds: 240);
  static const _steps = ['音をならべてる', 'リズムにしてる', 'メロディをのせてる', '映像をあわせてる'];
  static const _bars = 18;

  Timer? _timer;
  var _step = 0;
  final _started = DateTime.now();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(_tick, (_) {
        if (mounted) setState(() => _step++);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // No real progress comes from the renderer, so the bar eases toward 90%
  // over roughly the expected time and waits there for the finish.
  double get _progress {
    final expected = 4.0 + widget.seconds * 0.5;
    final elapsed = DateTime.now().difference(_started).inMilliseconds / 1000;
    return 0.9 * (1 - math.exp(-elapsed / expected * 1.6));
  }

  double _barHeight(int i) {
    final x = math.sin(_step * 0.9 + i * 1.7) * math.cos(_step * 0.37 + i);
    return 10 + 30 * x.abs();
  }

  @override
  Widget build(BuildContext context) {
    final clips = widget.clips.take(6).toList();
    final hopping = clips.isEmpty ? -1 : _step % (clips.length + 2);
    final line = _steps[(_step ~/ 7) % _steps.length];
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '曲をつくっています',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: AppTokens.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.seconds}秒 · ${widget.clips.length}つの音',
                style: const TextStyle(fontSize: 12, color: AppTokens.mutedInk),
              ),
              const SizedBox(height: 18),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTokens.tile,
                    borderRadius: BorderRadius.circular(AppTokens.tileRadius),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 84,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (var i = 0; i < clips.length; i++)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: _HoppingSound(
                                  image: widget.thumbnails[clips[i].id],
                                  color: AppTokens.soundColor(i),
                                  number: i + 1,
                                  up: i == hopping,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      SizedBox(
                        height: 42,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (var i = 0; i < _bars; i++)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: AnimatedContainer(
                                  duration: _tick,
                                  curve: Curves.easeInOut,
                                  width: 4,
                                  height: _barHeight(i),
                                  decoration: BoxDecoration(
                                    color: AppTokens.soundColor(
                                      clips.isEmpty ? 0 : i % clips.length,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      SizedBox(
                        height: 26,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 320),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, 0.6),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: Text(
                            line,
                            key: ValueKey(line),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: AppTokens.ink,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: 200,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: _progress,
                            minHeight: 6,
                            color: AppTokens.ink,
                            backgroundColor: AppTokens.hairline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'できあがるまで、少しだけ待ってね',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppTokens.mutedInk),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _HoppingSound extends StatelessWidget {
  const _HoppingSound({
    required this.image,
    required this.color,
    required this.number,
    required this.up,
  });

  final Uint8List? image;
  final Color color;
  final int number;
  final bool up;

  @override
  Widget build(BuildContext context) => AnimatedSlide(
    offset: up ? const Offset(0, -0.45) : Offset.zero,
    duration: const Duration(milliseconds: 220),
    curve: up ? Curves.easeOut : Curves.bounceOut,
    child: AnimatedScale(
      // a little squash on the way down, a stretch on the way up
      scale: up ? 1.08 : 1,
      duration: const Duration(milliseconds: 220),
      child: SizedBox.square(
        dimension: 44,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: image != null
                    ? Image.memory(
                        image!,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            ColoredBox(color: color),
                      )
                    : ColoredBox(color: color),
              ),
            ),
            Positioned(
              left: -4,
              top: -4,
              child: Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTokens.tile, width: 1.5),
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
