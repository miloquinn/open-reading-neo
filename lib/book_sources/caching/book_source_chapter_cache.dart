import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../services/core/cache_disk_budget.dart';
import '../protocol/book_source_protocol.dart';

class BookSourceChapterCache {
  static const String directoryName = 'book_source_chapters';
  static const _memoryLimit = 24;
  static const _catalogMemoryLimit = 12;
  static const defaultMaxMemoryBytes = 24 * 1024 * 1024;
  static const defaultMaxDiskBytes = 256 * 1024 * 1024;
  static const chapterRefreshAfter = Duration(hours: 12);
  static const chapterDiskLifetime = Duration(days: 30);
  static const catalogRefreshAfter = Duration(minutes: 30);
  static const catalogDiskLifetime = Duration(days: 30);
  static final Map<String, _CacheEntry<BookSourceChapterContent>> _memory = {};
  static final Map<String, _CacheEntry<List<BookSourceChapter>>>
  _catalogMemory = {};
  static final Map<String, Future<BookSourceChapterContent>> _inFlight = {};
  static final Map<String, Future<List<BookSourceChapter>>> _catalogInFlight =
      {};
  static final Map<String, Future<void>> _diskWriteQueues = {};
  static final Map<String, bool> _memoryOrder = {};
  static int _memoryBytes = 0;
  static int _writeGeneration = 0;

  const BookSourceChapterCache({
    this.cacheDirectory,
    this.maxMemoryBytes = defaultMaxMemoryBytes,
    this.maxDiskBytes = defaultMaxDiskBytes,
    this.diskMaintenanceInterval = const Duration(minutes: 5),
    @visibleForTesting this.beforeDiskRead,
    @visibleForTesting this.beforeDiskWrite,
  }) : assert(maxMemoryBytes >= 0),
       assert(maxDiskBytes >= 0);

  final Directory? cacheDirectory;
  final int maxMemoryBytes;
  final int maxDiskBytes;
  final Duration diskMaintenanceInterval;

  /// Allows tests to hold or fail persistence without coupling cache reads to
  /// the filesystem implementation.
  @visibleForTesting
  final Future<void> Function()? beforeDiskRead;

  @visibleForTesting
  final Future<void> Function()? beforeDiskWrite;

  static void clearMemory() {
    _writeGeneration++;
    _inFlight.clear();
    _catalogInFlight.clear();
    releaseMemory();
  }

  /// Releases decoded chapter objects without cancelling pending disk writes.
  /// Used for OS memory pressure; explicit cache deletion still uses
  /// [clearMemory] so older writes cannot repopulate a user-cleared cache.
  static void releaseMemory() {
    _memory.clear();
    _catalogMemory.clear();
    _memoryOrder.clear();
    _memoryBytes = 0;
  }

  static int get memorySizeBytes => _memoryBytes;

  Future<BookSourceChapterContent> getOrLoad({
    required String sourceId,
    String sourceRevision = '',
    required String bookId,
    required String chapterId,
    Duration refreshAfter = chapterRefreshAfter,
    bool staleWhileRevalidate = true,
    required Future<BookSourceChapterContent> Function() loader,
  }) async {
    final key = _key(sourceId, sourceRevision, bookId, chapterId);
    final generation = _writeGeneration;
    final memory = _memory.remove(key);
    if (memory != null) {
      _memory[key] = memory;
      _touchMemory(key, catalog: false);
      return _resolveCachedContent(
        key,
        memory,
        refreshAfter: refreshAfter,
        staleWhileRevalidate: staleWhileRevalidate,
        loader: loader,
        generation: generation,
      );
    }

    final disk = await _readDisk(key);
    if (disk != null) {
      if (generation == _writeGeneration) _remember(key, disk);
      return _resolveCachedContent(
        key,
        disk,
        refreshAfter: refreshAfter,
        staleWhileRevalidate: staleWhileRevalidate,
        loader: loader,
        generation: generation,
      );
    }
    return _loadContent(key, loader, generation);
  }

  /// Returns a previously loaded chapter catalog without waiting for the
  /// source. Once the cached catalog is old enough, a refresh is started in
  /// the background so the next open sees additions without delaying this
  /// one. Catalogs remain usable while offline for up to 30 days.
  Future<List<BookSourceChapter>> getChapterCatalogOrLoad({
    required String sourceId,
    String sourceRevision = '',
    required String bookId,
    Duration refreshAfter = catalogRefreshAfter,
    bool staleWhileRevalidate = true,
    required Future<List<BookSourceChapter>> Function() loader,
  }) async {
    final key = _key(sourceId, sourceRevision, bookId, 'catalog');
    final generation = _writeGeneration;
    final memory = _catalogMemory.remove(key);
    if (memory != null) {
      _catalogMemory[key] = memory;
      _touchMemory(key, catalog: true);
      return _resolveCachedCatalog(
        key,
        memory,
        refreshAfter: refreshAfter,
        staleWhileRevalidate: staleWhileRevalidate,
        loader: loader,
        generation: generation,
      );
    }

    final disk = await _readCatalogDisk(key);
    if (disk != null) {
      if (generation == _writeGeneration) _rememberCatalog(key, disk);
      return _resolveCachedCatalog(
        key,
        disk,
        refreshAfter: refreshAfter,
        staleWhileRevalidate: staleWhileRevalidate,
        loader: loader,
        generation: generation,
      );
    }
    return _loadCatalog(key, loader, generation);
  }

  Future<BookSourceChapterContent> _resolveCachedContent(
    String key,
    _CacheEntry<BookSourceChapterContent> cached, {
    required Duration refreshAfter,
    required bool staleWhileRevalidate,
    required Future<BookSourceChapterContent> Function() loader,
    required int generation,
  }) async {
    if (_looksLikeLegacyImageCache(cached.value)) {
      // Versions before 2.6.1 persisted image chapter HTML without its parsed
      // image metadata. Do not keep presenting those entries as zero-page
      // chapters for up to 12 hours; repair them from the source immediately.
      return _loadContent(key, loader, generation);
    }
    if (DateTime.now().difference(cached.cachedAt) < refreshAfter) {
      return cached.value;
    }
    if (!staleWhileRevalidate) return _loadContent(key, loader, generation);
    unawaited(_refreshContent(key, loader, generation));
    return cached.value;
  }

  Future<void> _refreshContent(
    String key,
    Future<BookSourceChapterContent> Function() loader,
    int generation,
  ) async {
    try {
      await _loadContent(key, loader, generation);
    } catch (_) {
      // Previously read content remains usable while the source is offline.
    }
  }

  bool _looksLikeLegacyImageCache(BookSourceChapterContent content) {
    if (content.images.isNotEmpty) return false;
    final html = content.content.toLowerCase();
    return RegExp(r'<(?:img|amp-img|source)\b').hasMatch(html) &&
        RegExp(
          r'''(?:src|data-src|data-original|data-original-src|data-lazy|data-lazy-src|data-url|data-image|data-srcset|srcset)\s*=''',
        ).hasMatch(html);
  }

  Future<BookSourceChapterContent> _loadContent(
    String key,
    Future<BookSourceChapterContent> Function() loader,
    int generation,
  ) async {
    if (generation != _writeGeneration) return loader();
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _fetchAndStoreContent(key, loader, generation);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    }
  }

  Future<BookSourceChapterContent> _fetchAndStoreContent(
    String key,
    Future<BookSourceChapterContent> Function() loader,
    int generation,
  ) async {
    final content = await loader();
    if (generation != _writeGeneration) return content;
    _remember(
      key,
      _CacheEntry(
        content,
        DateTime.now(),
        sizeBytes: utf8.encode(_chapterJson(content)).length,
      ),
    );
    _scheduleDiskWrite(
      'chapter',
      key,
      generation,
      (generation) => _writeDisk(key, content, generation),
    );
    return content;
  }

  void _scheduleDiskWrite(
    String scope,
    String key,
    int generation,
    Future<void> Function(int generation) writer,
  ) {
    final root = cacheDirectory?.absolute.path ?? '<default-cache-root>';
    final queueKey = '$root:$scope:$key';
    final previous = _diskWriteQueues[queueKey] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) => writer(generation)).whenComplete(() {
      if (identical(_diskWriteQueues[queueKey], next)) {
        _diskWriteQueues.remove(queueKey);
      }
    });
    _diskWriteQueues[queueKey] = next;
    unawaited(next);
  }

  void _remember(String key, _CacheEntry<BookSourceChapterContent> content) {
    final replaced = _memory.remove(key);
    if (replaced != null) _memoryBytes -= replaced.sizeBytes;
    _memory[key] = content;
    _memoryBytes += content.sizeBytes;
    _touchMemory(key, catalog: false);
    while (_memory.length > _memoryLimit) {
      _evictOldest(catalog: false);
    }
    _enforceMemoryBytes();
  }

  Future<_CacheEntry<BookSourceChapterContent>?> _readDisk(String key) async {
    try {
      await beforeDiskRead?.call();
      final file = await _chapterFileFor(key);
      if (!await file.exists()) return null;
      final budget = await _diskBudget();
      if (await budget.isExpired(file)) {
        await file.delete();
        return null;
      }
      final cachedAt = await file.lastModified();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final entry = _CacheEntry(
        BookSourceChapterContent.fromJson(
          decoded.map((key, value) => MapEntry('$key', value)),
        ),
        cachedAt,
        sizeBytes: await file.length(),
      );
      unawaited(budget.touch(file));
      unawaited(budget.maintain().catchError((_) {}));
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(
    String key,
    BookSourceChapterContent content,
    int generation,
  ) async {
    try {
      await beforeDiskWrite?.call();
      if (generation != _writeGeneration) return;
      final file = await _chapterFileFor(key);
      await _writeJsonAtomically(file, _chapterJson(content), generation);
      if (generation == _writeGeneration) {
        await (await _diskBudget()).recordWrite(
          utf8.encode(_chapterJson(content)).length,
        );
      }
    } catch (_) {
      // Cache failures must never interrupt reading.
    }
  }

  Future<List<BookSourceChapter>> _resolveCachedCatalog(
    String key,
    _CacheEntry<List<BookSourceChapter>> cached, {
    required Duration refreshAfter,
    required bool staleWhileRevalidate,
    required Future<List<BookSourceChapter>> Function() loader,
    required int generation,
  }) async {
    if (DateTime.now().difference(cached.cachedAt) < refreshAfter) {
      return cached.value;
    }
    if (!staleWhileRevalidate) return _loadCatalog(key, loader, generation);
    unawaited(_refreshCatalog(key, loader, generation));
    return cached.value;
  }

  Future<void> _refreshCatalog(
    String key,
    Future<List<BookSourceChapter>> Function() loader,
    int generation,
  ) async {
    try {
      await _loadCatalog(key, loader, generation);
    } catch (_) {
      // A stale catalog remains useful while a source is slow or offline.
    }
  }

  Future<List<BookSourceChapter>> _loadCatalog(
    String key,
    Future<List<BookSourceChapter>> Function() loader,
    int generation,
  ) async {
    if (generation != _writeGeneration) return loader();
    final pending = _catalogInFlight[key];
    if (pending != null) return pending;
    final future = _fetchAndStoreCatalog(key, loader, generation);
    _catalogInFlight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_catalogInFlight[key], future)) {
        _catalogInFlight.remove(key);
      }
    }
  }

  Future<List<BookSourceChapter>> _fetchAndStoreCatalog(
    String key,
    Future<List<BookSourceChapter>> Function() loader,
    int generation,
  ) async {
    final chapters = List<BookSourceChapter>.unmodifiable(await loader());
    if (generation != _writeGeneration) return chapters;
    final entry = _CacheEntry(
      chapters,
      DateTime.now(),
      sizeBytes: utf8.encode(_catalogJson(chapters)).length,
    );
    _rememberCatalog(key, entry);
    _scheduleDiskWrite(
      'catalog',
      key,
      generation,
      (generation) => _writeCatalogDisk(key, entry, generation),
    );
    return chapters;
  }

  void _rememberCatalog(
    String key,
    _CacheEntry<List<BookSourceChapter>> catalog,
  ) {
    final replaced = _catalogMemory.remove(key);
    if (replaced != null) _memoryBytes -= replaced.sizeBytes;
    _catalogMemory[key] = catalog;
    _memoryBytes += catalog.sizeBytes;
    _touchMemory(key, catalog: true);
    while (_catalogMemory.length > _catalogMemoryLimit) {
      _evictOldest(catalog: true);
    }
    _enforceMemoryBytes();
  }

  Future<_CacheEntry<List<BookSourceChapter>>?> _readCatalogDisk(
    String key,
  ) async {
    try {
      await beforeDiskRead?.call();
      final file = await _catalogFileFor(key);
      if (!await file.exists()) return null;
      final budget = await _diskBudget();
      if (await budget.isExpired(file)) {
        await file.delete();
        return null;
      }
      final cachedAt = await file.lastModified();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['items'] is! List) return null;
      final chapters = (decoded['items'] as List)
          .map(
            (item) => BookSourceChapter.fromJson(
              (item as Map).map((key, value) => MapEntry('$key', value)),
            ),
          )
          .toList(growable: false);
      unawaited(budget.touch(file));
      unawaited(budget.maintain().catchError((_) {}));
      return _CacheEntry(
        List.unmodifiable(chapters),
        cachedAt,
        sizeBytes: await file.length(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCatalogDisk(
    String key,
    _CacheEntry<List<BookSourceChapter>> catalog,
    int generation,
  ) async {
    try {
      await beforeDiskWrite?.call();
      if (generation != _writeGeneration) return;
      final file = await _catalogFileFor(key);
      final contents = _catalogJson(catalog.value);
      await _writeJsonAtomically(file, contents, generation);
      if (generation == _writeGeneration) {
        await (await _diskBudget()).recordWrite(utf8.encode(contents).length);
      }
    } catch (_) {
      // Cache failures must never interrupt reading.
    }
  }

  Future<void> _writeJsonAtomically(
    File file,
    String contents,
    int generation,
  ) async {
    if (generation != _writeGeneration) return;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$generation');
    await temporary.writeAsString(contents, flush: true);
    if (generation != _writeGeneration) {
      if (await temporary.exists()) await temporary.delete();
      return;
    }
    if (await file.exists()) {
      if (generation != _writeGeneration) {
        if (await temporary.exists()) await temporary.delete();
        return;
      }
      await file.delete();
    }
    if (generation != _writeGeneration) {
      if (await temporary.exists()) await temporary.delete();
      return;
    }
    await temporary.rename(file.path);
    if (generation != _writeGeneration && await file.exists()) {
      await file.delete();
    }
  }

  Future<Directory> _rootDirectory() async {
    final configuredDirectory = cacheDirectory;
    if (configuredDirectory != null) return configuredDirectory;
    final temp = await getTemporaryDirectory();
    return Directory(path.join(temp.path, directoryName));
  }

  Future<CacheDiskBudget> _diskBudget() async => CacheDiskBudget(
    directory: await _rootDirectory(),
    maxBytes: maxDiskBytes,
    maxAge: chapterDiskLifetime,
    maintenanceInterval: diskMaintenanceInterval,
  );

  Future<void> maintainDisk({bool force = false}) async =>
      (await _diskBudget()).maintain(force: force);

  Future<int> diskSizeBytes() async => (await _diskBudget()).sizeBytes();

  Future<File> _chapterFileFor(String key) async {
    final root = await _rootDirectory();
    return File(path.join(root.path, '${_hash(key)}.json'));
  }

  Future<File> _catalogFileFor(String key) async {
    final root = await _rootDirectory();
    return File(path.join(root.path, 'catalogs', '${_hash(key)}.json'));
  }

  String _key(
    String sourceId,
    String sourceRevision,
    String bookId,
    String chapterId,
  ) =>
      '${cacheDirectory?.absolute.path ?? 'default'}\u0000'
      '$sourceId\u0000$sourceRevision\u0000$bookId\u0000$chapterId';

  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  String _chapterJson(BookSourceChapterContent content) => jsonEncode({
    'bookId': content.bookId,
    'chapterId': content.chapterId,
    'title': content.title,
    'content': content.content,
    'contentType': content.contentType,
    if (content.images.isNotEmpty)
      'images': [for (final image in content.images) image.toJson()],
  });

  String _catalogJson(List<BookSourceChapter> chapters) => jsonEncode({
    'items': [
      for (final chapter in chapters)
        {
          'id': chapter.id,
          'title': chapter.title,
          'order': chapter.order,
          if (chapter.updatedAt != null)
            'updatedAt': chapter.updatedAt!.toIso8601String(),
        },
    ],
  });

  void _touchMemory(String key, {required bool catalog}) {
    _memoryOrder.remove(key);
    _memoryOrder[key] = catalog;
  }

  void _evictOldest({bool? catalog}) {
    String? key;
    for (final entry in _memoryOrder.entries) {
      if (catalog == null || entry.value == catalog) {
        key = entry.key;
        break;
      }
    }
    if (key == null) return;
    final isCatalog = _memoryOrder.remove(key)!;
    final removed = isCatalog
        ? _catalogMemory.remove(key)
        : _memory.remove(key);
    if (removed != null) _memoryBytes -= removed.sizeBytes;
  }

  void _enforceMemoryBytes() {
    while (_memoryBytes > maxMemoryBytes && _memoryOrder.isNotEmpty) {
      _evictOldest();
    }
  }
}

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.cachedAt, {this.sizeBytes = 0});

  final T value;
  final DateTime cachedAt;
  final int sizeBytes;
}
