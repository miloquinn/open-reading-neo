import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/comic_book_parser.dart';
import 'package:xxread/services/books/web_book_file_store.dart';
import 'package:xxread/services/reading/reading_resume_service.dart';
import 'package:xxread/utils/reader_themes.dart';

/// Local CBZ/CBT/CBR/CB7 archive as one image-book session.
class LocalComicSource extends ImageReaderSource {
  LocalComicSource({required this.book, required this.theme});

  static const int _pageCacheLimit = 8;

  final Book book;
  @override
  final ReaderThemePalette theme;

  final LinkedHashMap<int, Uint8List> _pageCache = LinkedHashMap();
  final Map<int, Future<Uint8List>> _pendingPages = {};
  List<String> _pages = const [];
  Uint8List? _webBytes;

  @override
  String get bookTitle => book.title;

  @override
  int? get localBookId => book.id;

  @override
  void attach() {
    unawaited(ReadingResumeService.markReading(book.id));
  }

  @override
  void dispose() {
    unawaited(ReadingResumeService.markClosed(book.id));
    super.dispose();
  }

  @override
  Future<ImageReaderDocument> loadDocument() async {
    _pages = await _indexPages();
    return ImageReaderDocument(
      chapters: [ImageReaderChapter(id: book.filePath, title: book.title)],
      initialPageIndex: book.currentPage,
    );
  }

  @override
  Future<int> loadChapterPageCount(int chapterIndex) async => _pages.length;

  @override
  Future<Uint8List> loadPage(
    int chapterIndex,
    int pageIndex, {
    bool preload = false,
  }) {
    final cached = _pageCache.remove(pageIndex);
    if (cached != null) {
      _pageCache[pageIndex] = cached;
      return SynchronousFuture<Uint8List>(cached);
    }
    final pending = _pendingPages[pageIndex];
    if (pending != null) return pending;
    final future = compute(extractComicPage, <String, dynamic>{
      if (kIsWeb) 'bytes': _webBytes else 'path': book.filePath,
      'ext': book.format,
      'name': _pages[pageIndex],
    });
    _pendingPages[pageIndex] = future;
    future
        .then((bytes) {
          _pageCache[pageIndex] = bytes;
          while (_pageCache.length > _pageCacheLimit) {
            _pageCache.remove(_pageCache.keys.first);
          }
        })
        .whenComplete(() => _pendingPages.remove(pageIndex));
    return future;
  }

  @override
  Future<void> invalidatePage(int chapterIndex, int pageIndex) async {
    _pageCache.remove(pageIndex);
    _pendingPages.remove(pageIndex);
  }

  @override
  Future<void> saveProgress({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  }) async {
    final bookId = book.id;
    if (bookId == null) return;
    try {
      await BookDao().updateBookProgress(
        bookId,
        pageIndex,
        readingProgress: (pageIndex + 1) / pageCount,
      );
    } catch (error) {
      debugPrint('保存漫画进度失败: $error');
    }
  }

  @override
  String emptyPagesMessage(AppLocalizations l10n) => l10n.readerComicNoPages;

  @override
  String describeError(Object error, AppLocalizations l10n) {
    if (error is ComicArchiveUnsupportedException) {
      return error.container == ComicContainerFormat.rar
          ? l10n.readerComicCbrUnsupported
          : l10n.readerComicArchiveUnsupported;
    }
    return l10n.readerOpenFailed(error.toString());
  }

  Future<List<String>> _indexPages() async {
    Map<String, dynamic> args;
    if (kIsWeb) {
      _webBytes = await WebBookFileStore().read(book.filePath);
      if (_webBytes == null) {
        throw StateError('Web 书籍文件不存在');
      }
      args = <String, dynamic>{'bytes': _webBytes, 'ext': book.format};
    } else {
      args = <String, dynamic>{'path': book.filePath, 'ext': book.format};
    }
    return compute(indexComicPages, args);
  }
}
