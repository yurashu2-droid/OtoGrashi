import 'package:flutter/material.dart';

class Pressable extends StatefulWidget {
  const Pressable({
    required this.onPressed,
    required this.child,
    this.enabled = true,
    this.semanticLabel,
    super.key,
  });

  final VoidCallback? onPressed;
  final bool enabled;
  final Widget child;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  bool get _enabled => widget.enabled && widget.onPressed != null;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel,
      onTap: _enabled ? widget.onPressed : null,
      excludeSemantics: widget.semanticLabel != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTap: _enabled ? widget.onPressed : null,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1,
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 90),
          curve: Curves.easeOutCubic,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: Opacity(opacity: _enabled ? 1 : 0.45, child: widget.child),
          ),
        ),
      ),
    );
  }
}
