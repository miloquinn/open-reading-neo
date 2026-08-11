import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/services/source_cover_cache.dart';
import 'package:xxread/pages/reader/image/paged_image_reader.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/reader_themes.dart';

bool isOnlineComicSource(RegisteredBookSource source, BookSourceBook book) {
  final sourceType = source.sourceConfig?['bookSourceType'];
  return sourceType == 2 || book.type == 64;
}

/// Book-level session for remote image chapters. Text layout is deliberately
/// absent: images own their typography, while this page owns chapter/page state.
class OnlineComicReaderPage extends StatefulWidget {
  const OnlineComicReaderPage({
    super.key,
    required this.source,
    required this.book,
    this.client,
    this.progressStore = const BookSourceReadingProgressStore(),
    this.shelfService,
    this.initialTheme,
    this.remoteImageCache,
  });

  final RegisteredBookSource source;
  final BookSourceBook book;
  final BookSourceClient? client;
  final BookSourceReadingProgressStore progressStore;
  final BookSourceShelfService? shelfService;
  final ReaderThemePalette? initialTheme;
  final SourceCoverCache? remoteImageCache;

  @override
  State<OnlineComicReaderPage> createState() => _OnlineComicReaderPageState();
}

class _OnlineComicReaderPageState extends State<OnlineComicReaderPage> {
  late final BookSourceClient _client = widget.client ?? BookSourceClient();
  late final bool _ownsClient = widget.client == null;
  late final SourceCoverCache _imageCache =
      widget.remoteImageCache ?? SourceCoverCache.instance;
  late final Future<List<BookSourceChapter>> _chaptersFuture =
      _initializeSession();
  final Map<int, BookSourceChapterContent> _contentCache = {};
  final Map<int, Future<BookSourceChapterContent>> _contentLoads = {};
  int _retrySerial = 0;

  int _chapterIndex = 0;
  int _pageIndex = 0;
  BookSourceReadingProgress? _savedProgress;
  ReaderThemePalette _theme = ReaderThemes.day;

  String get _settingsId => 'comic:${widget.source.id}:${widget.book.id}';

  @override
  void initState() {
    super.initState();
    _theme = widget.initialTheme ?? ReaderThemes.day;
  }

  Future<List<BookSourceChapter>> _initializeSession() async {
    final progress = await widget.progressStore.load(
      sourceId: widget.source.id,
      bookId: widget.book.id,
    );
    _savedProgress = progress;
    final chapters = [
      ...await _client.getChapters(
        widget.source,
        widget.book.id,
        sourceVariables: widget.book.sourceVariables,
      ),
    ]..sort(compareBookSourceChapters);
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException('No chapters found.');
    }
    if (progress != null) {
      _chapterIndex = _savedProgress!.chapterIndex.clamp(
        0,
        chapters.length - 1,
      );
    }
    return List.unmodifiable(chapters);
  }

  Future<BookSourceChapterContent> _loadContent(
    List<BookSourceChapter> chapters,
    int index,
  ) {
    final cached = _contentCache[index];
    if (cached != null) return SynchronousFuture(cached);
    return _contentLoads[index] ??= _client
        .getChapterContent(
          widget.source,
          bookId: widget.book.id,
          chapterId: chapters[index].id,
          sourceVariables: widget.book.sourceVariables,
        )
        .then(
          (content) {
            _contentCache[index] = content;
            _contentLoads.remove(index);
            return content;
          },
          onError: (Object error, StackTrace stack) {
            _contentLoads.remove(index);
            Error.throwWithStackTrace(error, stack);
          },
        );
  }

  void _retryChapter() {
    final index = _chapterIndex;
    _contentCache.remove(index);
    _contentLoads.remove(index);
    setState(() => _retrySerial++);
  }

  Future<Uint8List> _loadPage(BookSourceChapterContent content, int index) =>
      _imageCache.load(
        content.images[index].url,
        headers: content.images[index].headers,
      );

  Future<void> _saveProgress(
    int chapterIndex,
    int pageIndex,
    int pageCount,
  ) async {
    final progress = BookSourceReadingProgress(
      chapterId: (await _chaptersFuture)[chapterIndex].id,
      chapterIndex: chapterIndex,
      chapterProgress: pageCount <= 1
          ? 1
          : (pageIndex / (pageCount - 1)).clamp(0.0, 1.0),
      updatedAt: DateTime.now().toUtc(),
    );
    await widget.progressStore.save(
      sourceId: widget.source.id,
      bookId: widget.book.id,
      progress: progress,
    );
    _savedProgress = progress;
  }

  Future<void> _openChapter(int index, {int page = 0}) async {
    final chapters = await _chaptersFuture;
    if (!mounted || index < 0 || index >= chapters.length) return;
    setState(() {
      _chapterIndex = index;
      _pageIndex = page;
    });
  }

  Future<void> _showCatalog(List<BookSourceChapter> chapters) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          itemCount: chapters.length,
          itemBuilder: (context, index) => ListTile(
            selected: index == _chapterIndex,
            title: Text(chapters[index].title),
            onTap: () => Navigator.of(sheetContext).pop(index),
          ),
        ),
      ),
    );
    if (selected != null) await _openChapter(selected);
  }

  @override
  void dispose() {
    if (_ownsClient) _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<BookSourceChapter>>(
      future: _chaptersFuture,
      builder: (context, catalog) {
        if (catalog.hasError) {
          return PagedReaderMessageScaffold(
            title: widget.book.title,
            message: context.l10n.readerOpenFailed('${catalog.error}'),
            palette: _theme,
          );
        }
        final chapters = catalog.data;
        if (chapters == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final chapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
        return FutureBuilder<BookSourceChapterContent>(
          key: ValueKey('online-comic-chapter-$chapterIndex-$_retrySerial'),
          future: _loadContent(chapters, chapterIndex),
          builder: (context, contentSnapshot) {
            if (contentSnapshot.hasError) {
              return PagedReaderMessageScaffold(
                title: chapters[chapterIndex].title,
                message: context.l10n.readerOpenFailed(
                  '${contentSnapshot.error}',
                ),
                palette: _theme,
                onRetry: _retryChapter,
              );
            }
            final content = contentSnapshot.data;
            if (content == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (content.images.isEmpty) {
              return PagedReaderMessageScaffold(
                title: chapters[chapterIndex].title,
                message: 'This chapter has no image pages.',
                palette: _theme,
              );
            }
            final restoredPage =
                _savedProgress?.chapterId == chapters[chapterIndex].id
                ? ((_savedProgress!.chapterProgress *
                          (content.images.length - 1))
                      .round())
                : 0;
            if (_pageIndex == 0 && restoredPage > 0) {
              _pageIndex = restoredPage;
            }
            return PagedImageReader(
              title: '${widget.book.title} · ${chapters[chapterIndex].title}',
              pageCount: content.images.length,
              initialPage: _pageIndex,
              settingsId: _settingsId,
              loadPage: (index) => _loadPage(content, index),
              onPageChanged: (index) {
                _pageIndex = index;
                unawaited(
                  _saveProgress(chapterIndex, index, content.images.length),
                );
              },
              onReachedEnd: chapterIndex < chapters.length - 1
                  ? () => unawaited(_openChapter(chapterIndex + 1))
                  : null,
              onReachedStart: chapterIndex > 0
                  ? () => unawaited(_openChapter(chapterIndex - 1, page: 0))
                  : null,
              onTableOfContents: () => unawaited(_showCatalog(chapters)),
            );
          },
        );
      },
    );
  }
}
