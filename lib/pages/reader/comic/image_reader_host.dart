import 'dart:async';

import 'package:flutter/material.dart';

import 'package:xxread/core/reader/paged_image_reader_settings.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/pages/reader/comic/continuous_image_reader.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/pages/reader/image/paged_image_reader.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';

/// Shared comic/image-book host. Entries stay separate; this is the one
/// reading line for chapter/page state, catalog, retry, and page chrome.
class ImageReaderHost extends StatefulWidget {
  const ImageReaderHost({super.key, required this.source});

  final ImageReaderSource source;

  @override
  State<ImageReaderHost> createState() => _ImageReaderHostState();
}

class _ImageReaderHostState extends State<ImageReaderHost> {
  late Future<ImageReaderDocument> _documentFuture = widget.source
      .loadDocument();
  int _chapterIndex = 0;
  int _pageIndex = 0;
  int _retrySerial = 0;
  bool _appliedInitialLocation = false;
  bool _contentReadyMarked = false;
  int? _pageCountChapterIndex;
  int? _pageCountRetrySerial;
  Future<int>? _pageCountFuture;
  ImageReaderDirection? _resolvedDirection;

  @override
  void initState() {
    super.initState();
    widget.source.attach();
    unawaited(_resolveDirection());
    comicDebugLog(
      'host',
      'attach source=${widget.source.runtimeType} title=${widget.source.bookTitle} '
          'settingsId=${widget.source.settingsId}',
    );
  }

  @override
  void didUpdateWidget(covariant ImageReaderHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source)) return;
    oldWidget.source.dispose();
    widget.source.attach();
    unawaited(_resolveDirection());
    setState(() {
      _documentFuture = widget.source.loadDocument();
      _chapterIndex = 0;
      _pageIndex = 0;
      _retrySerial = 0;
      _appliedInitialLocation = false;
      _contentReadyMarked = false;
      _pageCountChapterIndex = null;
      _pageCountRetrySerial = null;
      _pageCountFuture = null;
      _resolvedDirection = null;
    });
  }

  @override
  void dispose() {
    widget.source.dispose();
    super.dispose();
  }

  void _markContentReady() {
    if (_contentReadyMarked) return;
    _contentReadyMarked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) BookOpenTransition.markReaderContentReady(context);
    });
  }

  Future<void> _openChapter(int index, {required int page}) async {
    final document = await _documentFuture;
    if (!mounted || index < 0 || index >= document.chapters.length) return;
    comicDebugLog(
      'chapter',
      'open from=$_chapterIndex to=$index requestedPage=$page '
          'title=${document.chapters[index].title}',
    );
    setState(() {
      _chapterIndex = index;
      _pageIndex = page;
      _retrySerial++;
    });
  }

  void _retryDocument() {
    comicDebugLog('retry', 'document title=${widget.source.bookTitle}');
    setState(() {
      _documentFuture = widget.source.loadDocument();
      _appliedInitialLocation = false;
      _pageCountChapterIndex = null;
      _pageCountRetrySerial = null;
      _pageCountFuture = null;
      _resolvedDirection = null;
    });
  }

  void _retryChapter() {
    comicDebugLog(
      'retry',
      'chapterIndex=$_chapterIndex retrySerial=${_retrySerial + 1}',
    );
    widget.source.invalidateChapter(_chapterIndex);
    setState(() => _retrySerial++);
  }

  Future<void> _resolveDirection() async {
    final store = const PagedImageReaderSettingsStore();
    final direction = widget.source.settingsId == null
        ? await store.loadDirection(
            widget.source.localBookId,
            fallback: widget.source.defaultDirection,
          )
        : await store.loadDirectionForKey(
            widget.source.settingsId,
            fallback: widget.source.defaultDirection,
          );
    if (!mounted) return;
    setState(() => _resolvedDirection = direction);
  }

  Future<void> _setHorizontalMode() async {
    final store = const PagedImageReaderSettingsStore();
    if (widget.source.settingsId == null) {
      await store.saveDirection(
        widget.source.localBookId,
        ImageReaderDirection.ltr,
      );
    } else {
      await store.saveDirectionForKey(
        widget.source.settingsId,
        ImageReaderDirection.ltr,
      );
    }
    if (!mounted) return;
    setState(() => _resolvedDirection = ImageReaderDirection.ltr);
  }

  Future<void> _showCatalog(ImageReaderDocument document) async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          itemCount: document.chapters.length,
          itemBuilder: (context, index) => ListTile(
            selected: index == _chapterIndex,
            title: Text(document.chapters[index].title),
            onTap: () => Navigator.of(sheetContext).pop(index),
          ),
        ),
      ),
    );
    if (selected != null) {
      if (_resolvedDirection == ImageReaderDirection.vertical) {
        setState(() {
          _chapterIndex = selected;
          _pageIndex = 0;
          _retrySerial++;
        });
      } else {
        await _openChapter(selected, page: 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<ImageReaderDocument>(
        future: _documentFuture,
        builder: (context, catalog) {
          if (catalog.hasError) {
            comicDebugLog(
              'document',
              'host failed title=${source.bookTitle}',
              error: catalog.error,
              stackTrace: catalog.stackTrace,
            );
            return PagedReaderMessageScaffold(
              title: source.bookTitle,
              message: source.describeError(catalog.error!, context.l10n),
              palette: source.theme,
              onRetry: _retryDocument,
            );
          }
          final document = catalog.data;
          if (document == null) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            );
          }
          if (document.chapters.isEmpty) {
            return PagedReaderMessageScaffold(
              title: source.bookTitle,
              message: source.emptyPagesMessage(context.l10n),
              palette: source.theme,
            );
          }
          if (!_appliedInitialLocation) {
            _appliedInitialLocation = true;
            comicDebugLog(
              'document',
              'ready chapters=${document.chapters.length} '
                  'initialChapter=${document.initialChapterIndex} '
                  'initialPage=${document.initialPageIndex}',
            );
            _chapterIndex = document.initialChapterIndex.clamp(
              0,
              document.chapters.length - 1,
            );
            _pageIndex = document.initialPageIndex;
          }
          final chapterIndex = _chapterIndex.clamp(
            0,
            document.chapters.length - 1,
          );
          final direction = _resolvedDirection;
          if (direction == null) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            );
          }
          if (direction == ImageReaderDirection.vertical) {
            _markContentReady();
            return ContinuousImageReader(
              key: ValueKey('continuous-image-reader-$_retrySerial'),
              document: document,
              source: source,
              initialChapterIndex: chapterIndex,
              initialPageIndex: _pageIndex,
              onTableOfContents: document.chapters.length > 1
                  ? () => unawaited(_showCatalog(document))
                  : null,
              onSettings: _setHorizontalMode,
              onChangeReadingMode: _setHorizontalMode,
            );
          }
          if (_pageCountFuture == null ||
              _pageCountChapterIndex != chapterIndex ||
              _pageCountRetrySerial != _retrySerial) {
            _pageCountChapterIndex = chapterIndex;
            _pageCountRetrySerial = _retrySerial;
            _pageCountFuture = source.loadChapterPageCount(chapterIndex);
          }
          return FutureBuilder<int>(
            key: ValueKey('image-chapter-$chapterIndex-$_retrySerial'),
            future: _pageCountFuture,
            builder: (context, pages) {
              if (pages.hasError) {
                comicDebugLog(
                  'page-count',
                  'failed chapterIndex=$chapterIndex '
                      'title=${document.chapters[chapterIndex].title}',
                  error: pages.error,
                  stackTrace: pages.stackTrace,
                );
                return PagedReaderMessageScaffold(
                  title: document.chapters[chapterIndex].title,
                  message: source.describeError(pages.error!, context.l10n),
                  palette: source.theme,
                  onRetry: _retryChapter,
                );
              }
              final pageCount = pages.data;
              if (pageCount == null) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.white70),
                );
              }
              if (pageCount <= 0) {
                comicDebugLog(
                  'page-count',
                  'empty chapterIndex=$chapterIndex '
                      'title=${document.chapters[chapterIndex].title}',
                );
                return PagedReaderMessageScaffold(
                  title: document.chapters[chapterIndex].title,
                  message: source.emptyPagesMessage(context.l10n),
                  palette: source.theme,
                  onRetry: _retryChapter,
                );
              }
              final initialPage = _pageIndex < 0
                  ? pageCount - 1
                  : _pageIndex.clamp(0, pageCount - 1);
              comicDebugLog(
                'page-count',
                'ready chapterIndex=$chapterIndex pages=$pageCount '
                    'initialPage=$initialPage retrySerial=$_retrySerial',
              );
              _pageIndex = initialPage;
              _markContentReady();
              return PagedImageReader(
                key: ValueKey('image-reader-$chapterIndex-$_retrySerial'),
                title: source.pageTitle(document, chapterIndex),
                pageCount: pageCount,
                initialPage: initialPage,
                settingsId: source.settingsId,
                bookId: source.localBookId,
                palette: source.theme,
                defaultDirection: direction,
                loadPage: (index, {preload = false}) =>
                    source.loadPage(chapterIndex, index, preload: preload),
                onRetryPage: (index) =>
                    source.invalidatePage(chapterIndex, index),
                onPageChanged: (index) {
                  _pageIndex = index;
                  unawaited(
                    source.saveProgress(
                      chapterIndex: chapterIndex,
                      pageIndex: index,
                      pageCount: pageCount,
                    ),
                  );
                },
                onReachedEnd: chapterIndex < document.chapters.length - 1
                    ? () => unawaited(_openChapter(chapterIndex + 1, page: 0))
                    : null,
                onReachedStart: chapterIndex > 0
                    ? () => unawaited(_openChapter(chapterIndex - 1, page: -1))
                    : null,
                onTableOfContents: document.chapters.length > 1
                    ? () => unawaited(_showCatalog(document))
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
