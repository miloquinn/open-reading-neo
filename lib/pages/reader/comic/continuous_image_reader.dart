import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_volume_key_controller.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';
import 'package:xxread/pages/reader/comic/image_reader_source.dart';
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
  });

  final ImageReaderDocument document;
  final ImageReaderSource source;
  final int initialChapterIndex;
  final int initialPageIndex;
  final VoidCallback? onTableOfContents;
  final VoidCallback onSettings;
  final VoidCallback onChangeReadingMode;

  @visibleForTesting
  static const chapterBoundaryKeyPrefix = 'continuous-chapter-boundary-';

  @override
  State<ContinuousImageReader> createState() => _ContinuousImageReaderState();
}

class _ContinuousImageReaderState extends State<ContinuousImageReader> {
  final ItemScrollController _itemController = ItemScrollController();
  final ItemPositionsListener _positions = ItemPositionsListener.create();
  final Map<int, Future<int>> _countLoads = {};
  final Map<int, int> _counts = {};
  final Set<int> _prefetchedChapters = {};

  List<_ContinuousEntry> _entries = const [];
  late int _currentChapter = widget.initialChapterIndex;
  late int _currentPage = widget.initialPageIndex;
  bool _chromeVisible = false;
  bool _initialJumpPending = true;
  int _windowGeneration = 0;

  ReaderThemePalette get _palette => widget.source.theme;

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

  Future<void> _ensureWindow(int anchorChapter) async {
    final generation = ++_windowGeneration;
    final first = (anchorChapter - 1).clamp(
      0,
      widget.document.chapters.length - 1,
    );
    final last = (anchorChapter + 1).clamp(
      0,
      widget.document.chapters.length - 1,
    );
    final loads = <Future<int>>[
      for (var index = first; index <= last; index++) _loadCount(index),
    ];
    await Future.wait(loads);
    if (!mounted || generation != _windowGeneration) return;
    widget.source.retainChapterWindow(first, last);
    _counts.removeWhere((index, _) => index < first || index > last);
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
    _scheduleInitialJump();
    _prefetchAdjacentChapters(anchorChapter);
  }

  void _scheduleInitialJump() {
    if (!_initialJumpPending) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemController.isAttached) return;
      final target = _entryIndexFor(_currentChapter, _currentPage);
      if (target < 0) return;
      _itemController.jumpTo(index: target, alignment: 0);
      _initialJumpPending = false;
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
      comicDebugLog(
        'chapter-preload',
        'failed chapterIndex=$chapterIndex',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handlePositions() {
    if (!mounted || _entries.isEmpty) return;
    final visible = _positions.itemPositions.value.where(
      (position) =>
          position.itemTrailingEdge > 0 &&
          position.itemLeadingEdge < 1 &&
          position.index >= 0 &&
          position.index < _entries.length &&
          _entries[position.index].kind == _ContinuousEntryKind.page,
    );
    if (visible.isEmpty) return;
    final nearest = visible.reduce((left, right) {
      return left.itemLeadingEdge.abs() <= right.itemLeadingEdge.abs()
          ? left
          : right;
    });
    final entry = _entries[nearest.index];
    final chapterChanged = entry.chapterIndex != _currentChapter;
    if (entry.chapterIndex == _currentChapter &&
        entry.pageIndex == _currentPage) {
      return;
    }
    setState(() {
      _currentChapter = entry.chapterIndex;
      _currentPage = entry.pageIndex;
    });
    unawaited(
      widget.source.saveProgress(
        chapterIndex: entry.chapterIndex,
        pageIndex: entry.pageIndex,
        pageCount: entry.pageCount,
      ),
    );
    _prefetchAdjacentChapters(entry.chapterIndex);
    if (chapterChanged &&
        (entry.chapterIndex == _windowFirst ||
            entry.chapterIndex == _windowLast)) {
      unawaited(_recenterWindow(entry.chapterIndex, nearest.index));
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

  Future<void> _recenterWindow(int chapterIndex, int oldIndex) async {
    if (chapterIndex <= 0 ||
        chapterIndex >= widget.document.chapters.length - 1) {
      return;
    }
    if ((_windowFirst == chapterIndex - 1 && _windowLast == chapterIndex + 1)) {
      return;
    }
    final oldEntry = _entries[oldIndex];
    final oldLeading = _positions.itemPositions.value
        .where((position) => position.index == oldIndex)
        .firstOrNull
        ?.itemLeadingEdge;
    _initialJumpPending = false;
    await _ensureWindow(chapterIndex);
    if (!mounted || !_itemController.isAttached) return;
    final target = _entryIndexFor(oldEntry.chapterIndex, oldEntry.pageIndex);
    if (target < 0) return;
    _itemController.jumpTo(
      index: target,
      alignment: oldLeading?.clamp(0, 1) ?? 0,
    );
  }

  int _entryIndexFor(int chapterIndex, int pageIndex) {
    return _entries.indexWhere(
      (entry) =>
          entry.kind == _ContinuousEntryKind.page &&
          entry.chapterIndex == chapterIndex &&
          entry.pageIndex == pageIndex,
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
    final pageCount = _counts[_currentChapter] ?? 1;
    return ColoredBox(
      color: Colors.black,
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
                    : ScrollablePositionedList.builder(
                        itemScrollController: _itemController,
                        itemPositionsListener: _positions,
                        itemCount: _entries.length,
                        padding: EdgeInsets.zero,
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
                              palette: _palette,
                              message: widget.source.emptyPagesMessage(
                                context.l10n,
                              ),
                              onRetry: () =>
                                  unawaited(_retryChapter(entry.chapterIndex)),
                            ),
                            _ContinuousEntryKind.page => _ContinuousChapterPage(
                              key: ValueKey(
                                'flow-${entry.chapterIndex}-${entry.pageIndex}',
                              ),
                              source: widget.source,
                              chapterIndex: entry.chapterIndex,
                              pageIndex: entry.pageIndex,
                              palette: _palette,
                            ),
                          };
                        },
                      ),
              ),
            ),
          ),
          _ProgressPill(
            palette: _palette,
            visible: !_chromeVisible,
            page: _currentPage + 1,
            pageCount: pageCount,
            chapterTitle: widget.document.chapters[_currentChapter].title,
          ),
          _ImageReaderChrome(
            palette: _palette,
            visible: _chromeVisible,
            title: widget.document.chapters[_currentChapter].title,
            page: _currentPage + 1,
            pageCount: pageCount,
            onBack: () {
              BookOpenTransition.beginExit();
              Navigator.of(context).maybePop();
            },
            onTableOfContents: widget.onTableOfContents,
            onMode: widget.onChangeReadingMode,
            onSettings: widget.onSettings,
          ),
        ],
      ),
    );
  }

  Future<void> _retryChapter(int chapterIndex) async {
    widget.source.invalidateChapter(chapterIndex);
    _counts.remove(chapterIndex);
    await _ensureWindow(_currentChapter);
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
  });

  final ImageReaderSource source;
  final int chapterIndex;
  final int pageIndex;
  final ReaderThemePalette palette;

  @override
  State<_ContinuousChapterPage> createState() => _ContinuousChapterPageState();
}

class _ContinuousChapterPageState extends State<_ContinuousChapterPage> {
  late Future<Uint8List> _bytes = widget.source.loadPage(
    widget.chapterIndex,
    widget.pageIndex,
  );

  Future<void> _retry() async {
    await widget.source.invalidatePage(widget.chapterIndex, widget.pageIndex);
    if (!mounted) return;
    final next = widget.source.loadPage(widget.chapterIndex, widget.pageIndex);
    setState(() => _bytes = next);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _PageErrorState(
            palette: widget.palette,
            pageNumber: widget.pageIndex + 1,
            onRetry: _retry,
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return _PageLoadingPlaceholder(
            palette: widget.palette,
            pageNumber: widget.pageIndex + 1,
          );
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 140),
          child: Image.memory(
            bytes,
            key: ValueKey(bytes.length),
            width: double.infinity,
            fit: BoxFit.fitWidth,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => _PageErrorState(
              palette: widget.palette,
              pageNumber: widget.pageIndex + 1,
              onRetry: _retry,
            ),
          ),
        );
      },
    );
  }
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
      color: Colors.black,
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

class _ImageReaderChrome extends StatelessWidget {
  const _ImageReaderChrome({
    required this.palette,
    required this.visible,
    required this.title,
    required this.page,
    required this.pageCount,
    required this.onBack,
    required this.onTableOfContents,
    required this.onMode,
    required this.onSettings,
  });

  final ReaderThemePalette palette;
  final bool visible;
  final String title;
  final int page;
  final int pageCount;
  final VoidCallback onBack;
  final VoidCallback? onTableOfContents;
  final VoidCallback onMode;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top + 10;
    final bottom = MediaQuery.paddingOf(context).bottom + 16;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: 20,
              right: 20,
              top: visible ? top : -100,
              child: ReaderControlBar(
                palette: palette,
                isTopBar: true,
                child: SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      const SizedBox(width: 7),
                      ReaderControlIconButton(
                        palette: palette,
                        onPressed: onBack,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        icon: Icons.arrow_back_rounded,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: palette.controlFill.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(99),
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
                      const SizedBox(width: 9),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: 22,
              right: 22,
              bottom: visible ? bottom : -100,
              child: ReaderControlBar(
                palette: palette,
                isTopBar: false,
                child: SizedBox(
                  height: 64,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      if (onTableOfContents != null)
                        _ChromeButton(
                          palette: palette,
                          icon: Icons.format_list_bulleted_rounded,
                          label: context.l10n.readerToolbarTOC,
                          onTap: onTableOfContents!,
                        ),
                      _ChromeButton(
                        palette: palette,
                        icon: Icons.swap_horiz_rounded,
                        label: context.l10n.imageReaderDirectionTitle,
                        onTap: onMode,
                      ),
                      _ChromeButton(
                        palette: palette,
                        icon: Icons.tune_rounded,
                        label: context.l10n.imageReaderSettings,
                        onTap: onSettings,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.palette,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final ReaderThemePalette palette;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 32,
      child: SizedBox(
        width: 82,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: palette.text),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
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
  });

  final ReaderThemePalette palette;
  final int pageNumber;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 320,
      color: Colors.black,
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
      color: Colors.black,
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
      color: Colors.black,
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
