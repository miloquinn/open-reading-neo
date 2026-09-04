import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_volume_key_controller.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
import 'package:xxread/pages/reader/image/image_reader_chrome.dart';
import 'package:xxread/utils/book_open_transition.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

class ContinuousImageReader extends StatefulWidget {
  const ContinuousImageReader({
    super.key,
    required this.document,
    required this.source,
    required this.initialChapterIndex,
    required this.initialPageIndex,
    required this.onTableOfContents,
    required this.onSettings,
    required this.onChangeReadingMode,
    this.palette,
  });

  final ImageReaderDocument document;
  final ImageReaderSource source;
  final int initialChapterIndex;
  final int initialPageIndex;
  final VoidCallback? onTableOfContents;
  final VoidCallback onSettings;
  final VoidCallback onChangeReadingMode;
  final ReaderThemePalette? palette;

  @visibleForTesting
  static const chapterBoundaryKeyPrefix = 'continuous-chapter-boundary-';

  @visibleForTesting
  static const emptyChapterKeyPrefix = 'continuous-empty-chapter-';

  @visibleForTesting
  static const settingsButtonKey = ValueKey('continuous-reader-settings');

  @visibleForTesting
  static const modeButtonKey = ValueKey('continuous-reader-mode');

  @visibleForTesting
  static const pageKeyPrefix = 'continuous-page-';

  @visibleForTesting
  static const pageContentKeyPrefix = 'continuous-page-content-';

  @override
  State<ContinuousImageReader> createState() => _ContinuousImageReaderState();
}

class _ContinuousImageReaderState extends State<ContinuousImageReader> {
  final ItemScrollController _itemController = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final Map<int, Future<int>> _countLoads = {};
  final Map<int, int> _counts = {};
  final Set<int> _prefetchedChapters = {};
  final ValueNotifier<bool> _userScrolling = ValueNotifier(false);
  final Map<({int chapterIndex, int pageIndex}), double> _pageAspectRatios = {};

  List<_ContinuousEntry> _entries = const [];
  late int _currentChapter = widget.initialChapterIndex;
  late int _currentPage = widget.initialPageIndex;
  bool _chromeVisible = false;
  bool _initialJumpPending = true;
  int _windowGeneration = 0;
  bool _scrolling = false;
  bool _windowLoadInFlight = false;
  int? _pendingWindowChapter;

  ReaderThemePalette get _palette => widget.palette ?? widget.source.theme;

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_handlePositions);
    unawaited(ReaderKeepScreenOnController.activate(this));
    unawaited(_activateVolumeKeys());
    unawaited(_ensureWindow(widget.initialChapterIndex));
  }

  @override
  void dispose() {
    unawaited(ReaderVolumeKeyController.deactivate(this));
    unawaited(ReaderKeepScreenOnController.deactivate(this));
    _positions.itemPositions.removeListener(_handlePositions);
    _userScrolling.dispose();
    super.dispose();
  }

  Future<void> _activateVolumeKeys() {
    return ReaderVolumeKeyController.activate(
      owner: this,
      pageTurningAvailable: true,
      onNextPage: _nextPage,
      onPreviousPage: _previousPage,
    );
  }

  Future<int> _loadCount(int chapterIndex) {
    final cached = _counts[chapterIndex];
    if (cached != null) return Future.value(cached);
    return _countLoads.putIfAbsent(chapterIndex, () async {
      try {
        final count = await widget.source.loadChapterPageCount(chapterIndex);
        _counts[chapterIndex] = count;
        return count;
      } finally {
        _countLoads.remove(chapterIndex);
      }
    });
  }

  Future<bool> _ensureWindow(int anchorChapter) async {
    final generation = ++_windowGeneration;
    final requestedFirst = (anchorChapter - 1).clamp(
      0,
      widget.document.chapters.length - 1,
    );
    final requestedLast = (anchorChapter + 1).clamp(
      0,
      widget.document.chapters.length - 1,
    );
    final first = requestedFirst;
    final last = requestedLast;
    final loads = <Future<int>>[
      for (var index = first; index <= last; index++) _loadCount(index),
    ];
    await Future.wait(loads);
    if (!mounted || generation != _windowGeneration) return false;
    _counts.removeWhere(
      (chapter, _) => chapter < requestedFirst || chapter > requestedLast,
    );
    _prefetchedChapters.removeWhere(
      (chapter) => chapter < requestedFirst || chapter > requestedLast,
    );
    widget.source.retainChapterWindow(requestedFirst, requestedLast);
    final anchorChapterBeforeRebuild = _currentChapter;
    final anchorPageBeforeRebuild = _currentPage;
    final anchorAlignment = _currentEntryAlignment();
    final entries = <_ContinuousEntry>[];
    for (var chapter = first; chapter <= last; chapter++) {
      if (entries.isNotEmpty) {
        entries.add(
          _ContinuousEntry.boundary(
            chapterIndex: chapter,
            title: widget.document.chapters[chapter].title,
          ),
        );
      }
      final count = _counts[chapter] ?? 0;
      if (count <= 0) {
        entries.add(_ContinuousEntry.empty(chapterIndex: chapter));
      } else {
        for (var page = 0; page < count; page++) {
          entries.add(
            _ContinuousEntry.page(
              chapterIndex: chapter,
              pageIndex: page,
              pageCount: count,
            ),
          );
        }
      }
    }
    setState(() => _entries = List.unmodifiable(entries));
    if (_initialJumpPending) {
      _scheduleInitialJump();
    } else {
      _scheduleAnchorRestore(
        anchorChapterBeforeRebuild,
        anchorPageBeforeRebuild,
        anchorAlignment,
      );
    }
    _prefetchAdjacentChapters(anchorChapter);
    return true;
  }

  double _currentEntryAlignment() {
    final current = _entryIndexFor(_currentChapter, _currentPage);
    if (current < 0) return 0;
    for (final position in _positions.itemPositions.value) {
      if (position.index == current) {
        return position.itemLeadingEdge.clamp(0.0, 1.0);
      }
    }
    return 0;
  }

  void _scheduleAnchorRestore(
    int chapterIndex,
    int pageIndex,
    double alignment,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _entryIndexFor(chapterIndex, pageIndex);
      if (_itemController.isAttached && target >= 0) {
        _itemController.jumpTo(index: target, alignment: alignment);
      }
    });
  }

  void _scheduleInitialJump([int attemptsRemaining = 4]) {
    if (!_initialJumpPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_initialJumpPending) return;
      final target = _entryIndexFor(_currentChapter, _currentPage);
      if (_itemController.isAttached && target >= 0) {
        _itemController.jumpTo(index: target, alignment: 0);
        _initialJumpPending = false;
        return;
      }
      if (attemptsRemaining > 0) {
        _scheduleInitialJump(attemptsRemaining - 1);
      } else {
        _initialJumpPending = false;
        _handlePositions();
      }
    });
  }

  void _prefetchAdjacentChapters(int chapterIndex) {
    for (final neighbor in [chapterIndex - 1, chapterIndex + 1]) {
      if (neighbor < 0 || neighbor >= widget.document.chapters.length) continue;
      if (!_prefetchedChapters.add(neighbor)) continue;
      unawaited(_prefetchChapter(neighbor));
    }
  }

  Future<void> _prefetchChapter(int chapterIndex) async {
    try {
      final count = await _loadCount(chapterIndex);
      for (final page in [0, 1]) {
        if (page >= count) break;
        await widget.source.loadPage(chapterIndex, page, preload: true);
      }
    } catch (error, stackTrace) {
      _prefetchedChapters.remove(chapterIndex);
      comicDebugLog(
        'chapter-preload',
        'failed chapterIndex=$chapterIndex',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrolling = true;
      _userScrolling.value = true;
    } else if (notification is ScrollEndNotification) {
      if (_scrolling) {
        _scrolling = false;
        _userScrolling.value = false;
      }
      final pending = _pendingWindowChapter;
      if (pending != null && !_windowLoadInFlight) {
        _pendingWindowChapter = null;
        unawaited(_recenterWindow(pending));
      }
    }
    return false;
  }

  void _handlePositions() {
    if (!mounted || _entries.isEmpty || _initialJumpPending) return;
    final visible = _positions.itemPositions.value.where((position) {
      if (position.itemTrailingEdge <= 0 ||
          position.itemLeadingEdge >= 1 ||
          position.index < 0 ||
          position.index >= _entries.length) {
        return false;
      }
      final kind = _entries[position.index].kind;
      return kind == _ContinuousEntryKind.page ||
          kind == _ContinuousEntryKind.empty;
    });
    if (visible.isEmpty) return;
    final nearest = visible.reduce((left, right) {
      return left.itemLeadingEdge.abs() <= right.itemLeadingEdge.abs()
          ? left
          : right;
    });
    final entry = _entries[nearest.index];
    final chapterChanged = entry.chapterIndex != _currentChapter;
    final pageChanged =
        entry.kind == _ContinuousEntryKind.page &&
        entry.pageIndex != _currentPage;
    if (!chapterChanged && !pageChanged) return;
    setState(() {
      _currentChapter = entry.chapterIndex;
      _currentPage = entry.kind == _ContinuousEntryKind.page
          ? entry.pageIndex
          : 0;
    });
    if (entry.kind == _ContinuousEntryKind.page) {
      unawaited(
        widget.source.saveProgress(
          chapterIndex: entry.chapterIndex,
          pageIndex: entry.pageIndex,
          pageCount: entry.pageCount,
        ),
      );
    }
    _prefetchAdjacentChapters(entry.chapterIndex);
    if (chapterChanged &&
        (entry.chapterIndex == _windowFirst ||
            entry.chapterIndex == _windowLast)) {
      unawaited(_recenterWindow(entry.chapterIndex));
    }
  }

  int get _windowFirst {
    for (final entry in _entries) {
      if (entry.kind == _ContinuousEntryKind.page ||
          entry.kind == _ContinuousEntryKind.empty) {
        return entry.chapterIndex;
      }
    }
    return _currentChapter;
  }

  int get _windowLast {
    for (final entry in _entries.reversed) {
      if (entry.kind == _ContinuousEntryKind.page ||
          entry.kind == _ContinuousEntryKind.empty) {
        return entry.chapterIndex;
      }
    }
    return _currentChapter;
  }

  Future<void> _recenterWindow(int chapterIndex) async {
    if (chapterIndex <= 0 ||
        chapterIndex >= widget.document.chapters.length - 1 ||
        (_windowFirst <= chapterIndex - 1 && _windowLast >= chapterIndex + 1)) {
      return;
    }
    if (_scrolling || _windowLoadInFlight) {
      _pendingWindowChapter = chapterIndex;
      return;
    }

    _windowLoadInFlight = true;
    var nextChapter = chapterIndex;
    try {
      while (mounted) {
        _pendingWindowChapter = null;
        _initialJumpPending = false;
        await _ensureWindow(nextChapter);
        final pending = _pendingWindowChapter;
        if (_scrolling) return;
        if (pending == null ||
            pending <= 0 ||
            pending >= widget.document.chapters.length - 1 ||
            (_windowFirst <= pending - 1 && _windowLast >= pending + 1)) {
          return;
        }
        nextChapter = pending;
      }
    } finally {
      _windowLoadInFlight = false;
    }
  }

  int _entryIndexFor(int chapterIndex, int pageIndex) {
    final page = _entries.indexWhere(
      (entry) =>
          entry.kind == _ContinuousEntryKind.page &&
          entry.chapterIndex == chapterIndex &&
          entry.pageIndex == pageIndex,
    );
    if (page >= 0) return page;
    return _entries.indexWhere(
      (entry) =>
          entry.kind == _ContinuousEntryKind.empty &&
          entry.chapterIndex == chapterIndex,
    );
  }

  void _goToCurrentOffset(int delta) {
    final current = _entryIndexFor(_currentChapter, _currentPage);
    if (current < 0) return;
    var target = current + delta;
    while (target >= 0 && target < _entries.length) {
      if (_entries[target].kind == _ContinuousEntryKind.page) {
        if (_itemController.isAttached) {
          unawaited(
            _itemController.scrollTo(
              index: target,
              alignment: 0,
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
            ),
          );
        }
        return;
      }
      target += delta.sign;
    }
  }

  void _nextPage() => _goToCurrentOffset(1);

  void _previousPage() => _goToCurrentOffset(-1);

  void _goToPage(int pageIndex) {
    final target = _entryIndexFor(_currentChapter, pageIndex);
    if (target < 0 || !_itemController.isAttached) return;
    _itemController.jumpTo(index: target, alignment: 0);
  }

  void _handleTap(Offset position, Size size) {
    if (_chromeVisible) {
      setState(() => _chromeVisible = false);
      return;
    }
    final centerStart = size.width * 0.28;
    final centerEnd = size.width * 0.72;
    if (position.dx >= centerStart && position.dx <= centerEnd) {
      setState(() => _chromeVisible = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pageCount = _counts[_currentChapter] ?? 0;
    final displayPage = pageCount > 0 ? _currentPage + 1 : 0;
    return ColoredBox(
      color: _palette.background,
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) =>
                    _handleTap(details.localPosition, constraints.biggest),
                child: _entries.isEmpty
                    ? _ReaderLoadingState(
                        palette: _palette,
                        label: widget.document.chapters[_currentChapter].title,
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: _handleScrollNotification,
                        child: ScrollablePositionedList.builder(
                          itemScrollController: _itemController,
                          itemPositionsListener: _positions,
                          itemCount: _entries.length,
                          padding: EdgeInsets.zero,
                          addAutomaticKeepAlives: false,
                          itemBuilder: (context, index) {
                            final entry = _entries[index];
                            return switch (entry.kind) {
                              _ContinuousEntryKind.boundary => _ChapterBoundary(
                                key: ValueKey(
                                  '${ContinuousImageReader.chapterBoundaryKeyPrefix}${entry.chapterIndex}',
                                ),
                                palette: _palette,
                                title: entry.title,
                              ),
                              _ContinuousEntryKind.empty => _EmptyChapter(
                                key: ValueKey(
                                  '${ContinuousImageReader.emptyChapterKeyPrefix}${entry.chapterIndex}',
                                ),
                                palette: _palette,
                                message: widget.source.emptyPagesMessage(
                                  context.l10n,
                                ),
                                onRetry: () => unawaited(
                                  _retryChapter(entry.chapterIndex),
                                ),
                              ),
                              _ContinuousEntryKind.page => _ContinuousChapterPage(
                                key: ValueKey(
                                  '${ContinuousImageReader.pageKeyPrefix}${entry.chapterIndex}-${entry.pageIndex}',
                                ),
                                source: widget.source,
                                chapterIndex: entry.chapterIndex,
                                pageIndex: entry.pageIndex,
                                palette: _palette,
                                userScrolling: _userScrolling,
                                knownAspectRatio:
                                    _pageAspectRatios[(
                                      chapterIndex: entry.chapterIndex,
                                      pageIndex: entry.pageIndex,
                                    )],
                                onAspectRatio: (aspectRatio) {
                                  _pageAspectRatios[(
                                        chapterIndex: entry.chapterIndex,
                                        pageIndex: entry.pageIndex,
                                      )] =
                                      aspectRatio;
                                },
                              ),
                            };
                          },
                        ),
                      ),
              ),
            ),
          ),
          _ProgressPill(
            palette: _palette,
            visible: !_chromeVisible,
            page: displayPage,
            pageCount: pageCount,
            chapterTitle: widget.document.chapters[_currentChapter].title,
          ),
          ImageReaderChrome(
            palette: _palette,
            visible: _chromeVisible,
            title: widget.document.chapters[_currentChapter].title,
            pageIndex: _currentPage,
            pageCount: pageCount,
            directionIcon: Icons.swap_vert_rounded,
            directionLabel: context.l10n.imageReaderDirectionVertical,
            onBack: () {
              BookOpenTransition.beginExit();
              Navigator.of(context).maybePop();
            },
            onPageSelected: _goToPage,
            onTableOfContents: widget.onTableOfContents,
            directionKey: ContinuousImageReader.modeButtonKey,
            settingsKey: ContinuousImageReader.settingsButtonKey,
            onDirection: widget.onChangeReadingMode,
            onSettings: widget.onSettings,
          ),
        ],
      ),
    );
  }

  Future<void> _retryChapter(int chapterIndex) async {
    widget.source.invalidateChapter(chapterIndex);
    _counts.remove(chapterIndex);
    _prefetchedChapters.remove(chapterIndex);
    await _ensureWindow(chapterIndex);
  }
}

enum _ContinuousEntryKind { page, boundary, empty }

class _ContinuousEntry {
  const _ContinuousEntry._({
    required this.kind,
    required this.chapterIndex,
    this.pageIndex = 0,
    this.pageCount = 0,
    this.title = '',
  });

  factory _ContinuousEntry.page({
    required int chapterIndex,
    required int pageIndex,
    required int pageCount,
  }) => _ContinuousEntry._(
    kind: _ContinuousEntryKind.page,
    chapterIndex: chapterIndex,
    pageIndex: pageIndex,
    pageCount: pageCount,
  );

  factory _ContinuousEntry.boundary({
    required int chapterIndex,
    required String title,
  }) => _ContinuousEntry._(
    kind: _ContinuousEntryKind.boundary,
    chapterIndex: chapterIndex,
    title: title,
  );

  factory _ContinuousEntry.empty({required int chapterIndex}) =>
      _ContinuousEntry._(
        kind: _ContinuousEntryKind.empty,
        chapterIndex: chapterIndex,
      );

  final _ContinuousEntryKind kind;
  final int chapterIndex;
  final int pageIndex;
  final int pageCount;
  final String title;
}

class _ContinuousChapterPage extends StatefulWidget {
  const _ContinuousChapterPage({
    super.key,
    required this.source,
    required this.chapterIndex,
    required this.pageIndex,
    required this.palette,
    required this.userScrolling,
    required this.knownAspectRatio,
    required this.onAspectRatio,
  });

  final ImageReaderSource source;
  final int chapterIndex;
  final int pageIndex;
  final ReaderThemePalette palette;
  final ValueListenable<bool> userScrolling;
  final double? knownAspectRatio;
  final ValueChanged<double> onAspectRatio;

  @override
  State<_ContinuousChapterPage> createState() => _ContinuousChapterPageState();
}

class _ContinuousChapterPageState extends State<_ContinuousChapterPage> {
  Uint8List? _bytes;
  MemoryImage? _provider;
  Object? _error;
  double? _aspectRatio;
  bool _decoded = false;
  bool _presented = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _aspectRatio = widget.knownAspectRatio;
    widget.userScrolling.addListener(_handleScrollingChanged);
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _ContinuousChapterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.userScrolling, widget.userScrolling)) {
      oldWidget.userScrolling.removeListener(_handleScrollingChanged);
      widget.userScrolling.addListener(_handleScrollingChanged);
    }
    if (!identical(oldWidget.source, widget.source) ||
        oldWidget.chapterIndex != widget.chapterIndex ||
        oldWidget.pageIndex != widget.pageIndex) {
      _releaseProvider();
      _aspectRatio = widget.knownAspectRatio;
      _bytes = null;
      _provider = null;
      _error = null;
      _decoded = false;
      _presented = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    widget.userScrolling.removeListener(_handleScrollingChanged);
    _releaseProvider();
    super.dispose();
  }

  void _handleScrollingChanged() {
    if (widget.userScrolling.value || !_decoded || _presented || !mounted) {
      return;
    }
    setState(() => _presented = true);
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final bytes = await widget.source.loadPage(
        widget.chapterIndex,
        widget.pageIndex,
      );
      if (!mounted || generation != _loadGeneration) return;
      _bytes = bytes;
      _provider = MemoryImage(bytes);
      final ratio =
          _imageAspectRatio(bytes) ?? _aspectRatio ?? _defaultPageAspectRatio;
      _aspectRatio = ratio;
      widget.onAspectRatio(ratio);
      _decoded = true;
      if (!widget.userScrolling.value) {
        setState(() => _presented = true);
      }
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = error);
    }
  }

  void _releaseProvider() {
    _provider = null;
    _bytes = null;
  }

  Future<void> _retry() async {
    _loadGeneration++;
    await widget.source.invalidatePage(widget.chapterIndex, widget.pageIndex);
    if (!mounted) return;
    _releaseProvider();
    if (!mounted) return;
    setState(() {
      _error = null;
      _decoded = false;
      _presented = false;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = _aspectRatio ?? _defaultPageAspectRatio;
    if (_error != null) {
      return _PageErrorState(
        palette: widget.palette,
        pageNumber: widget.pageIndex + 1,
        onRetry: _retry,
      );
    }
    final provider = _provider;
    if (!_presented || provider == null || _bytes == null) {
      return _PageLoadingPlaceholder(
        palette: widget.palette,
        pageNumber: widget.pageIndex + 1,
        aspectRatio: aspectRatio,
      );
    }
    return KeyedSubtree(
      key: ValueKey(
        '${ContinuousImageReader.pageContentKeyPrefix}${widget.chapterIndex}-${widget.pageIndex}',
      ),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Image(
          image: provider,
          width: double.infinity,
          fit: BoxFit.fitWidth,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _PageErrorState(
            palette: widget.palette,
            pageNumber: widget.pageIndex + 1,
            onRetry: _retry,
          ),
        ),
      ),
    );
  }
}

const double _defaultPageAspectRatio = 1.0;

double _safeAspectRatio(double value) {
  if (!value.isFinite || value <= 0) return _defaultPageAspectRatio;
  return value.clamp(0.02, 50.0);
}

double? _imageAspectRatio(Uint8List bytes) {
  int u16be(int offset) => (bytes[offset] << 8) | bytes[offset + 1];
  int u16le(int offset) => bytes[offset] | (bytes[offset + 1] << 8);
  int u24le(int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
  int u32be(int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
  int u32le(int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
  int i32le(int offset) {
    final value = u32le(offset);
    return value >= 0x80000000 ? value - 0x100000000 : value;
  }

  double? ratio(int width, int height) =>
      width > 0 && height > 0 ? _safeAspectRatio(width / height) : null;

  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return ratio(u32be(16), u32be(20));
  }
  if (bytes.length >= 10 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return ratio(u16le(6), u16le(8));
  }
  if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return ratio(i32le(18).abs(), i32le(22).abs());
  }
  if (bytes.length >= 30 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    if (bytes[12] == 0x56 &&
        bytes[13] == 0x50 &&
        bytes[14] == 0x38 &&
        bytes[15] == 0x58) {
      return ratio(u24le(24) + 1, u24le(27) + 1);
    }
    if (bytes[12] == 0x56 &&
        bytes[13] == 0x50 &&
        bytes[14] == 0x38 &&
        bytes[15] == 0x4c &&
        bytes[20] == 0x2f) {
      final packed = u32le(21);
      return ratio((packed & 0x3fff) + 1, ((packed >> 14) & 0x3fff) + 1);
    }
    if (bytes[12] == 0x56 &&
        bytes[13] == 0x50 &&
        bytes[14] == 0x38 &&
        bytes[15] == 0x20 &&
        bytes[23] == 0x9d &&
        bytes[24] == 0x01 &&
        bytes[25] == 0x2a) {
      return ratio(u16le(26) & 0x3fff, u16le(28) & 0x3fff);
    }
  }
  if (bytes.length >= 4 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    const sizeMarkers = <int>{
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    };
    var offset = 2;
    while (offset + 3 < bytes.length) {
      while (offset < bytes.length && bytes[offset] != 0xff) {
        offset++;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd8 || marker == 0xd9 || marker == 0x01) continue;
      if (marker >= 0xd0 && marker <= 0xd7) continue;
      if (offset + 1 >= bytes.length) break;
      final segmentLength = u16be(offset);
      if (segmentLength < 2 || offset + segmentLength > bytes.length) break;
      if (sizeMarkers.contains(marker) && segmentLength >= 7) {
        return ratio(u16be(offset + 5), u16be(offset + 3));
      }
      offset += segmentLength;
    }
  }
  return null;
}

class _ChapterBoundary extends StatelessWidget {
  const _ChapterBoundary({
    super.key,
    required this.palette,
    required this.title,
  });

  final ReaderThemePalette palette;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.background,
      padding: const EdgeInsets.fromLTRB(24, 34, 24, 30),
      child: Column(
        children: [
          Container(
            width: 36,
            height: 3,
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.text,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressPill extends StatelessWidget {
  const _ProgressPill({
    required this.palette,
    required this.visible,
    required this.page,
    required this.pageCount,
    required this.chapterTitle,
  });

  final ReaderThemePalette palette;
  final bool visible;
  final int page;
  final int pageCount;
  final String chapterTitle;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 16,
      bottom: MediaQuery.paddingOf(context).bottom + 14,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Semantics(
            label: '$chapterTitle $page / $pageCount',
            child: ReaderControlBar(
              palette: palette,
              isTopBar: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 7,
                ),
                child: Text(
                  '$page / $pageCount',
                  style: TextStyle(
                    color: palette.secondaryText,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderLoadingState extends StatelessWidget {
  const _ReaderLoadingState({required this.palette, required this.label});

  final ReaderThemePalette palette;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: palette.secondaryText,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.secondaryText,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageLoadingPlaceholder extends StatelessWidget {
  const _PageLoadingPlaceholder({
    required this.palette,
    required this.pageNumber,
    required this.aspectRatio,
  });

  final ReaderThemePalette palette;
  final int pageNumber;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Container(
        color: palette.background,
        alignment: Alignment.center,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: palette.secondaryText.withValues(alpha: 0.56),
            semanticsLabel: '$pageNumber',
          ),
        ),
      ),
    );
  }
}

class _PageErrorState extends StatelessWidget {
  const _PageErrorState({
    required this.palette,
    required this.pageNumber,
    required this.onRetry,
  });

  final ReaderThemePalette palette;
  final int pageNumber;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      color: palette.background,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: palette.secondaryText,
            size: 30,
          ),
          const SizedBox(height: 10),
          Text(
            '$pageNumber',
            style: TextStyle(
              color: palette.secondaryText,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => unawaited(onRetry()),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(context.l10n.retry),
            style: OutlinedButton.styleFrom(
              foregroundColor: palette.text,
              side: BorderSide(color: palette.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChapter extends StatelessWidget {
  const _EmptyChapter({
    super.key,
    required this.palette,
    required this.message,
    required this.onRetry,
  });

  final ReaderThemePalette palette;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: palette.background,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.secondaryText, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(context.l10n.retry),
          ),
        ],
      ),
    );
  }
}
