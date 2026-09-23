import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/clip_asset.dart';

/// A small visual rehearsal of the one-to-many video reveal while rendering.
class BeatBuildingPreview extends StatefulWidget {
  const BeatBuildingPreview({
    required this.clips,
    required this.thumbnails,
    super.key,
  });

  final List<ClipAsset> clips;
  final Map<String, Uint8List> thumbnails;

  @override
  State<BeatBuildingPreview> createState() => _BeatBuildingPreviewState();
}

class _BeatBuildingPreviewState extends State<BeatBuildingPreview> {
  Timer? _beat;
  var _step = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _beat?.cancel();
      _beat = null;
    } else {
      _beat ??= Timer.periodic(const Duration(milliseconds: 850), (_) {
        if (mounted) setState(() => _step = (_step + 1) % 4);
      });
    }
  }

  @override
  void dispose() {
    _beat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = MediaQuery.disableAnimationsOf(context) ? 3 : _step;
    return Semantics(
      label: '撮った音を組み立てています',
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(child: _scene(step)),
          Positioned(
            top: 12,
            left: 12,
            child: Transform.rotate(
              angle: -0.035,
              child: ColoredBox(
                color: AppTokens.paper,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  child: Text(
                    '音をつないでいます',
                    style: const TextStyle(
                      color: AppTokens.ink,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 14,
            left: 14,
            right: 14,
            child: Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  Expanded(
                    child: Container(
                      height: 3,
                      color: i == step ? AppTokens.coral : Colors.white54,
                    ),
                  ),
                  if (i < 3) const SizedBox(width: 4),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scene(int step) {
    if (widget.clips.isEmpty) {
      return const ColoredBox(color: Color(0xFF302D36));
    }
    if (step == 0 || widget.clips.length == 1) return _tile(0);
    if (step == 1) return _tile(1);
    if (step == 2) {
      return Column(
        children: [
          Expanded(
            flex: 55,
            child: Row(
              children: [
                Expanded(child: _tile(1)),
                Expanded(child: _tile(1, mirror: true)),
              ],
            ),
          ),
          Expanded(flex: 45, child: _tile(0)),
        ],
      );
    }
    final otherCount = widget.clips.length - 1;
    final rows = (otherCount + 1) ~/ 2;
    return Column(
      children: [
        Expanded(
          flex: 55,
          child: Column(
            children: [
              for (var row = 0; row < rows; row++)
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _tile(row * 2 + 1)),
                      if (row * 2 + 2 < widget.clips.length)
                        Expanded(child: _tile(row * 2 + 2)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Expanded(flex: 45, child: _tile(0)),
      ],
    );
  }

  Widget _tile(int index, {bool mirror = false}) {
    final clip = widget.clips[index];
    final bytes = widget.thumbnails[clip.id];
    final fallback = [
      const Color(0xFF8069B2),
      const Color(0xFFCB766D),
      const Color(0xFF63958B),
    ][index % 3];
    return Stack(
      fit: StackFit.expand,
      children: [
        bytes == null
            ? ColoredBox(color: fallback)
            : Transform.flip(
                flipX: mirror,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  excludeFromSemantics: true,
                ),
              ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0x88000000)],
            ),
          ),
        ),
        Positioned(
          left: 10,
          bottom: 24,
          child: Text(
            '音 ${(index + 1).toString().padLeft(2, '0')}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}
