import 'dart:async';

import 'package:flutter/material.dart';

import 'package:xxread/book_sources/caching/source_cover_cache.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_reading_progress.dart';
import 'package:xxread/core/reader/paged_image_reader_settings.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/pages/reader/comic/continuous_image_reader.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/pages/reader/comic/local_comic_source.dart';
import 'package:xxread/pages/reader/comic/online_comic_source.dart';
import 'package:xxread/pages/reader/image/paged_image_reader.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_transitions.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_settings_controls.dart';

/// The single comic reader for local archives and online image chapters.
///
/// Storage and network differences live behind [ImageReaderSource]. Chapter
/// state, progress, reading modes, retry, controls, and cache pressure all
/// follow this one page implementation.
class ComicReaderPage extends StatefulWidget {
  const ComicReaderPage({super.key, required this.source});

  factory ComicReaderPage.local({
    Key? key,
    required Book book,
    required ReaderThemePalette theme,
  }) => ComicReaderPage(
    key: key,
    source: LocalComicSource(book: book, theme: theme),
  );

  factory ComicReaderPage.online({
    Key? key,
    required RegisteredBookSource source,
    required BookSourceBook book,
    BookSourceClient? client,
    BookSourceReadingProgressStore progressStore =
        const BookSourceReadingProgressStore(),
    ReaderThemePalette? theme,
    SourceCoverCache? imageCache,
  }) => ComicReaderPage(
    key: key,
    source: OnlineComicSource(
      source: source,
      book: book,
      client: client,
      progressStore: progressStore,
      imageCache: imageCache,
      theme: theme,
    ),
  );

  final ImageReaderSource source;

  static Future<void> open(
    BuildContext context,
    Book book, {
    BookOpenAnimation? animation,
    LibraryBookOpenAnimation? libraryAnimation,
    LibraryBookOpenAnimationPace animationPace =
        LibraryBookOpenAnimationPace.fast,
    ReaderThemePalette? initialTheme,
    bool waitForReaderClose = true,
  }) async {
    final theme = initialTheme ?? await ReaderThemes.loadSavedPalette();
    if (!context.mounted) return;
    final route = BookOpenTransition.createRoute<void>(
      ComicReaderPage.local(book: book, theme: theme),
      animation: animation,
      libraryAnimation: libraryAnimation,
      animationPace: animationPace,
      readerBackgroundColor: theme.background,
      waitForReaderReady: true,
    );
    final navigation = BookOpenTransition.push<void>(context, route);
    if (waitForReaderClose) {
      await navigation;
    } else {
      unawaited(navigation);
    }
  }

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage>
    with WidgetsBindingObserver {
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
  int _directionGeneration = 0;
  late ReaderThemePalette _readerPalette = widget.source.theme;
  late ImageReaderBackground _background =
      _readerPalette.brightness == Brightness.dark
      ? ImageReaderBackground.black
      : ImageReaderBackground.white;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.source.attach();
    unawaited(_resolveDirection());
    comicDebugLog(
      'host',
      'attach source=${widget.source.runtimeType} title=${widget.source.bookTitle} '
          'settingsId=${widget.source.settingsId}',
    );
  }

  @override
  void didUpdateWidget(covariant ComicReaderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.source, widget.source)) return;
    oldWidget.source.dispose();
    widget.source.attach();
    _readerPalette = widget.source.theme;
    _background = _readerPalette.brightness == Brightness.dark
        ? ImageReaderBackground.black
        : ImageReaderBackground.white;
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
    WidgetsBinding.instance.removeObserver(this);
    _directionGeneration++;
    widget.source.dispose();
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    widget.source.handleMemoryPressure(_chapterIndex);
  }

  @override
  void didChangePlatformBrightness() {
    if (_readerPalette.id != ReaderThemes.systemId) return;
    final palette = ReaderThemes.systemPalette();
    final background = _backgroundForPalette(palette);
    setState(() {
      _readerPalette = palette;
      _background = background;
    });
    ReaderThemes.rememberSavedPalette(palette);
    unawaited(const PagedImageReaderSettingsStore().saveBackground(background));
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
    _retainAround(index, document.chapters.length);
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

  void _retainAround(int chapterIndex, int chapterCount) {
    widget.source.retainChapterWindow(
      (chapterIndex - 1).clamp(0, chapterCount - 1),
      (chapterIndex + 1).clamp(0, chapterCount - 1),
    );
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
    final source = widget.source;
    final generation = ++_directionGeneration;
    final store = const PagedImageReaderSettingsStore();
    final direction = source.settingsId == null
        ? await store.loadDirection(
            source.localBookId,
            fallback: source.defaultDirection,
          )
        : await store.loadDirectionForKey(
            source.settingsId,
            fallback: source.defaultDirection,
          );
    if (!mounted ||
        generation != _directionGeneration ||
        !identical(source, widget.source)) {
      return;
    }
    setState(() => _resolvedDirection = direction);
  }

  Future<void> _showReaderSettings() async {
    final source = widget.source;
    final current = _resolvedDirection ?? source.defaultDirection;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _ComicReaderSettingsSheet(
        key: const ValueKey('continuous-reader-settings-sheet'),
        palette: _readerPalette,
        direction: current,
        onThemeChanged: _setReaderTheme,
        onDirectionChanged: _setDirection,
      ),
    );
  }

  ImageReaderBackground _backgroundForPalette(ReaderThemePalette palette) =>
      palette.brightness == Brightness.dark
      ? ImageReaderBackground.black
      : ImageReaderBackground.white;

  Future<void> _setReaderTheme(String themeId) async {
    final palette = ReaderThemes.byId(
      themeId,
      platformBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final background = _backgroundForPalette(palette);
    if (mounted) {
      setState(() {
        _readerPalette = palette;
        _background = background;
      });
    }
    ReaderThemes.rememberSavedPalette(palette);
    await Future.wait([
      const ReaderSettingsStore().saveThemeId(palette.id),
      const PagedImageReaderSettingsStore().saveBackground(background),
    ]);
  }

  Future<void> _setDirection(ImageReaderDirection direction) async {
    final source = widget.source;
    final generation = ++_directionGeneration;
    final store = const PagedImageReaderSettingsStore();
    if (source.settingsId == null) {
      await store.saveDirection(source.localBookId, direction);
    } else {
      await store.saveDirectionForKey(source.settingsId, direction);
    }
    if (!mounted ||
        generation != _directionGeneration ||
        !identical(source, widget.source)) {
      return;
    }
    setState(() => _resolvedDirection = direction);
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
      backgroundColor: _background.color,
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
              palette: _readerPalette,
              onRetry: _retryDocument,
            );
          }
          final document = catalog.data;
          if (document == null) {
            return Center(
              child: CircularProgressIndicator(
                color: _readerPalette.secondaryText,
              ),
            );
          }
          if (document.chapters.isEmpty) {
            return PagedReaderMessageScaffold(
              title: source.bookTitle,
              message: source.emptyPagesMessage(context.l10n),
              palette: _readerPalette,
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
            _retainAround(_chapterIndex, document.chapters.length);
          }
          final chapterIndex = _chapterIndex.clamp(
            0,
            document.chapters.length - 1,
          );
          final direction = _resolvedDirection;
          if (direction == null) {
            return Center(
              child: CircularProgressIndicator(
                color: _readerPalette.secondaryText,
              ),
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
              palette: _readerPalette,
              onSettings: () => unawaited(_showReaderSettings()),
              onChangeReadingMode: () =>
                  unawaited(_setDirection(ImageReaderDirection.ltr)),
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
                  palette: _readerPalette,
                  onRetry: _retryChapter,
                );
              }
              final pageCount = pages.data;
              if (pageCount == null) {
                return Center(
                  child: CircularProgressIndicator(
                    color: _readerPalette.secondaryText,
                  ),
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
                  palette: _readerPalette,
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
                palette: _readerPalette,
                backgroundOverride: _background,
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
                onDirectionChanged: _setDirection,
                onSettings: () => unawaited(_showReaderSettings()),
              );
            },
          );
        },
      ),
    );
  }
}

enum _ComicReaderSettingsTab { theme, paging }

class _ComicReaderSettingsSheet extends StatefulWidget {
  const _ComicReaderSettingsSheet({
    super.key,
    required this.palette,
    required this.direction,
    required this.onThemeChanged,
    required this.onDirectionChanged,
  });

  final ReaderThemePalette palette;
  final ImageReaderDirection direction;
  final Future<void> Function(String themeId) onThemeChanged;
  final Future<void> Function(ImageReaderDirection direction)
  onDirectionChanged;

  @override
  State<_ComicReaderSettingsSheet> createState() =>
      _ComicReaderSettingsSheetState();
}

class _ComicReaderSettingsSheetState extends State<_ComicReaderSettingsSheet> {
  late ReaderThemePalette _palette = widget.palette;
  late String _themeId = widget.palette.id;
  late ImageReaderDirection _direction = widget.direction;
  _ComicReaderSettingsTab _tab = _ComicReaderSettingsTab.theme;

  @override
  Widget build(BuildContext context) {
    final theme = _palette.toThemeData(typography: Theme.of(context).textTheme);
    return ReaderSettingsSheetFrame(
      palette: _palette,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.imageReaderSettings,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          SegmentedButton<_ComicReaderSettingsTab>(
            key: const ValueKey('comic-reader-settings-tab-bar'),
            expandedInsets: EdgeInsets.zero,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _ComicReaderSettingsTab.theme,
                label: Text(context.l10n.readerSettingsTabTheme),
              ),
              ButtonSegment(
                value: _ComicReaderSettingsTab.paging,
                label: Text(context.l10n.readerSettingsTabPaging),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (selection) =>
                setState(() => _tab = selection.first),
          ),
          const SizedBox(height: 16),
          if (_tab == _ComicReaderSettingsTab.theme) ...[
            Text(
              context.l10n.readerThemeDescription,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            ReaderThemeStrip(
              selectedThemeId: _themeId,
              palettes: [
                ReaderThemes.systemPalette(
                  platformBrightness: MediaQuery.platformBrightnessOf(context),
                ),
                ReaderThemes.day,
                ReaderThemes.pureBlack,
              ],
              showCustomAction: false,
              cardWidth: 98,
              spacing: 8,
              labelFor: (id) => switch (id) {
                ReaderThemes.systemId => context.l10n.readerThemeFollowSystem,
                'pureBlack' => context.l10n.darkMode,
                _ => context.l10n.lightMode,
              },
              onSelected: _selectTheme,
              onCustomThemeTap: () {},
            ),
          ] else ...[
            Text(
              context.l10n.imageReaderDirectionTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            RadioGroup<ImageReaderDirection>(
              groupValue: _direction,
              onChanged: (direction) {
                if (direction != null) _selectDirection(direction);
              },
              child: Column(
                children: [
                  RadioListTile<ImageReaderDirection>(
                    contentPadding: EdgeInsets.zero,
                    value: ImageReaderDirection.vertical,
                    title: Text(context.l10n.imageReaderDirectionVertical),
                  ),
                  RadioListTile<ImageReaderDirection>(
                    contentPadding: EdgeInsets.zero,
                    value: ImageReaderDirection.ltr,
                    title: Text(context.l10n.imageReaderDirectionLtr),
                  ),
                  RadioListTile<ImageReaderDirection>(
                    contentPadding: EdgeInsets.zero,
                    value: ImageReaderDirection.rtl,
                    title: Text(context.l10n.imageReaderDirectionRtl),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _selectTheme(String themeId) {
    final palette = ReaderThemes.byId(
      themeId,
      platformBrightness: MediaQuery.platformBrightnessOf(context),
    );
    setState(() {
      _themeId = themeId;
      _palette = palette;
    });
    unawaited(widget.onThemeChanged(themeId));
  }

  void _selectDirection(ImageReaderDirection direction) {
    setState(() => _direction = direction);
    unawaited(widget.onDirectionChanged(direction));
  }
}
