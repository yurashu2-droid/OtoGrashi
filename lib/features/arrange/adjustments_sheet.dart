import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/arrangement.dart';
import '../../domain/clip_asset.dart';
import '../../domain/video_recipe.dart';
import '../create/creation_controller.dart';

Future<void> showAdjustmentsSheet(
  BuildContext context,
  CreationController controller,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => AdjustmentsSheet(controller: controller),
);

final class AdjustmentsSheet extends StatefulWidget {
  const AdjustmentsSheet({required this.controller, super.key});

  final CreationController controller;

  @override
  State<AdjustmentsSheet> createState() => _AdjustmentsSheetState();
}

final class _AdjustmentsSheetState extends State<AdjustmentsSheet> {
  late String? _assetId = widget.controller.state.clips.firstOrNull?.id;
  late final TextEditingController _caption = TextEditingController(
    text: _existingCaption,
  );
  final _captionIndex = 0;
  var _trimStartUs = 0;
  late int _trimDurationUs = _selectedClip?.selectionDurationUs ?? 1;
  var _cropWidth = 1.0;
  double? _pendingGain;
  double? _pendingAccompaniment;

  ClipAsset? get _selectedClip => widget.controller.state.clips
      .where((clip) => clip.id == _assetId)
      .firstOrNull;

  String get _existingCaption {
    final value = widget.controller.state.project?.videoRecipe['captions'];
    if (value is! List || value.isEmpty || value.first is! Map) return '';
    return (value.first as Map)['text'] as String? ?? '';
  }

  double get _gain {
    final events = widget.controller.state.project?.arrangement['events'];
    if (events is List) {
      for (final value in events) {
        if (value is Map && value['assetId'] == _assetId) {
          final gain = value['gain'];
          if (gain is num) return gain.toDouble().clamp(0, 1);
        }
      }
    }
    return .8;
  }

  double get _accompaniment {
    final value =
        widget.controller.state.project?.arrangement['accompanimentGain'];
    return value is num ? value.toDouble().clamp(0, 1) : .25;
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('かんたん調整', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            _assetPicker(),
            const SizedBox(height: 8),
            Text('素材名', style: Theme.of(context).textTheme.titleMedium),
            Text(_selectedClip?.label ?? '素材を選んでください'),
            const SizedBox(height: 12),
            Text('素材の音量', style: Theme.of(context).textTheme.titleMedium),
            Slider(
              value: _pendingGain ?? _gain,
              label: '${(_gain * 100).round()}%',
              onChanged: _assetId == null
                  ? null
                  : (value) => setState(() => _pendingGain = value),
              onChangeEnd: _assetId == null
                  ? null
                  : (value) =>
                        unawaited(widget.controller.setGain(_assetId!, value)),
            ),
            Text('伴奏量', style: Theme.of(context).textTheme.titleMedium),
            Slider(
              value: _pendingAccompaniment ?? _accompaniment,
              label: '${(_accompaniment * 100).round()}%',
              onChanged: (value) =>
                  setState(() => _pendingAccompaniment = value),
              onChangeEnd: (value) =>
                  unawaited(widget.controller.setAccompanimentGain(value)),
            ),
            const SizedBox(height: 8),
            Text('切り出し', style: Theme.of(context).textTheme.titleMedium),
            _trimControls(),
            const SizedBox(height: 8),
            Text('クロップ', style: Theme.of(context).textTheme.titleMedium),
            Slider(
              value: _cropWidth,
              min: .25,
              max: 1,
              label: '${(_cropWidth * 100).round()}%',
              onChanged: (value) => setState(() => _cropWidth = value),
              onChangeEnd: (value) {
                final id = _assetId;
                if (id != null) {
                  unawaited(
                    widget.controller.setCrop(
                      id,
                      NormalizedCrop(x: 0, y: 0, width: value, height: 1),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            Text('字幕・短い一言', style: Theme.of(context).textTheme.titleMedium),
            TextField(
              controller: _caption,
              onChanged: (_) => setState(() {}),
              maxLength: 80,
              decoration: const InputDecoration(
                hintText: 'たとえば「朝のコップ」',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 8),
            Text('動画の見せ方', style: Theme.of(context).textTheme.titleMedium),
            RadioGroup<VideoLayout>(
              groupValue: widget.controller.state.layout,
              onChanged: (value) {
                if (value != null) widget.controller.setLayout(value);
              },
              child: Column(
                children: [
                  for (final entry in const <VideoLayout, String>{
                    VideoLayout.buildUp: 'ひとつずつ → 音に合わせて増える',
                    VideoLayout.stacked: '3段で見せる',
                    VideoLayout.sequentialFocus: '順番に大きく',
                    VideoLayout.photoDump: 'フォトダンプ',
                  }.entries)
                    RadioListTile<VideoLayout>(
                      value: entry.key,
                      title: Text(entry.value),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            FilledButton(
              onPressed: () {
                unawaited(
                  _caption.text.trim().isEmpty
                      ? widget.controller.removeCaption(_captionIndex)
                      : widget.controller.setCaption(
                          _caption.text,
                          index: _captionIndex,
                        ),
                );
                Navigator.pop(context);
              },
              child: const Text('調整を保存'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _assetPicker() {
    final clips = widget.controller.state.clips;
    if (clips.isEmpty) return const Text('素材がありません');
    return DropdownButtonFormField<String>(
      initialValue: _assetId,
      decoration: const InputDecoration(
        labelText: '調整する素材',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final clip in clips)
          DropdownMenuItem(value: clip.id, child: Text(clip.label)),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _assetId = value;
          _pendingGain = null;
          final segment =
              widget.controller.comparisonSegments[widget.controller.state.clips
                  .indexWhere((clip) => clip.id == value)];
          _trimStartUs = segment.startUs;
          _trimDurationUs = segment.durationUs;
        });
      },
    );
  }

  Widget _trimControls() {
    final clip = _selectedClip;
    if (clip == null) return const Text('素材を選んでください');
    final maxUs = clip.durationUs;
    final endUs = (_trimStartUs + _trimDurationUs).clamp(1, maxUs);
    return Column(
      children: [
        RangeSlider(
          values: RangeValues(
            _trimStartUs.toDouble().clamp(0, maxUs.toDouble()),
            endUs.toDouble().clamp(1, maxUs.toDouble()),
          ),
          min: 0,
          max: maxUs.toDouble(),
          labels: RangeLabels(
            '${(_trimStartUs / 1e6).toStringAsFixed(1)}秒',
            '${(endUs / 1e6).toStringAsFixed(1)}秒',
          ),
          onChanged: (value) => setState(() {
            _trimStartUs = value.start.round();
            _trimStartUs = _trimStartUs.clamp(0, maxUs - 1);
            _trimDurationUs = (value.end - value.start).round().clamp(
              1,
              6000000,
            );
          }),
          onChangeEnd: (_) {
            final id = _assetId;
            if (id != null) {
              unawaited(
                widget.controller.setTrim(id, _trimStartUs, _trimDurationUs),
              );
            }
          },
        ),
        Text(
          '${(_trimDurationUs / 1e6).toStringAsFixed(1)}秒を使用',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
