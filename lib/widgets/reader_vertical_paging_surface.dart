import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:xxread/core/reader/reader_safe_area.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/core/reader/reader_vertical_paging.dart';

ReaderViewportChromeMetrics readerViewportChromeForTopBar({
  required ReaderSafeAreaMetrics safeArea,
  required ReaderTopBarStyle topBarStyle,
}) => ReaderViewportChromeMetrics(
  safeArea: safeArea,
  immersive: topBarStyle == ReaderTopBarStyle.hidden,
  reservesTitle: topBarStyle == ReaderTopBarStyle.reader,
);

ReaderVisibleItemPosition readerVisibleItemPositionFromItemPosition(
  ItemPosition position,
) => ReaderVisibleItemPosition(
  index: position.index,
  leadingEdge: position.itemLeadingEdge,
  trailingEdge: position.itemTrailingEdge,
);

/// Shared safe-area window for local and online vertical readers.
class ReaderVerticalReadingWindow extends StatelessWidget {
  const ReaderVerticalReadingWindow({
    super.key,
    required this.metrics,
    required this.child,
    this.windowKey,
  });

  final ReaderViewportChromeMetrics metrics;
  final Widget child;
  final Key? windowKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: windowKey,
      padding: EdgeInsets.only(
        top: metrics.contentTop,
        bottom: metrics.contentBottom,
      ),
      child: ClipRect(child: child),
    );
  }
}

/// Shared interaction shell for local and online vertical paging.
///
/// The tap recognizer deliberately lives inside [SelectionArea]. If it wraps
/// the selectable scroll view from outside, selection recognizers can consume
/// the light tap before the reader gets a chance to reveal its controls.
class ReaderVerticalPagingSurface extends StatelessWidget {
  const ReaderVerticalPagingSurface({
    super.key,
    required this.child,
    this.onTap,
    this.surfaceKey,
    this.onHorizontalDragEnd,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Key? surfaceKey;
  final GestureDragEndCallback? onHorizontalDragEnd;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: GestureDetector(
        key: surfaceKey,
        behavior: HitTestBehavior.translucent,
        onTap: onTap,
        onHorizontalDragEnd: onHorizontalDragEnd,
        child: child,
      ),
    );
  }
}
