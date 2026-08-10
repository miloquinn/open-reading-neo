import 'package:dio/dio.dart';

import '../../models/registered_book_source.dart';
import '../../services/book_download_cancellation.dart';
import '../../services/book_source_chapter_cache.dart';
import '../../services/book_source_gateway.dart';
import '../book_source_protocol.dart';
import 'orsp_http_pipeline.dart';

abstract interface class OrspBookSourceBackendPort {
  Future<DiscoveredBookSource> discover(String input);
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  });
  Future<BookSourceDiscoveryPage> getDiscovery(RegisteredBookSource source);
  Future<List<BookSourceCategory>> getCategories(RegisteredBookSource source);
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  });
  Future<BookSourceBook> getBook(RegisteredBookSource source, String bookId);
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId,
  );
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    BookDownloadCancellation? cancellation,
  });
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
  });
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    BookDownloadCancellation? cancellation,
  });
  Future<void> invalidateResponseCache(RegisteredBookSource source);
  Future<void> invalidateResponseCaches(Iterable<RegisteredBookSource> sources);
  Future<void> invalidateDiscoveryResponseCache(String input);
}

class OrspBookSourceBackend implements OrspBookSourceBackendPort {
  OrspBookSourceBackend(this._pipeline, this._chapterCache);

  final OrspHttpPipeline _pipeline;
  final BookSourceChapterCache _chapterCache;

  static const Duration discoveryCacheTtl = Duration(hours: 1);
  static const Duration categoriesCacheTtl = Duration(minutes: 30);
  static const Duration browseCacheTtl = Duration(minutes: 5);
  static const Duration searchCacheTtl = Duration(minutes: 2);
  static const Duration bookDetailCacheTtl = Duration(minutes: 10);
  static const int _defaultChapterPageSize = 100;
  static const int _maxChapters = 30000;

  @override
  Future<DiscoveredBookSource> discover(String input) async {
    final manifestUrl = normalizeManifestUri(input);
    try {
      final json = await _pipeline.withRetries(
        () => _pipeline.cachedJson(
          key: OrspHttpPipeline.discoveryCacheKey(manifestUrl),
          ttl: discoveryCacheTtl,
          uri: manifestUrl,
          validate: BookSourceManifest.fromJson,
        ),
      );
      return DiscoveredBookSource(
        manifestUrl: manifestUrl,
        manifest: BookSourceManifest.fromJson(json),
      );
    } on DioException catch (error) {
      throw _pipeline.mapDioException(error);
    }
  }

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    if (!source.capabilities.contains('search')) {
      throw const BookSourceProtocolException(
        'This source does not support search.',
      );
    }
    final uri = OrspHttpPipeline.apiUri(source.apiBaseUrl, 'v1/search').replace(
      queryParameters: {
        'q': query.trim(),
        'page': '$page',
        'pageSize': '$pageSize',
      },
    );
    try {
      cancellation?.throwIfCancelled();
      final json = await _pipeline.cachedJson(
        key: OrspHttpPipeline.cacheKey(source, 'search', [
          query.trim(),
          '$page',
          '$pageSize',
        ]),
        ttl: searchCacheTtl,
        uri: uri,
        cancellation: cancellation,
        deduplicateInFlight: cancellation == null,
        persistToDisk: false,
        validate: (json) =>
            BookSourceSearchPage.fromJson(json, baseUri: source.apiBaseUrl),
      );
      cancellation?.throwIfCancelled();
      return BookSourceSearchPage.fromJson(json, baseUri: source.apiBaseUrl);
    } on DioException catch (error) {
      throw _pipeline.mapDioException(error);
    }
  }

  @override
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source,
  ) async {
    if (!source.capabilities.contains('discover')) {
      throw const BookSourceProtocolException(
        'This source does not support discovery.',
      );
    }
    final uri = OrspHttpPipeline.apiUri(source.apiBaseUrl, 'v1/discover');
    try {
      final json = await _pipeline.cachedJson(
        key: OrspHttpPipeline.cacheKey(source, 'discovery'),
        ttl: discoveryCacheTtl,
        uri: uri,
        validate: (json) =>
            BookSourceDiscoveryPage.fromJson(json, baseUri: source.apiBaseUrl),
      );
      return BookSourceDiscoveryPage.fromJson(json, baseUri: source.apiBaseUrl);
    } on DioException catch (error) {
      throw _pipeline.mapDioException(error);
    }
  }

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
  ) async {
    if (!source.capabilities.contains('categories')) {
      throw const BookSourceProtocolException(
        'This source does not support categories.',
      );
    }
    final uri = OrspHttpPipeline.apiUri(source.apiBaseUrl, 'v1/categories');
    try {
      final json = await _pipeline.cachedJson(
        key: OrspHttpPipeline.cacheKey(source, 'categories'),
        ttl: categoriesCacheTtl,
        uri: uri,
        validate: _validateCategoriesJson,
      );
      final items = json['items'];
      if (items is! List) {
        throw const BookSourceProtocolException(
          'Category response must contain an items array.',
        );
      }
      return items
          .map(
            (item) => BookSourceCategory.fromJson(decodeBookSourceJson(item)),
          )
          .toList(growable: false);
    } on DioException catch (error) {
      throw _pipeline.mapDioException(error);
    }
  }

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    if (!source.capabilities.contains('browse')) {
      throw const BookSourceProtocolException(
        'This source does not support browsing.',
      );
    }
    final uri = OrspHttpPipeline.apiUri(source.apiBaseUrl, 'v1/browse').replace(
      queryParameters: {
        if (category != null && category.trim().isNotEmpty)
          'category': category.trim(),
        'sort': sort,
        'page': '$page',
        'pageSize': '$pageSize',
      },
    );
    try {
      final json = await _pipeline.cachedJson(
        key: OrspHttpPipeline.cacheKey(source, 'browse', [
          category?.trim() ?? '',
          sort.trim(),
          '$page',
          '$pageSize',
        ]),
        ttl: browseCacheTtl,
        uri: uri,
        validate: (json) =>
            BookSourceSearchPage.fromJson(json, baseUri: source.apiBaseUrl),
      );
      return BookSourceSearchPage.fromJson(json, baseUri: source.apiBaseUrl);
    } on DioException catch (error) {
      throw _pipeline.mapDioException(error);
    }
  }

  @override
  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId,
  ) async {
    final uri = OrspHttpPipeline.apiUri(
      source.apiBaseUrl,
      'v1/books/${Uri.encodeComponent(bookId)}',
    );
    try {
      final json = await _pipeline.cachedJson(
        key: OrspHttpPipeline.cacheKey(source, 'book', [bookId]),
        ttl: bookDetailCacheTtl,
        uri: uri,
        validate: (json) {
          final book = BookSourceBook.fromJson(
            json,
            baseUri: source.apiBaseUrl,
          );
          if (book.id != bookId) {
            throw const BookSourceProtocolException(
              'Book detail response does not match the requested book.',
            );
          }
          return book;
        },
      );
      final book = BookSourceBook.fromJson(json, baseUri: source.apiBaseUrl);
      if (book.id != bookId) {
        throw const BookSourceProtocolException(
          'Book detail response does not match the requested book.',
        );
      }
      return book;
    } on DioException catch (error) {
      throw _pipeline.mapDioException(error);
    }
  }

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId,
  ) => _chapterCache.getChapterCatalogOrLoad(
    sourceId: source.id,
    sourceRevision: source.apiBaseUrl.toString(),
    bookId: bookId,
    loader: () => _fetchAllChapters(
      OrspHttpPipeline.apiUri(
        source.apiBaseUrl,
        'v1/books/${Uri.encodeComponent(bookId)}/chapters',
      ),
      pageSize: _chapterPageSizeFor(source),
      maxBytes: OrspHttpPipeline.maxResponseBytes,
      receiveTimeout: null,
    ),
  );

  @override
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    BookDownloadCancellation? cancellation,
  }) => _fetchAllChapters(
    OrspHttpPipeline.apiUri(
      source.apiBaseUrl,
      'v1/books/${Uri.encodeComponent(bookId)}/chapters',
    ),
    pageSize: _chapterPageSizeFor(source),
    maxBytes: OrspHttpPipeline.maxDownloadResponseBytes,
    receiveTimeout: OrspHttpPipeline.downloadReceiveTimeout,
    cancellation: cancellation,
  );

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
  }) => _chapterCache.getOrLoad(
    sourceId: source.id,
    sourceRevision: source.apiBaseUrl.toString(),
    bookId: bookId,
    chapterId: chapterId,
    loader: () async {
      final uri = _chapterUri(source, bookId, chapterId);
      try {
        final content = BookSourceChapterContent.fromJson(
          decodeBookSourceJson(await _pipeline.getBounded(uri)),
        );
        _validateChapterContentIdentity(content, bookId, chapterId);
        return content;
      } on DioException catch (error) {
        throw _pipeline.mapDioException(error);
      }
    },
  );

  @override
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final content = await _chapterCache.getOrLoad(
      sourceId: source.id,
      sourceRevision: source.apiBaseUrl.toString(),
      bookId: bookId,
      chapterId: chapterId,
      staleWhileRevalidate: false,
      loader: () => _pipeline.withRetries(() async {
        final content = BookSourceChapterContent.fromJson(
          decodeBookSourceJson(
            await _pipeline.getBounded(
              _chapterUri(source, bookId, chapterId),
              maxBytes: OrspHttpPipeline.maxDownloadResponseBytes,
              receiveTimeout: OrspHttpPipeline.downloadReceiveTimeout,
              cancellation: cancellation,
            ),
          ),
        );
        _validateChapterContentIdentity(content, bookId, chapterId);
        return content;
      }, cancellation: cancellation),
    );
    cancellation?.throwIfCancelled();
    return content;
  }

  @override
  Future<void> invalidateResponseCache(RegisteredBookSource source) =>
      _pipeline.invalidateSource(source);

  @override
  Future<void> invalidateResponseCaches(
    Iterable<RegisteredBookSource> sources,
  ) => _pipeline.invalidateSources(sources);

  @override
  Future<void> invalidateDiscoveryResponseCache(String input) =>
      _pipeline.invalidateDiscovery(normalizeManifestUri(input));

  static Uri normalizeManifestUri(String input) {
    final trimmed = input.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !parsed.hasAuthority ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Please enter a valid http or https URL.',
      );
    }
    if (parsed.path.endsWith('.json')) return parsed;
    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return parsed
        .replace(path: path, query: null, fragment: null)
        .resolve(openReadingSourceDiscoveryPath);
  }

  int _chapterPageSizeFor(RegisteredBookSource source) =>
      (source.maxCatalogPageSize ?? _defaultChapterPageSize).clamp(1, 1000);

  Future<List<BookSourceChapter>> _fetchAllChapters(
    Uri uri, {
    required int pageSize,
    required int maxBytes,
    required Duration? receiveTimeout,
    BookDownloadCancellation? cancellation,
  }) async {
    const maxPageRequests = 1000;
    final maxPages = ((_maxChapters / pageSize).ceil()).clamp(
      1,
      maxPageRequests,
    );
    final chapters = <BookSourceChapter>[];
    final chapterIds = <String>{};
    for (var page = 1; page <= maxPages; page++) {
      cancellation?.throwIfCancelled();
      final pageUri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'page': '$page',
          'pageSize': '$pageSize',
        },
      );
      final result = await _pipeline.withRetries(() async {
        final json = decodeBookSourceJson(
          await _pipeline.getBounded(
            pageUri,
            maxBytes: maxBytes,
            receiveTimeout: receiveTimeout,
            cancellation: cancellation,
          ),
        );
        return BookSourceChapterPage.fromJson(json);
      }, cancellation: cancellation);
      if (result.items.length > _maxChapters - chapters.length) {
        throw const BookSourceProtocolException(
          'Book source chapter catalog exceeds the supported limit.',
        );
      }
      for (final chapter in result.items) {
        if (!chapterIds.add(chapter.id)) {
          throw const BookSourceProtocolException(
            'Book source chapter catalog contains duplicate chapter IDs.',
          );
        }
        chapters.add(chapter);
      }
      if (chapters.length >= _maxChapters && result.hasMore) {
        throw const BookSourceProtocolException(
          'Book source chapter catalog exceeds the supported limit.',
        );
      }
      if (!result.hasMore || result.items.isEmpty) break;
      if (page == maxPages) {
        throw const BookSourceProtocolException(
          'Book source chapter catalog contains too many pages.',
        );
      }
    }
    chapters.sort(_compareChapters);
    return chapters;
  }

  static Object? _validateCategoriesJson(Map<String, dynamic> json) {
    final items = json['items'];
    if (items is! List) {
      throw const BookSourceProtocolException(
        'Category response must contain an items array.',
      );
    }
    for (final item in items) {
      BookSourceCategory.fromJson(decodeBookSourceJson(item));
    }
    return null;
  }

  static Uri _chapterUri(
    RegisteredBookSource source,
    String bookId,
    String chapterId,
  ) => OrspHttpPipeline.apiUri(
    source.apiBaseUrl,
    'v1/books/${Uri.encodeComponent(bookId)}/chapters/'
    '${Uri.encodeComponent(chapterId)}',
  );

  static void _validateChapterContentIdentity(
    BookSourceChapterContent content,
    String bookId,
    String chapterId,
  ) {
    if (content.bookId != bookId || content.chapterId != chapterId) {
      throw const BookSourceProtocolException(
        'Chapter response does not match the requested resource.',
      );
    }
  }
}

int _compareChapters(BookSourceChapter left, BookSourceChapter right) {
  final order = left.order.compareTo(right.order);
  return order != 0 ? order : left.id.compareTo(right.id);
}
