import 'package:flutter/material.dart';

/// Replaces a lazy content tree only after it has faded out. Keeping a single
/// tree avoids duplicate scroll positions, requests and text-field controllers.
class BookSourceSliverTransition extends StatefulWidget {
  const BookSourceSliverTransition({
    super.key,
    required this.identity,
    required this.slivers,
    this.onSwap,
  });

  final Object identity;
  final List<Widget> slivers;
  final VoidCallback? onSwap;

  @override
  State<BookSourceSliverTransition> createState() =>
      _BookSourceSliverTransitionState();
}

class _BookSourceSliverTransitionState extends State<BookSourceSliverTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 180),
    reverseDuration: const Duration(milliseconds: 80),
  )..addStatusListener(_onStatus);
  late final Animation<double> _opacity = _controller.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );
  late Object _shownIdentity;
  late List<Widget> _shownSlivers;
  bool _exiting = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _shownIdentity = widget.identity;
    _shownSlivers = widget.slivers;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _showImmediately();
  }

  @override
  void didUpdateWidget(covariant BookSourceSliverTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reduceMotion) {
      _showImmediately();
    } else if (widget.identity == _shownIdentity) {
      _shownSlivers = widget.slivers;
      if (_exiting) {
        // A quick A -> B -> A selection can keep the original tree.
        _exiting = false;
        _controller.forward();
      }
    } else if (!_exiting) {
      _exiting = true;
      if (_controller.isDismissed) {
        _swap();
      } else {
        _controller.reverse();
      }
    }
  }

  void _showImmediately() {
    final changed = _shownIdentity != widget.identity;
    _exiting = false;
    _shownIdentity = widget.identity;
    _shownSlivers = widget.slivers;
    _controller.value = 1;
    if (changed) widget.onSwap?.call();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _exiting) {
      setState(_swap);
    }
  }

  void _swap() {
    _shownIdentity = widget.identity;
    _shownSlivers = widget.slivers;
    _exiting = false;
    widget.onSwap?.call();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller
      ..removeStatusListener(_onStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: _exiting,
    child: SliverIgnorePointer(
      ignoring: _exiting,
      sliver: SliverFadeTransition(
        opacity: _opacity,
        sliver: SliverMainAxisGroup(slivers: _shownSlivers),
      ),
    ),
  );
}
