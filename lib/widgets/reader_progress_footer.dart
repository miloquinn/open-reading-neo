import 'package:flutter/material.dart';

import '../core/reader/reader_settings.dart';
import '../utils/localization_extension.dart';

String formatReaderChapterProgress(
  BuildContext context, {
  required ReaderChapterProgressStyle style,
  required int chapterIndex,
  required int chapterCount,
}) {
  if (chapterCount <= 0 || chapterIndex < 0 || chapterIndex >= chapterCount) {
    return '';
  }
  return switch (style) {
    ReaderChapterProgressStyle.hidden => '',
    ReaderChapterProgressStyle.fraction =>
      context.l10n.readerChapterProgressFraction(
        chapterIndex + 1,
        chapterCount,
      ),
    ReaderChapterProgressStyle.remaining =>
      context.l10n.readerChapterProgressRemaining(
        chapterCount - chapterIndex - 1,
      ),
  };
}

/// Shares one footer row between paper leaves and the scrolling viewport.
class ReaderProgressFooter extends StatelessWidget {
  const ReaderProgressFooter({
    super.key,
    required this.chapterLabel,
    required this.pageLabel,
    this.pageKey,
    this.style,
    this.pageOnLeft = false,
  });

  final String chapterLabel;
  final String pageLabel;
  final Key? pageKey;
  final TextStyle? style;
  final bool pageOnLeft;

  @override
  Widget build(BuildContext context) {
    final page = Text(pageLabel, key: pageKey, style: style, maxLines: 1);
    final chapter = Expanded(
      child: Text(
        chapterLabel,
        style: style,
        textAlign: pageOnLeft ? TextAlign.right : TextAlign.left,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return Row(
      textDirection: TextDirection.ltr,
      children: pageOnLeft
          ? [page, const SizedBox(width: 12), chapter]
          : [chapter, const SizedBox(width: 12), page],
    );
  }
}
