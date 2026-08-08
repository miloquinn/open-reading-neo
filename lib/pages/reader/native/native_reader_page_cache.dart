part of 'native_reader_page.dart';

extension _NativeReaderPageCache on _NativeReaderPageState {
  List<_ReaderPageData> _pagesFor(
    _NativeChapter chapter,
    int chapterIndex,
    Size size,
    TextDirection direction,
    TextScaler textScaler,
  ) {
    final key = _paginationFingerprintFor(
      chapterIndex,
      size,
      direction,
      textScaler,
    );
    final maxCachedLayouts = widget.book.format.toLowerCase() == 'epub'
        ? 12
        : 96;
    if (!_pageCache.containsKey(key) && _pageCache.length >= maxCachedLayouts) {
      _pageCache.remove(_pageCache.keys.first);
    }
    final memoryCached = _pageCache[key];
    if (memoryCached != null) return memoryCached;

    final persistedPayload = _persistedPaginationPayloads[key];
    if (persistedPayload != null) {
      final restored = _restoreNativePagination(
        payload: persistedPayload,
        chapter: chapter,
        firstLineIndent: _firstLineIndent,
        paragraphSpacing: _paragraphSpacing,
        normalizeParagraphBreaks: _normalizesParagraphBreaks(
          widget.book.format,
        ),
      );
      if (restored != null) {
        _pageCache[key] = restored;
        return restored;
      }
      _persistedPaginationPayloads.remove(key);
    }

    widget.onPaginationCacheMiss?.call(chapterIndex);
    final verticalChrome = _pageMode == NativePageMode.verticalScroll
        ? _verticalChrome
        : null;
    final pages = developer.Timeline.timeSync(
      'paginateChapter',
      arguments: {'chapter': chapterIndex, 'chars': chapter.plainText.length},
      () => _paginateChapter(
        chapter,
        maxWidth: readerTextContentWidth(size.width, _horizontalMargin),
        maxHeight:
            verticalChrome?.contentHeight(size.height) ??
            readerTextContentHeight(
              size.height,
              _effectiveTopMargin,
              _effectiveBottomMargin,
            ),
        flowStyle: _readerTextFlowStyle(
          direction: direction,
          textScaler: textScaler,
        ),
        style: _readerTextStyle,
        firstLineIndent: _firstLineIndent,
        paragraphSpacing: _paragraphSpacing,
        normalizeParagraphBreaks: _normalizesParagraphBreaks(
          widget.book.format,
        ),
        showDedicatedChapterTitlePage:
            widget.book.format.toLowerCase() != 'txt' ||
            _txtChapterTitlePageEnabled,
      ),
    );
    _pageCache[key] = pages;
    _persistNativePagination(
      layoutFingerprint: key,
      chapterIndex: chapterIndex,
      pages: pages,
    );
    return pages;
  }

  void _scheduleBookPaginationWarm(
    List<_NativeChapter> chapters,
    int chapterIndex,
    Size size,
    TextDirection direction,
    TextScaler textScaler,
  ) {
    bool supportsBookPaginationWarm() =>
        _pageMode == NativePageMode.horizontalSlide ||
        _pageMode == NativePageMode.coverSlide ||
        _pageMode == NativePageMode.pageCurl;
    if (!supportsBookPaginationWarm() ||
        chapterIndex < 0 ||
        chapterIndex >= chapters.length ||
        size.isEmpty) {
      return;
    }
    final key = _paginationFingerprintFor(
      chapterIndex,
      size,
      direction,
      textScaler,
    );
    if (_pageCache.containsKey(key) ||
        !_queuedHorizontalPaginationWarms.add(key)) {
      return;
    }
    late void Function(Duration) warmAfterFrame;
    void scheduleAfterFrame({bool requestFrame = false}) {
      WidgetsBinding.instance.addPostFrameCallback(warmAfterFrame);
      // Futures completed by the EPUB isolate do not schedule a Flutter frame.
      // Without this request the warmed chapter can remain invisible until an
      // unrelated rebuild, such as opening the table of contents.
      if (requestFrame) WidgetsBinding.instance.ensureVisualUpdate();
    }

    warmAfterFrame = (Duration _) {
      if (!mounted ||
          !supportsBookPaginationWarm() ||
          key !=
              _paginationFingerprintFor(
                chapterIndex,
                size,
                direction,
                textScaler,
              )) {
        _queuedHorizontalPaginationWarms.remove(key);
        return;
      }
      // 整章排版是主线程重活；打开动画（含正文渐显）没播完前先让帧，
      // 每帧末尾重试。动画结束时必有 setState 触发新帧，队列不会滞留。
      if (!_openingFlightSettledNow) {
        scheduleAfterFrame();
        return;
      }
      final chapter = chapters[chapterIndex];
      if (!chapter.hasLoadedText) {
        debugPrint(
          '[reader-horizontal] warm content start chapter=$chapterIndex',
        );
        _loadIndexedChapterWindow(
          chapters,
          chapterIndex,
          retainAroundCurrentChapter: true,
        ).then((_) {
          if (mounted) {
            debugPrint(
              '[reader-horizontal] warm content complete '
              'chapter=$chapterIndex',
            );
            scheduleAfterFrame(requestFrame: true);
          } else {
            _queuedHorizontalPaginationWarms.remove(key);
          }
        }, onError: (_, _) => _queuedHorizontalPaginationWarms.remove(key));
        return;
      }
      final pageController = _pageController;
      if (pageController != null &&
          pageController.hasClients &&
          pageController.position.isScrollingNotifier.value) {
        final scrolling = pageController.position.isScrollingNotifier;
        late VoidCallback resumeWhenIdle;
        resumeWhenIdle = () {
          if (scrolling.value) return;
          scrolling.removeListener(resumeWhenIdle);
          if (mounted) {
            scheduleAfterFrame(requestFrame: true);
          } else {
            _queuedHorizontalPaginationWarms.remove(key);
          }
        };
        scrolling.addListener(resumeWhenIdle);
        return;
      }
      _queuedHorizontalPaginationWarms.remove(key);
      _pagesFor(chapter, chapterIndex, size, direction, textScaler);
      if (mounted &&
          chapterIndex >= _horizontalFirstChapter &&
          chapterIndex <= _horizontalLastChapter) {
        _setReaderState(() {});
      }
    };

    scheduleAfterFrame();
  }

  String _paginationFingerprintFor(
    int chapterIndex,
    Size size,
    TextDirection direction,
    TextScaler textScaler,
  ) => ReaderLayoutFingerprint(
    contentKey: '$chapterIndex',
    viewport: size,
    fontSize: _fontSize,
    fontWeight: _fontWeight,
    lineHeight: _lineHeight,
    letterSpacing: _letterSpacing,
    textAlign: _readerTextAlign,
    horizontalMargin: _horizontalMargin,
    verticalMargin: _topMargin + _bottomMargin,
    textScaler: textScaler,
    locale: Localizations.maybeLocaleOf(context),
    pageMode: _pageMode,
    firstLineIndent: _firstLineIndent,
    paragraphSpacing: _paragraphSpacing,
    textDirection: direction,
    extra:
        '${_pageMode == NativePageMode.verticalScroll ? _verticalChrome.paginationSignature : _readerSafeArea.paginationSignature}:'
        '${_readerFont.id}:'
        '${widget.book.format.toLowerCase() == 'txt' ? _txtChapterTitlePageEnabled : true}',
  ).cacheKey('native-line-v8');
}
