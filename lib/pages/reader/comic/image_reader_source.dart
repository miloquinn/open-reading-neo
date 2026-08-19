import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/utils/reader_themes.dart';

class ImageReaderChapter {
  const ImageReaderChapter({required this.id, required this.title});

  final String id;
  final String title;
}

class ImageReaderDocument {
  const ImageReaderDocument({
    required this.chapters,
    this.initialChapterIndex = 0,
    this.initialPageIndex = 0,
  });

  final List<ImageReaderChapter> chapters;
  final int initialChapterIndex;
  final int initialPageIndex;
}

/// One image-book session. Local archives and online sources adapt to this
/// port; [ImageReaderHost] owns chapter/page state and chrome.
abstract class ImageReaderSource {
  String get bookTitle;
  ReaderThemePalette get theme;

  /// Local shelf books persist direction by numeric id.
  int? get localBookId => null;

  /// Online books persist direction by a stable string key.
  String? get settingsId => null;

  Future<ImageReaderDocument> loadDocument();

  Future<int> loadChapterPageCount(int chapterIndex);

  Future<Uint8List> loadPage(int chapterIndex, int pageIndex);

  Future<void> saveProgress({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  });

  /// Drop a cached chapter so the next load retries the network or archive.
  void invalidateChapter(int chapterIndex) {}

  String pageTitle(ImageReaderDocument document, int chapterIndex) {
    final chapter = document.chapters[chapterIndex];
    if (document.chapters.length == 1) return bookTitle;
    return '$bookTitle · ${chapter.title}';
  }

  String emptyPagesMessage(AppLocalizations l10n);

  String describeError(Object error, AppLocalizations l10n);

  void attach() {}

  @mustCallSuper
  void dispose() {}
}
