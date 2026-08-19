import 'package:flutter/foundation.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/book_sources/caching/source_cover_cache.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/utils/reader_themes.dart';

/// Remote image-source book as one image-book session.
class OnlineComicSource extends ImageReaderSource {
  OnlineComicSource({
    required this.source,
    required this.book,
    BookSourceClient? client,
    this.progressStore = const BookSourceReadingProgressStore(),
    SourceCoverCache? imageCache,
    ReaderThemePalette? theme,
  }) : _client = client ?? BookSourceClient(),
       _ownsClient = client == null,
       _imageCache = imageCache ?? SourceCoverCache.instance,
       theme = theme ?? ReaderThemes.day;

  final RegisteredBookSource source;
  final BookSourceBook book;
  final BookSourceReadingProgressStore progressStore;
  final BookSourceClient _client;
  final bool _ownsClient;
  final SourceCoverCache _imageCache;

  @override
  final ReaderThemePalette theme;

  List<BookSourceChapter> _chapters = const [];
  BookSourceReadingProgress? _savedProgress;
  final Map<int, BookSourceChapterContent> _contentCache = {};
  final Map<int, Future<BookSourceChapterContent>> _contentLoads = {};

  @override
  String get bookTitle => book.title;

  @override
  String get settingsId => 'comic:${source.id}:${book.id}';

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  @override
  Future<ImageReaderDocument> loadDocument() async {
    comicDebugLog(
      'document',
      'start source=${source.name} sourceId=${source.id} book=${book.title} '
          'bookId=${comicDebugTarget(book.id)} bookType=${book.type} '
          'sourceType=${source.sourceConfig?['bookSourceType']} '
          'variables=${book.sourceVariables.keys.toList()..sort()}',
    );
    _savedProgress = await progressStore.load(
      sourceId: source.id,
      bookId: book.id,
    );
    comicDebugLog(
      'progress',
      _savedProgress == null
          ? 'no saved progress'
          : 'saved chapterIndex=${_savedProgress!.chapterIndex} '
                'chapterId=${comicDebugTarget(_savedProgress!.chapterId)} '
                'chapterProgress=${_savedProgress!.chapterProgress}',
    );
    final stopwatch = Stopwatch()..start();
    late final List<BookSourceChapter> chapters;
    try {
      chapters = [
        ...await _client.getChapters(
          source,
          book.id,
          sourceVariables: book.sourceVariables,
        ),
      ]..sort(compareBookSourceChapters);
    } catch (error, stackTrace) {
      comicDebugLog(
        'catalog',
        'failed source=${source.name} elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
    comicDebugLog(
      'catalog',
      'success chapters=${chapters.length} elapsedMs=${stopwatch.elapsedMilliseconds} '
          'first=${chapters.isEmpty ? 'none' : chapters.first.title}',
    );
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException('No chapters found.');
    }
    _chapters = List.unmodifiable(chapters);
    var chapterIndex = 0;
    var pageIndex = 0;
    final progress = _savedProgress;
    if (progress != null) {
      chapterIndex = progress.chapterIndex.clamp(0, _chapters.length - 1);
      if (progress.chapterId == _chapters[chapterIndex].id) {
        final count = await loadChapterPageCount(chapterIndex);
        pageIndex = count <= 1
            ? 0
            : (progress.chapterProgress * (count - 1)).round();
      }
    }
    return ImageReaderDocument(
      chapters: [
        for (final chapter in _chapters)
          ImageReaderChapter(id: chapter.id, title: chapter.title),
      ],
      initialChapterIndex: chapterIndex,
      initialPageIndex: pageIndex,
    );
  }

  @override
  Future<int> loadChapterPageCount(int chapterIndex) async {
    final content = await _loadContent(chapterIndex);
    comicDebugLog(
      'content',
      'chapterIndex=$chapterIndex title=${_chapters[chapterIndex].title} '
          'htmlChars=${content.content.length} images=${content.images.length}',
    );
    for (final entry in content.images.take(3).indexed) {
      comicDebugLog(
        'image-list',
        'chapterIndex=$chapterIndex sample=${entry.$1 + 1}/${content.images.length} '
            'url=${comicDebugUri(entry.$2.url)} '
            'headerNames=${comicDebugHeaderNames(entry.$2.headers)}',
      );
    }
    return content.images.length;
  }

  @override
  Future<Uint8List> loadPage(int chapterIndex, int pageIndex) async {
    final content = await _loadContent(chapterIndex);
    final image = content.images[pageIndex];
    final headers = <String, String>{...image.headers};
    if (!headers.keys.any((name) => name.toLowerCase() == 'referer')) {
      headers['Referer'] = source.apiBaseUrl.toString();
    }
    final stopwatch = Stopwatch()..start();
    comicDebugLog(
      'image-fetch',
      'start chapterIndex=$chapterIndex page=${pageIndex + 1}/${content.images.length} '
          'url=${comicDebugUri(image.url)} '
          'headerNames=${comicDebugHeaderNames(headers)}',
    );
    try {
      final bytes = await _imageCache.load(
        image.url,
        headers: headers,
        preferPlatform:
            !kIsWeb && defaultTargetPlatform == TargetPlatform.android,
      );
      comicDebugLog(
        'image-fetch',
        'success chapterIndex=$chapterIndex page=${pageIndex + 1}/${content.images.length} '
            'bytes=${bytes.length} elapsedMs=${stopwatch.elapsedMilliseconds} '
            'signature=${_byteSignature(bytes)}',
      );
      return bytes;
    } catch (error, stackTrace) {
      comicDebugLog(
        'image-fetch',
        'failed chapterIndex=$chapterIndex page=${pageIndex + 1}/${content.images.length} '
            'elapsedMs=${stopwatch.elapsedMilliseconds} url=${comicDebugUri(image.url)}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> saveProgress({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  }) async {
    final progress = BookSourceReadingProgress(
      chapterId: _chapters[chapterIndex].id,
      chapterIndex: chapterIndex,
      chapterProgress: pageCount <= 1
          ? 1
          : (pageIndex / (pageCount - 1)).clamp(0.0, 1.0),
      updatedAt: DateTime.now().toUtc(),
    );
    await progressStore.save(
      sourceId: source.id,
      bookId: book.id,
      progress: progress,
    );
    _savedProgress = progress;
  }

  @override
  void invalidateChapter(int chapterIndex) {
    _contentCache.remove(chapterIndex);
    _contentLoads.remove(chapterIndex);
  }

  @override
  String emptyPagesMessage(AppLocalizations l10n) =>
      l10n.readerComicChapterNoPages;

  @override
  String describeError(Object error, AppLocalizations l10n) =>
      l10n.readerOpenFailed('$error');

  Future<BookSourceChapterContent> _loadContent(int index) {
    final cached = _contentCache[index];
    if (cached != null) {
      comicDebugLog(
        'content',
        'cache-hit chapterIndex=$index images=${cached.images.length}',
      );
      return SynchronousFuture(cached);
    }
    final pending = _contentLoads[index];
    if (pending != null) {
      comicDebugLog('content', 'join-inflight chapterIndex=$index');
      return pending;
    }
    final stopwatch = Stopwatch()..start();
    comicDebugLog(
      'content',
      'start chapterIndex=$index chapter=${_chapters[index].title} '
          'chapterId=${comicDebugTarget(_chapters[index].id)}',
    );
    return _contentLoads[index] = _client
        .getChapterContent(
          source,
          bookId: book.id,
          chapterId: _chapters[index].id,
          sourceVariables: book.sourceVariables,
        )
        .then(
          (content) {
            _contentCache[index] = content;
            _contentLoads.remove(index);
            comicDebugLog(
              'content',
              'success chapterIndex=$index htmlChars=${content.content.length} '
                  'images=${content.images.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
            );
            return content;
          },
          onError: (Object error, StackTrace stack) {
            _contentLoads.remove(index);
            comicDebugLog(
              'content',
              'failed chapterIndex=$index elapsedMs=${stopwatch.elapsedMilliseconds}',
              error: error,
              stackTrace: stack,
            );
            Error.throwWithStackTrace(error, stack);
          },
        );
  }
}

String _byteSignature(Uint8List bytes) {
  if (bytes.isEmpty) return 'empty';
  final length = bytes.length < 12 ? bytes.length : 12;
  return bytes
      .take(length)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
}
