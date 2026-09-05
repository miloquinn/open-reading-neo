part of 'native_reader_page.dart';

extension _NativeReaderLoading on _NativeReaderPageState {
  String get _navigationReplacementCacheKey =>
      '$_bookCacheKey:${_replaceRules.rulesSignature}';

  void _initializeReaderDependencies() {
    if (_readerDependenciesInitialized) return;
    NativeReaderCacheStore.instance.registerMemoryClearer(
      clearNativeReaderMemoryCaches,
    );
    final cacheKey = _bookCacheKey;
    _readerMemoryCacheKey = cacheKey;
    NativeReaderCacheStore.instance.retainFrom(this, cacheKey);
    _paginationCacheLoadFuture = _loadPersistedPaginationCache();
    if (_shouldBypassReaderMemoryCaches) {
      // Large books already retain substantial parsed chapter and image data
      // in memory. Keeping that graph in the static reopen cache prevents it
      // from being released after leaving the reader and can push Android into
      // heavy GC or an OOM. Disk caches still cover indexed TXT and pagination.
      _pageCache = <String, List<_ReaderPageData>>{};
      _chaptersFuture = _prepareLoadedChapters(_loadBook());
      _readerDependenciesInitialized = true;
      return;
    }
    if (!_bookMemoryCache.containsKey(cacheKey) &&
        _bookMemoryCache.length >= 2) {
      final oldestKey = _bookMemoryCache.keys.first;
      _bookMemoryCache.remove(oldestKey);
      unawaited(NativeReaderCacheStore.instance.release(oldestKey));
      _navigationMemoryCache.removeWhere(
        (key, _) => key == oldestKey || key.startsWith('$oldestKey:'),
      );
      _paginationMemoryCache.remove(oldestKey);
    }
    _pageCache = _paginationMemoryCache.putIfAbsent(cacheKey, () => {});
    final cachedChapters = _bookMemoryCache.putIfAbsent(cacheKey, () {
      late final Future<List<_NativeChapter>> loading;
      loading = _loadBook().onError((error, stackTrace) {
        if (identical(_bookMemoryCache[cacheKey], loading)) {
          _bookMemoryCache.remove(cacheKey);
          _paginationMemoryCache.remove(cacheKey);
          unawaited(NativeReaderCacheStore.instance.release(cacheKey));
        }
        Error.throwWithStackTrace(
          error ?? StateError('Unknown reader loading error'),
          stackTrace,
        );
      });
      return loading;
    });
    _chaptersFuture = _prepareLoadedChapters(cachedChapters);
    _readerDependenciesInitialized = true;
  }

  Future<List<_NativeChapter>> _prepareLoadedChapters(
    Future<List<_NativeChapter>> chaptersFuture,
  ) async {
    await _paginationCacheLoadFuture;
    await _replaceRules.load();
    final chapters = await chaptersFuture;
    if (!mounted) return const <_NativeChapter>[];
    NativeReaderCacheStore.instance.retainFrom(this, _bookCacheKey);
    if (chapters.isEmpty) return chapters;
    for (final chapter in chapters) {
      chapter.configureReplacement(widget.book.title);
    }
    final replacementService = _replaceRules;
    for (final chapter in chapters) {
      chapter.prepareReplacementRevision(replacementService.revision);
    }
    const titleBatchSize = 256;
    for (var start = 0; start < chapters.length; start += titleBatchSize) {
      final end = math.min(start + titleBatchSize, chapters.length);
      final batch = chapters.sublist(start, end);
      final cleaned = await replacementService.applyBatchAsync(
        batch.map((chapter) => chapter.originalTitle).toList(growable: false),
        bookTitle: widget.book.title,
        title: true,
      );
      for (var index = 0; index < batch.length; index++) {
        batch[index].applyPreparedTitle(cleaned.values[index]);
      }
    }

    final preparedNavigation = await _prepareNavigationTitles(
      _parsedNavigationChapters,
    );
    _loadedChapters = chapters;
    final initialChapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
    // 冷缓存打开时，章节文本的读取与 UTF-8 解码（UI isolate 上数十毫秒）
    // 等封面飞到静止的停留画面再执行，避免解码回调冻结飞行帧。
    if (_pageCache.isEmpty) await _waitForOpeningCoverHold();
    await _loadIndexedChapterWindow(chapters, initialChapterIndex);
    _navigationChapters =
        _navigationMemoryCache[_navigationReplacementCacheKey] ??
        (preparedNavigation.isNotEmpty
            ? preparedNavigation
            : List<ReaderNavigationChapter>.generate(
                chapters.length,
                (index) => ReaderNavigationChapter(
                  title: chapters[index].title,
                  index: index,
                  id: chapters[index].id,
                  depth: chapters[index].depth,
                ),
                growable: false,
              ));
    _navigationMemoryCache[_navigationReplacementCacheKey] =
        _navigationChapters;
    _navigationCatalog = ReaderNavigationCatalog(_navigationChapters);
    return chapters;
  }

  Future<List<ReaderNavigationChapter>> _prepareNavigationTitles(
    List<ReaderNavigationChapter> navigation,
  ) async {
    if (navigation.isEmpty) return const <ReaderNavigationChapter>[];
    final cleaned = await _replaceRules.applyBatchAsync(
      navigation.map((entry) => entry.title).toList(growable: false),
      bookTitle: widget.book.title,
      title: true,
    );
    return List<ReaderNavigationChapter>.generate(
      navigation.length,
      (index) => ReaderNavigationChapter(
        title: cleaned.values[index],
        index: navigation[index].index,
        id: navigation[index].id,
        fragment: navigation[index].fragment,
        depth: navigation[index].depth,
      ),
      growable: false,
    );
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
        chapters[index].prepareReplacementAsync(_replaceRules),
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
      final operation = Object();
      NativeReaderCacheStore.instance.retain(
        operation,
        missing.first.epubLoadArguments['cacheDirectory'] as String,
      );
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
        NativeReaderCacheStore.instance.scheduleMaintenance(
          Directory(first.epubLoadArguments['cacheDirectory'] as String).parent,
        );
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
        unawaited(NativeReaderCacheStore.instance.release(operation));
      }
    }
    await Future.wait<void>(pending);
  }

  Future<List<_NativeChapter>> _loadBook() async {
    final operation = Object();
    final generation = NativeReaderCacheStore.instance.generation;
    try {
      return await _loadBookWithCacheOwner(operation, generation);
    } finally {
      unawaited(NativeReaderCacheStore.instance.release(operation));
    }
  }

  Future<List<_NativeChapter>> _loadBookWithCacheOwner(
    Object operation,
    int cacheGeneration,
  ) async {
    final l10n = context.l10n;
    await _replaceRules.load();
    final format = _activeBook.format.toLowerCase();
    final webBytes = kIsWeb
        ? await WebBookFileStore().read(_activeBook.filePath)
        : null;
    if (kIsWeb && webBytes == null) {
      throw StateError('Web 书籍文件不存在');
    }
    if (format == 'txt') {
      if (!kIsWeb) await TxtEditService().recoverInterruptedEdit(_activeBook);
      if (webBytes != null) {
        final decoded = EnhancedTxtImportService().decodeWithOverride(
          webBytes,
          encodingOverride: _activeBook.textEncoding,
          verifyEncodingOverride: true,
        );
        return _parseTxtChapters(
          decoded,
          _activeBook.title,
          l10n.readerPrefaceTitle,
        );
      }
      final sourceFile = File(_activeBook.filePath);
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
      final cacheStore = NativeReaderCacheStore.instance;
      await cacheStore.acquire(operation, cachePath);
      if (cacheGeneration != cacheStore.generation) {
        cacheStore.discardWhenReleased(cachePath);
      }
      if (mounted) cacheStore.retain(this, cachePath);
      if (cacheGeneration == cacheStore.generation &&
          _bookMemoryCache.containsKey(_bookCacheKey)) {
        cacheStore.retain(_bookCacheKey, cachePath);
      }
      cacheStore.scheduleMaintenance(cacheDirectory);
      if (useParsedCache) {
        final cached = await compute(_readParsedChapterCache, cachePath);
        if (cached != null) {
          return cached
              .map(
                (chapter) => _nativeChapterFromMap(
                  chapter,
                  bookTitle: _activeBook.title,
                ),
              )
              .toList(growable: false);
        }
      }

      final parseArguments = <String, dynamic>{
        'path': sourceFile.path,
        'encoding': _activeBook.textEncoding,
        'title': _activeBook.title,
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
            bookTitle: _activeBook.title,
          );
        }

        // A first-time 70 MB index can saturate CPU and storage bandwidth even
        // though it runs in another isolate. Keep it completely outside the
        // cover flight and cover-to-loader handoff so opening motion stays
        // responsive; cached indexes only wait for the route itself above.
        if (!await _waitForLargeTxtIndexingWindow()) {
          return const <_NativeChapter>[];
        }

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
        cacheStore.scheduleMaintenance(cacheDirectory, force: true);
        return _nativeChaptersFromFileIndex(
          indexed,
          bookTitle: _activeBook.title,
        );
      }

      // Small TXT books can keep using the JSON chapter cache.
      final parsed = await compute(_parseTxtFileInBackground, parseArguments);
      if (cacheGeneration == cacheStore.generation) {
        final writer = Object();
        cacheStore.retain(writer, cachePath);
        unawaited(
          compute(_writeParsedChapterCache, <String, dynamic>{
                'path': cachePath,
                'chapters': parsed,
              })
              .then((_) => cacheStore.maintain(cacheDirectory, force: true))
              .whenComplete(() => cacheStore.release(writer))
              .catchError((Object error) {
                debugPrint('TXT cache persistence failed: $error');
              }),
        );
      }
      return parsed
          .map(
            (chapter) =>
                _nativeChapterFromMap(chapter, bookTitle: _activeBook.title),
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
      final cacheStore = NativeReaderCacheStore.instance;
      await cacheStore.acquire(operation, cacheRoot);
      if (cacheGeneration != cacheStore.generation) {
        cacheStore.discardWhenReleased(cacheRoot);
      }
      if (mounted) cacheStore.retain(this, cacheRoot);
      if (cacheGeneration == cacheStore.generation &&
          _bookMemoryCache.containsKey(_bookCacheKey)) {
        cacheStore.retain(_bookCacheKey, cacheRoot);
      }
      cacheStore.scheduleMaintenance(cacheDirectory);
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
        cacheStore.scheduleMaintenance(cacheDirectory, force: true);
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
      _parsedNavigationChapters =
          (index['navigation'] as List<dynamic>? ?? const <dynamic>[])
              .map((raw) {
                final descriptor = Map<String, dynamic>.from(raw as Map);
                final chapterIndex = (descriptor['chapterIndex'] as num?)
                    ?.toInt();
                if (chapterIndex == null ||
                    chapterIndex < 0 ||
                    chapterIndex >= chapters.length) {
                  return null;
                }
                final chapter = chapters[chapterIndex];
                return ReaderNavigationChapter(
                  title: descriptor['title'] as String? ?? chapter.title,
                  index: chapterIndex,
                  id: chapter.id,
                  fragment: descriptor['fragment'] as String?,
                  depth:
                      (descriptor['depth'] as num?)?.toInt() ?? chapter.depth,
                );
              })
              .whereType<ReaderNavigationChapter>()
              .toList(growable: false);
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
