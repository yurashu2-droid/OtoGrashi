import 'package:flutter/material.dart';

import '../../design/tokens.dart';
import '../../domain/melody_template.dart';

/// Shows the actual eight-step note pattern used by a song template.
class MelodyTemplateCard extends StatelessWidget {
  const MelodyTemplateCard({
    required this.melody,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final MelodyTemplate melody;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (melody) {
    MelodyTemplate.none => Icons.auto_awesome_rounded,
    MelodyTemplate.hop => Icons.trending_up_rounded,
    MelodyTemplate.wink => Icons.music_note_rounded,
    MelodyTemplate.answer => Icons.question_answer_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTokens.coral : AppTokens.lavender;
    return Semantics(
      button: true,
      selected: selected,
      label: '${melody.label}、${melody.description}',
      child: Material(
        color: selected ? const Color(0xFFFFF7F2) : const Color(0xFFFFFEFB),
        elevation: selected ? 3 : 1,
        shadowColor: const Color(0x228D6B5B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? AppTokens.coral : const Color(0xFFE7DCD2),
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Transform.rotate(
                      angle: -0.08,
                      child: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Icon(_icon, size: 19, color: color),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        melody.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (selected)
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 18,
                        color: AppTokens.coral,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: selected ? 48 : 28,
                  height: 3,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: selected ? 0.85 : 0.5),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  melody.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                SizedBox(
                  height: 26,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var step = 0; step < 8; step++) ...[
                        if (step > 0) const SizedBox(width: 3),
                        Expanded(
                          child: _StepBar(
                            note: melody == MelodyTemplate.none
                                ? null
                                : melody.notes[step],
                            color: color,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepBar extends StatelessWidget {
  const _StepBar({required this.note, required this.color});
  final MelodyNote? note;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final pitch = note?.pitchSemitones;
    final height = pitch == null
        ? 4.0
        : (14 + pitch * 2).clamp(7, 24).toDouble();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: pitch == null ? color.withValues(alpha: 0.22) : color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}
