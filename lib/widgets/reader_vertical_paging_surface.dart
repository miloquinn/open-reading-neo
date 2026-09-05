import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:xxread/core/reader/reader_safe_area.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/core/reader/reader_vertical_paging.dart';
import 'reader_chapter_title_page.dart';

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

/// Finds the text paragraph rendered below a keyed vertical page cell.
RenderParagraph? readerParagraphForKey(GlobalKey key) {
  final root = key.currentContext;
  if (root == null) return null;
  RenderParagraph? result;
  void visit(Element element) {
    if (result != null || element.widget is ReaderInlineChapterTitle) return;
    final renderObject = element.renderObject;
    if (renderObject is RenderParagraph) {
      result = renderObject;
      return;
    }
    element.visitChildElements(visit);
  }

  root.visitChildElements(visit);
  return result;
}

/// Resolves the canonical source offset painted at the viewport center.
int readerSourceOffsetAtViewportCenter({
  required RenderParagraph? paragraph,
  required String text,
  required int fallbackOffset,
  required int Function(int textOffset) sourceOffsetForTextOffset,
  required double viewportCenterY,
}) {
  if (paragraph == null || !paragraph.hasSize || text.isEmpty) {
    return fallbackOffset;
  }
  final localCenter = Offset(
    paragraph.size.width / 2,
    viewportCenterY - paragraph.localToGlobal(Offset.zero).dy,
  );
  return sourceOffsetForTextOffset(
    paragraph.getPositionForOffset(localCenter).offset,
  );
}

/// Resolves the vertical caret position for a canonical source offset.
double? readerCaretDyForSourceOffset({
  required RenderParagraph? paragraph,
  required String text,
  required int sourceOffset,
  required int Function(int sourceOffset) textOffsetForSourceOffset,
}) {
  if (paragraph == null || !paragraph.hasSize || text.isEmpty) return null;
  return paragraph
      .getOffsetForCaret(
        TextPosition(offset: textOffsetForSourceOffset(sourceOffset)),
        Rect.zero,
      )
      .dy;
}

/// Refines an estimated page index using the page cell nearest screen center.
int readerPartIndexAtViewportCenter({
  required int estimatedIndex,
  required int itemCount,
  required RenderBox? Function(int index) renderBoxAt,
  required double viewportCenterY,
}) {
  if (itemCount <= 1) return 0;
  var result = estimatedIndex.clamp(0, itemCount - 1);
  var closestDistance = double.infinity;
  for (var index = 0; index < itemCount; index++) {
    final renderBox = renderBoxAt(index);
    if (renderBox == null || !renderBox.hasSize) continue;
    final top = renderBox.localToGlobal(Offset.zero).dy;
    final bottom = top + renderBox.size.height;
    if (top <= viewportCenterY && bottom > viewportCenterY) return index;
    final distance = math.min(
      (top - viewportCenterY).abs(),
      (bottom - viewportCenterY).abs(),
    );
    if (distance < closestDistance) {
      closestDistance = distance;
      result = index;
    }
  }
  return result;
}

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
