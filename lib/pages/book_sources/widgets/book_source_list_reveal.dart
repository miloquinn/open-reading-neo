import 'package:flutter/material.dart';

/// A short, one-shot entrance used by lazily built discovery list rows.
///
/// The internal animation controller is removed as soon as the transition
/// finishes, so long source libraries do not retain a ticker per row.
class BookSourceListReveal extends StatefulWidget {
  const BookSourceListReveal({
    super.key,
    required this.animate,
    required this.child,
    this.order = 0,
  });

  final bool animate;
  final Widget child;
  final int order;

  @override
  State<BookSourceListReveal> createState() => _BookSourceListRevealState();
}

class _BookSourceListRevealState extends State<BookSourceListReveal> {
  late final bool _animate = widget.animate;
  bool _finished = false;

  @override
  Widget build(BuildContext context) {
    if (!_animate || _finished || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }

    final delay = Duration(milliseconds: widget.order.clamp(0, 4) * 24);
    final duration = const Duration(milliseconds: 220) + delay;
    final delayFraction = delay.inMicroseconds / duration.inMicroseconds;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Interval(delayFraction, 1, curve: Curves.easeOutCubic),
      onEnd: () {
        if (mounted) setState(() => _finished = true);
      },
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - value)),
          child: Transform.scale(
            scale: 0.985 + (0.015 * value),
            alignment: Alignment.bottomCenter,
            child: child,
          ),
        ),
      ),
      child: widget.child,
    );
  }
}
