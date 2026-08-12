part of 'native_reader_page.dart';

extension _NativeReaderLoading on _NativeReaderPageState {
  void _initializeReaderDependencies() {
    if (_readerDependenciesInitialized) return;
    final cacheKey = _bookCacheKey;
    _paginationCacheLoadFuture = _loadPersistedPaginationCache();
    if (_isLargeTxtBook || !widget.usePaginationMemoryCache) {
      // Large TXT books already retain their chapter text in memory. Keeping
      // another static cache prevents that memory from being released after
      // leaving the reader and can push Android into heavy GC or an OOM.
      _pageCache = <String, List<_ReaderPageData>>{};
      _chaptersFuture = _prepareLoadedChapters(_loadBook());
      _readerDependenciesInitialized = true;
      return;
    }
    if (!_bookMemoryCache.containsKey(cacheKey) &&
        _bookMemoryCache.length >= 2) {
      final oldestKey = _bookMemoryCache.keys.first;
      _bookMemoryCache.remove(oldestKey);
      _navigationMemoryCache.remove(oldestKey);
      _paginationMemoryCache.remove(oldestKey);
    }
    _pageCache = _paginationMemoryCache.putIfAbsent(cacheKey, () => {});
    final cachedChapters = _bookMemoryCache.putIfAbsent(
      cacheKey,
      () => _loadBook().onError((error, stackTrace) {
        _bookMemoryCache.remove(cacheKey);
        _paginationMemoryCache.remove(cacheKey);
        Error.throwWithStackTrace(
          error ?? StateError('Unknown reader loading error'),
          stackTrace,
        );
      }),
    );
    _chaptersFuture = _prepareLoadedChapters(cachedChapters);
    _readerDependenciesInitialized = true;
  }

  Future<List<_NativeChapter>> _prepareLoadedChapters(
    Future<List<_NativeChapter>> chaptersFuture,
  ) async {
    await _paginationCacheLoadFuture;
    final chapters = await chaptersFuture;
    if (chapters.isEmpty) return chapters;
    for (final chapter in chapters) {
      chapter.configureReplacement(widget.book.title);
    }

    _loadedChapters = chapters;
    final initialChapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
    // 冷缓存打开时，章节文本的读取与 UTF-8 解码（UI isolate 上数十毫秒）
    // 等封面飞到静止的停留画面再执行，避免解码回调冻结飞行帧。
    if (_pageCache.isEmpty) await _waitForOpeningCoverHold();
    await _loadIndexedChapterWindow(chapters, initialChapterIndex);
    final replacementProgress = _replacementRestoreChapterProgress;
    if (replacementProgress != null) {
      final chapter = chapters[initialChapterIndex];
      await chapter.loadTextAsync();
      final restoredOffset = (chapter.plainText.length * replacementProgress)
          .round()
          .clamp(0, chapter.plainText.length);
      _anchorOffset = restoredOffset;
      _verticalCanonicalOffset = restoredOffset;
      _pageIndex = 0;
      _restoreAnchorAfterLayout = true;
      _initialPositionRestored = false;
      _initialPositionRestoreScheduled = false;
      _replacementRestoreChapterProgress = null;
    }
    _navigationChapters =
        _navigationMemoryCache[_bookCacheKey] ??
        List<ReaderNavigationChapter>.generate(
          chapters.length,
          (index) => ReaderNavigationChapter(
            title: chapters[index].title,
            index: index,
            id: chapters[index].id,
            depth: chapters[index].depth,
          ),
          growable: false,
        );
    _navigationCatalog = ReaderNavigationCatalog(_navigationChapters);
    return chapters;
  }

  Future<void> _loadIndexedChapterWindow(
    List<_NativeChapter> chapters,
    int chapterIndex, {
    bool retainAroundCurrentChapter = false,
  }) async {
    debugPrint(
      '[reader-horizontal] load window target=$chapterIndex '
      'current=$_chapterIndex first=$_horizontalFirstChapter '
      'last=$_horizontalLastChapter retain=$retainAroundCurrentChapter',
    );
    final indexes = <int>{
      chapterIndex,
      chapterIndex - 1,
      chapterIndex + 1,
      chapterIndex - 2,
      chapterIndex + 2,
      chapterIndex - 3,
      chapterIndex + 3,
    }.where((index) => index >= 0 && index < chapters.length).toList();
    final epubChapters = indexes
        .map((index) => chapters[index])
        .where((chapter) => chapter.isLazyEpub)
        .toList(growable: false);
    if (epubChapters.isNotEmpty) {
      await _loadEpubChapterBatch(epubChapters);
    }
    await Future.wait<void>([
      for (final index in indexes)
        if (!chapters[index].isLazyEpub) chapters[index].loadTextAsync(),
    ]);
    final retainedChapterIndex = retainAroundCurrentChapter
        ? _chapterIndex.clamp(0, chapters.length - 1)
        : chapterIndex;
    for (var index = 0; index < chapters.length; index++) {
      if ((index - retainedChapterIndex).abs() > 4) {
        chapters[index].unloadLazyContent();
      }
    }
    debugPrint(
      '[reader-horizontal] load window complete target=$chapterIndex '
      'retained=$retainedChapterIndex cacheLayouts=${_pageCache.length}',
    );
  }

  Future<void> _loadEpubChapterBatch(List<_NativeChapter> chapters) async {
    final pending = chapters
        .where((chapter) => chapter.hasPendingLoad)
        .map((chapter) => chapter.pendingLoad!)
        .toList(growable: false);
    final missing = chapters
        .where((chapter) => !chapter.hasLoadedText && !chapter.hasPendingLoad)
        .toList(growable: false);
    if (missing.isNotEmpty) {
      final completers = <_NativeChapter, Completer<void>>{
        for (final chapter in missing) chapter: Completer<void>(),
      };
      for (final entry in completers.entries) {
        entry.key.attachPendingLoad(entry.value.future);
      }
      try {
        final first = missing.first;
        final parsed =
            await compute(loadEpubNativeChapterWindow, <String, dynamic>{
              ...first.epubLoadArguments,
              'chapters': missing
                  .map((chapter) => chapter.epubDescriptor)
                  .toList(growable: false),
            });
        final results = (parsed['results'] as List<dynamic>).cast<Map>();
        final fonts = <String, String>{};
        for (final result in results) {
          fonts.addAll(
            Map<String, String>.from(result['fonts'] as Map? ?? const {}),
          );
        }
        await _registerEpubFonts(fonts);
        for (var index = 0; index < missing.length; index++) {
          missing[index].applyEpubResult(
            Map<String, dynamic>.from(results[index]),
          );
          completers[missing[index]]!.complete();
        }
      } catch (error, stackTrace) {
        debugPrint('EPUB batch failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        for (final completer in completers.values) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
        rethrow;
      } finally {
        for (final chapter in missing) {
          chapter.clearPendingLoad();
        }
      }
    }
    await Future.wait<void>(pending);
  }

  Future<List<_NativeChapter>> _loadBook() async {
    final l10n = context.l10n;
    await ReplaceRuleService.instance.load();
    final format = widget.book.format.toLowerCase();
    final webBytes = kIsWeb
        ? await WebBookFileStore().read(widget.book.filePath)
        : null;
    if (kIsWeb && webBytes == null) {
      throw StateError('Web 书籍文件不存在');
    }
    if (format == 'txt') {
      if (webBytes != null) {
        final decoded = EnhancedTxtImportService().decodeWithOverride(
          webBytes,
          encodingOverride: widget.book.textEncoding,
          verifyEncodingOverride: true,
        );
        return _parseTxtChapters(
          decoded,
          widget.book.title,
          l10n.readerPrefaceTitle,
        );
      }
      final sourceFile = File(widget.book.filePath);
      final fileSize = await sourceFile.length();
      final useParsedCache = fileSize <= _largeTxtFileThreshold;
      final cacheDirectory = Directory(
        path.join(
          (await getApplicationSupportDirectory()).path,
          'native_reader_cache',
        ),
      );
      final cacheName = sha1.convert(utf8.encode(_bookCacheKey)).toString();
      final cachePath = path.join(cacheDirectory.path, '$cacheName.json');
      if (useParsedCache) {
        final cached = await compute(_readParsedChapterCache, cachePath);
        if (cached != null) {
          return cached
              .map(
                (chapter) => _nativeChapterFromMap(
                  chapter,
                  bookTitle: widget.book.title,
                ),
              )
              .toList(growable: false);
        }
      }

      final parseArguments = <String, dynamic>{
        'path': sourceFile.path,
        'encoding': widget.book.textEncoding,
        'title': widget.book.title,
        'prefaceTitle': l10n.readerPrefaceTitle,
      };
      if (!useParsedCache) {
        final indexPath = '$cachePath.index';
        final dataPath = '$cachePath.data';
        // A cached index avoids the expensive scan, but materializing its
        // chapter descriptors and loading the initial text window can still
        // be substantial for very large books. Keep that work out of the
        // cover flight just like first-time indexing.
        if (!await _waitForOpeningRouteToSettle()) {
          return const <_NativeChapter>[];
        }
        final cachedIndex = await compute(_readLargeTxtIndexCache, indexPath);
        if (cachedIndex != null) {
          return _nativeChaptersFromFileIndex(
            cachedIndex,
            bookTitle: widget.book.title,
          );
        }

        // A first-time 70 MB index can saturate CPU and storage bandwidth even
        // though it runs in another isolate. Keep it completely outside the
        // cover flight and cover-to-loader handoff so opening motion stays
        // responsive; cached indexes only wait for the route itself above.
        if (!await _waitForLargeTxtIndexingWindow()) {
          return const <_NativeChapter>[];
        }

        unawaited(
          compute(
            _deleteOversizedParsedChapterCaches,
            cacheDirectory.path,
          ).catchError((_) {}),
        );

        // The worker writes normalized UTF-8 chapter data to disk and returns
        // only offsets/titles. The UI isolate loads one chapter at a time.
        final indexed = await compute(
          _indexTxtFileInBackground,
          <String, dynamic>{
            ...parseArguments,
            'indexPath': indexPath,
            'dataPath': dataPath,
          },
        );
        return _nativeChaptersFromFileIndex(
          indexed,
          bookTitle: widget.book.title,
        );
      }

      // Small TXT books can keep using the JSON chapter cache.
      final parsed = await compute(_parseTxtFileInBackground, parseArguments);
      if (useParsedCache) {
        unawaited(
          compute(_writeParsedChapterCache, <String, dynamic>{
            'path': cachePath,
            'chapters': parsed,
          }).catchError((_) {}),
        );
      }
      return parsed
          .map(
            (chapter) =>
                _nativeChapterFromMap(chapter, bookTitle: widget.book.title),
          )
          .toList(growable: false);
    }

    if (format == 'epub' && !kIsWeb) {
      final sourceFile = File(widget.book.filePath);
      final cacheBase = await _readerCacheDirectory();
      final cacheDirectory = Directory(
        path.join(cacheBase.path, 'native_reader_cache', 'epub'),
      );
      final cacheKey = sha1.convert(utf8.encode(_bookCacheKey)).toString();
      final cacheRoot = path.join(cacheDirectory.path, cacheKey);
      final indexPath = path.join(cacheRoot, 'index.json');
      final sourceSize = await sourceFile.length();
      final sourceModifiedMillis =
          (await sourceFile.lastModified()).millisecondsSinceEpoch;
      final arguments = <String, dynamic>{
        'epubPath': sourceFile.path,
        'cacheDirectory': cacheRoot,
        'indexPath': indexPath,
        'sourceSize': sourceSize,
        'sourceModifiedMillis': sourceModifiedMillis,
        'familyPrefix': cacheKey,
      };
      final cached = await compute(readEpubNativeIndex, arguments);
      final Map<String, dynamic> index;
      if (cached != null) {
        index = cached;
      } else {
        final staleCache = Directory(cacheRoot);
        if (await staleCache.exists()) {
          await staleCache.delete(recursive: true);
        }
        index = await compute(buildEpubNativeIndex, arguments);
      }
      final chapters = (index['chapters'] as List<dynamic>? ?? const [])
          .map(
            (chapter) => _NativeChapter.lazyEpub(
              descriptor: Map<String, dynamic>.from(chapter as Map),
              loadArguments: <String, dynamic>{
                'epubPath': sourceFile.path,
                'cacheDirectory': cacheRoot,
                'cssPaths': index['cssPaths'],
                'familyPrefix': cacheKey,
              },
              replaceBookTitle: widget.book.title,
            ),
          )
          .toList(growable: false);
      final navigation = (index['navigation'] as List<dynamic>? ?? const [])
          .map((entry) {
            final values = Map<String, dynamic>.from(entry as Map);
            final chapterIndex = values['chapterIndex'] as int;
            return ReaderNavigationChapter(
              title: values['title'] as String? ?? '',
              index: chapterIndex,
              id: chapters[chapterIndex].id,
              fragment: values['fragment'] as String?,
              depth: values['depth'] as int? ?? 0,
            );
          })
          .toList(growable: false);
      if (navigation.isNotEmpty) {
        _navigationMemoryCache[_bookCacheKey] = navigation;
      }
      return chapters;
    }

    final bytes = webBytes ?? await File(widget.book.filePath).readAsBytes();
    switch (format) {
      case 'epub':
        return _richChaptersFromParsed(
          await compute(_parseEpubChapters, bytes),
        );
      case 'mobi':
      case 'azw':
      case 'azw3':
        try {
          return _richChaptersFromParsed(
            await compute(_parseKindleChapters, bytes),
          );
        } on KindleDrmException {
          throw _ReaderBookLoadException(l10n.readerKindleDrmProtected);
        }
      case 'html':
      case 'htm':
      case 'xhtml':
        return _parseHtmlDocument(
          utf8.decode(bytes, allowMalformed: true),
          widget.book.title,
        );
      case 'md':
      case 'markdown':
        return _parseMarkdownDocument(
          utf8.decode(bytes, allowMalformed: true),
          widget.book.title,
          l10n.readerPrefaceTitle,
        );
      case 'fb2':
        return _parseFb2Document(
          utf8.decode(bytes, allowMalformed: true),
          widget.book.title,
        );
      case 'rtf':
        return _parseTxtChapters(
          _extractRtfText(bytes),
          widget.book.title,
          l10n.readerPrefaceTitle,
        );
      case 'docx':
        return _parseTxtChapters(
          _extractDocxText(bytes),
          widget.book.title,
          l10n.readerPrefaceTitle,
        );
      default:
        throw UnsupportedError(l10n.readerUnsupportedFormat);
    }
  }

  Future<bool> _waitForOpeningRouteToSettle() async {
    return waitForReaderOpeningRouteToSettle(
      routeAnimation: _routeAnimation,
      routeEntranceCompleted: _routeEntranceCompleted,
      isMounted: () => mounted,
    );
  }

  Future<bool> _waitForLargeTxtIndexingWindow() async {
    if (!await _waitForOpeningRouteToSettle()) return false;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return mounted &&
        (_routeAnimation == null ||
            _routeAnimation!.status == AnimationStatus.completed);
  }
}
