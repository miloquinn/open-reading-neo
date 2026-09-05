import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/reader/reader_auto_page_turn_controller.dart';

/// Drives the existing vertical list at a constant viewport-relative speed.
/// Only the scroll offset changes on a frame; the reader owns chapter loading.
class ReaderAutoScrollSurface extends StatefulWidget {
  const ReaderAutoScrollSurface({
    super.key,
    required this.controller,
    required this.child,
    required this.onBoundary,
    this.ready = true,
  });

  final ReaderAutoPageTurnController controller;
  final Widget child;
  final Future<bool> Function() onBoundary;
  final bool ready;

  @override
  State<ReaderAutoScrollSurface> createState() =>
      _ReaderAutoScrollSurfaceState();
}

class _ReaderAutoScrollSurfaceState extends State<ReaderAutoScrollSurface>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  ScrollableState? _scrollable;
  Duration? _lastTick;
  bool _coasting = false;
  bool _tickerEnabled = true;
  double _coastSeconds = 0;

  bool get _canCoast =>
      _tickerEnabled &&
      widget.controller.isActive &&
      widget.controller.smoothPauseRequested &&
      !(MediaQuery.maybeOf(context)?.disableAnimations ?? false) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  double _coastTravel(double elapsed) {
    final duration =
        ReaderAutoPageTurnController.smoothPauseDuration.inMicroseconds /
        1000000;
    final from = _coastSeconds;
    final to = math.min(duration, from + elapsed);
    // Integrate the declining speed so low and high refresh rates travel alike.
    double integral(double t) =>
        t - t * t / duration + t * t * t / (3 * duration * duration);
    _coastSeconds = to;
    if (to >= duration) {
      _coasting = false;
      _ticker.stop();
      _lastTick = null;
    }
    return integral(to) - integral(from);
  }

  bool _boundaryPending = false;
  int _generation = 0;

  bool get _running =>
      widget.ready &&
      widget.controller.isRunning &&
      widget.controller.mode == ReaderAutoPageTurnMode.continuous;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (!_tickerEnabled && widget.controller.smoothPauseRequested) {
      _coasting = false;
      _ticker.stop();
      _lastTick = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.controller.smoothPauseRequested) {
          widget.controller.pause();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant ReaderAutoScrollSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
    _scrollable = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  void _sync() {
    if (_running) {
      _coasting = false;
      if (!_ticker.isActive) {
        _lastTick = null;
        _ticker.start();
      }
    } else {
      _generation++;
      if (_canCoast &&
          widget.ready &&
          _ticker.isActive &&
          widget.controller.mode == ReaderAutoPageTurnMode.continuous) {
        if (!_coasting) {
          _coasting = true;
          _coastSeconds = 0;
          _lastTick = null;
        }
        return;
      }
      _coasting = false;
      _ticker.stop();
      _lastTick = null;
    }
  }

  ScrollableState? _findScrollable() {
    if (_scrollable?.mounted == true) return _scrollable;
    _scrollable = null;
    void visit(Element element) {
      if (_scrollable != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final state = element.state as ScrollableState;
        if (axisDirectionToAxis(state.position.axisDirection) ==
            Axis.vertical) {
          _scrollable = state;
          return;
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return _scrollable;
  }

  void _tick(Duration elapsed) {
    final previous = _lastTick;
    _lastTick = elapsed;
    if (_coasting && (!_canCoast || !widget.ready)) {
      _sync();
      return;
    }
    if (previous == null || (!_running && !_coasting) || _boundaryPending) {
      return;
    }
    final state = _findScrollable();
    if (state == null) return;
    final position = state.position;
    if (!position.hasContentDimensions || !position.hasPixels) return;
    // Never race a route-position restore, manual drag or a ballistic fling.
    if (position.isScrollingNotifier.value) {
      if (_coasting) widget.controller.pause();
      return;
    }
    if (position.extentAfter <= 0.5) {
      if (_coasting) {
        widget.controller.pause();
        return;
      }
      _boundaryPending = true;
      unawaited(_atBoundary(_generation));
      return;
    }
    final elapsedSeconds = (elapsed - previous).inMicroseconds / 1000000;
    final seconds = _coasting
        ? _coastTravel(elapsedSeconds)
        : math.min(elapsedSeconds, 0.1);
    final secondsPerScreen = widget.controller.secondsFor(
      ReaderAutoPageTurnMode.continuous,
    );
    final distance = position.viewportDimension * seconds / secondsPerScreen;
    position.jumpTo(
      math.min(position.maxScrollExtent, position.pixels + distance),
    );
    if (!_running && !_coasting && widget.controller.smoothPauseRequested) {
      widget.controller.pause();
    }
  }

  Future<void> _atBoundary(int generation) async {
    try {
      final more = await widget.onBoundary();
      if (mounted && generation == _generation && _running && !more) {
        widget.controller.stop();
      }
    } catch (error, stack) {
      if (mounted && generation == _generation) {
        widget.controller.pause();
        debugPrint('Automatic scrolling could not advance: $error');
        debugPrintStack(stackTrace: stack);
      }
    } finally {
      if (mounted) _boundaryPending = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
