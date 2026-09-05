import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/reader/reader_auto_page_turn_controller.dart';
import 'reader_shader_page_curl.dart';

/// Reveals a prepared next page without moving either page's text.
/// The host commits the prepared target only after the complete sweep.
class ReaderSweepPageTurn extends StatefulWidget {
  const ReaderSweepPageTurn({
    super.key,
    required this.controller,
    required this.currentPage,
    required this.nextPage,
    required this.hasNext,
    required this.onTurnForward,
    this.twoPage = false,
    this.contentInsets = EdgeInsets.zero,
    this.spreadGutter = 24,
    this.onNeedNextPage,
  });

  final ReaderAutoPageTurnController controller;
  final ReaderPageSnapshot currentPage;
  final ReaderPageSnapshot? nextPage;
  final bool hasNext;
  final Future<void> Function() onTurnForward;
  final bool twoPage;
  final EdgeInsets contentInsets;
  final double spreadGutter;
  final VoidCallback? onNeedNextPage;

  @override
  State<ReaderSweepPageTurn> createState() => _ReaderSweepPageTurnState();
}

class _ReaderSweepPageTurnState extends State<ReaderSweepPageTurn>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _progress = ValueNotifier(0);
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

  double _waitSeconds = 2;
  bool _committing = false;
  bool _requestedNext = false;
  int _epoch = 0;

  bool get _running =>
      widget.controller.isRunning &&
      widget.controller.mode == ReaderAutoPageTurnMode.sweep;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncMotion);
    _scheduleSync();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMotion();
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
  void didUpdateWidget(covariant ReaderSweepPageTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncMotion);
      widget.controller.addListener(_syncMotion);
    }
    final pageChanged =
        oldWidget.currentPage.key.pageIdentity !=
        widget.currentPage.key.pageIdentity;
    final layoutChanged =
        oldWidget.contentInsets != widget.contentInsets ||
        oldWidget.twoPage != widget.twoPage ||
        oldWidget.spreadGutter != widget.spreadGutter ||
        (!pageChanged && oldWidget.currentPage.key != widget.currentPage.key);
    final targetChanged =
        _progress.value > 0 &&
        !pageChanged &&
        oldWidget.nextPage?.key != widget.nextPage?.key;
    if (pageChanged || layoutChanged || targetChanged) {
      _epoch++;
      _coasting = false;
      _progress.value = 0;
      _waitSeconds = pageChanged ? 1 : 2;
      _committing = false;
      _requestedNext = false;
      _lastTick = null;
    }
    if (layoutChanged || targetChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.controller.stop();
      });
    } else {
      _scheduleSync();
    }
  }

  void _syncMotion() {
    if (!widget.controller.isActive) {
      _epoch++;
      _coasting = false;
      _progress.value = 0;
      _waitSeconds = 2;
      _committing = false;
    }
    if (!_running) _requestedNext = false;
    if (!_running &&
        _canCoast &&
        _ticker.isActive &&
        !_committing &&
        widget.hasNext &&
        widget.nextPage != null &&
        _waitSeconds <= 0) {
      if (!_coasting) {
        _coasting = true;
        _coastSeconds = 0;
        _lastTick = null;
      }
      return;
    }
    _coasting = false;
    if (!_running || _committing || !widget.hasNext) {
      _ticker.stop();
      _lastTick = null;
      if (_running && !widget.hasNext) widget.controller.stop();
      return;
    }
    if (widget.nextPage == null) {
      _ticker.stop();
      _lastTick = null;
      if (!_requestedNext) {
        _requestedNext = true;
        widget.onNeedNextPage?.call();
      }
      return;
    }
    _requestedNext = false;
    if (!_ticker.isActive) {
      _lastTick = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final previous = _lastTick;
    _lastTick = elapsed;
    if (_coasting && !_canCoast) {
      _syncMotion();
      return;
    }
    if (previous == null ||
        (!_running && !_coasting) ||
        widget.nextPage == null) {
      return;
    }
    var seconds = (elapsed - previous).inMicroseconds / 1000000;
    final settling = _coasting;
    if (settling) seconds = _coastTravel(seconds);
    if (_waitSeconds > 0) {
      final waiting = math.min(seconds, _waitSeconds);
      _waitSeconds -= waiting;
      seconds -= waiting;
    }
    if (seconds <= 0) return;
    final duration =
        widget.controller.secondsFor(ReaderAutoPageTurnMode.sweep) *
        (widget.twoPage ? 2 : 1);
    _progress.value = (_progress.value + seconds / duration).clamp(
      0,
      settling ? 0.999999 : 1,
    );
    if (settling && !_coasting && widget.controller.smoothPauseRequested) {
      widget.controller.pause();
    }
    if (_running && _progress.value >= 1 && !_committing) {
      _committing = true;
      _ticker.stop();
      unawaited(_commit(_epoch));
    }
  }

  Future<void> _commit(int epoch) async {
    try {
      await widget.onTurnForward();
    } catch (error, stack) {
      if (mounted && epoch == _epoch) {
        _committing = false;
        _progress.value = 0;
        _waitSeconds = 2;
        widget.controller.pause();
        debugPrint('Automatic sweep could not advance: $error');
        debugPrintStack(stackTrace: stack);
      }
    }
    // The new snapshot identity starts the next cycle in didUpdateWidget.
    // Leaving this cycle latched prevents duplicate commits during async loads.
  }

  @override
  void dispose() {
    _epoch++;
    widget.controller.removeListener(_syncMotion);
    _ticker.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = widget.nextPage;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: widget.controller.stop,
      child: IgnorePointer(
        child: Stack(
          key: const ValueKey('reader-sweep-surface'),
          fit: StackFit.expand,
          children: [
            RepaintBoundary(child: widget.currentPage.child),
            if (next != null) ...[
              IgnorePointer(
                child: ExcludeSemantics(
                  child: ClipPath(
                    key: const ValueKey('reader-sweep-next-page'),
                    clipper: _SweepClipper(
                      progress: _progress,
                      insets: widget.contentInsets,
                      twoPage: widget.twoPage,
                      gutter: widget.spreadGutter,
                    ),
                    child: RepaintBoundary(child: next.child),
                  ),
                ),
              ),
              IgnorePointer(
                child: CustomPaint(
                  painter: _SweepLinePainter(
                    progress: _progress,
                    insets: widget.contentInsets,
                    twoPage: widget.twoPage,
                    gutter: widget.spreadGutter,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

List<Rect> _sweepRegions(
  Size size,
  EdgeInsets insets,
  bool twoPage,
  double gutter,
) {
  final top = insets.top.clamp(0.0, size.height);
  final bottom = (size.height - insets.bottom).clamp(top, size.height);
  if (!twoPage) {
    return [Rect.fromLTRB(insets.left, top, size.width - insets.right, bottom)];
  }
  final middle = size.width / 2;
  return [
    Rect.fromLTRB(insets.left, top, middle - gutter / 2, bottom),
    Rect.fromLTRB(middle + gutter / 2, top, size.width - insets.right, bottom),
  ];
}

class _SweepClipper extends CustomClipper<Path> {
  _SweepClipper({
    required this.progress,
    required this.insets,
    required this.twoPage,
    required this.gutter,
  }) : super(reclip: progress);

  final ValueListenable<double> progress;
  final EdgeInsets insets;
  final bool twoPage;
  final double gutter;

  @override
  Path getClip(Size size) {
    final regions = _sweepRegions(size, insets, twoPage, gutter);
    final path = Path();
    for (var index = 0; index < regions.length; index++) {
      final rect = regions[index];
      final fraction = (progress.value * regions.length - index).clamp(
        0.0,
        1.0,
      );
      if (fraction > 0) {
        path.addRect(
          Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width,
            rect.height * fraction,
          ),
        );
      }
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _SweepClipper oldClipper) =>
      insets != oldClipper.insets ||
      twoPage != oldClipper.twoPage ||
      gutter != oldClipper.gutter ||
      progress != oldClipper.progress;
}

class _SweepLinePainter extends CustomPainter {
  _SweepLinePainter({
    required this.progress,
    required this.insets,
    required this.twoPage,
    required this.gutter,
    required this.color,
  }) : super(repaint: progress);

  final ValueListenable<double> progress;
  final EdgeInsets insets;
  final bool twoPage;
  final double gutter;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress.value <= 0 || progress.value >= 1) return;
    final regions = _sweepRegions(size, insets, twoPage, gutter);
    final segment = progress.value * regions.length;
    final index = math.min(segment.floor(), regions.length - 1);
    final rect = regions[index];
    final y = rect.top + rect.height * (segment - index);
    canvas.drawLine(
      Offset(rect.left, y + 1),
      Offset(rect.right, y + 1),
      Paint()
        ..color = color.withValues(alpha: 0.08)
        ..strokeWidth = 3,
    );
    canvas.drawLine(
      Offset(rect.left, y),
      Offset(rect.right, y),
      Paint()
        ..color = color.withValues(alpha: 0.30)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _SweepLinePainter oldDelegate) =>
      insets != oldDelegate.insets ||
      twoPage != oldDelegate.twoPage ||
      gutter != oldDelegate.gutter ||
      color != oldDelegate.color ||
      progress != oldDelegate.progress;
}
