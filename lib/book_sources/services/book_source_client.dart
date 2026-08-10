import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../protocol/orsp/orsp_book_source_backend.dart';
import '../source_engine/source_login_ui.dart';
import 'book_download_cancellation.dart';
import 'book_source_chapter_cache.dart';
import 'book_source_client_resources.dart';
import 'book_source_gateway.dart';
import 'book_source_network_policy.dart';
import 'book_source_response_cache.dart';

export 'book_source_gateway.dart' show BookSourceGateway, DiscoveredBookSource;

class BookSourceClient implements BookSourceGateway {
  BookSourceClient({
    Dio? dio,
    Dio? systemDio,
    BookSourceChapterCache? chapterCache,
    BookSourceResponseCache? responseCache,
    BookSourceNetworkPolicy networkPolicy = const BookSourceNetworkPolicy(
      allowSyntheticDns: true,
    ),
  }) : this._(
         BookSourceClientResources.create(
           dio: dio,
           systemDio: systemDio,
           chapterCache: chapterCache,
           responseCache: responseCache,
           networkPolicy: networkPolicy,
         ),
       );

  BookSourceClient._(this._resources);

  @visibleForTesting
  BookSourceClient.withResources(this._resources);

  final BookSourceClientResources _resources;

  static const int maxResponseBytes = 8 * 1024 * 1024;
  static const int maxDownloadResponseBytes = 24 * 1024 * 1024;
  static const Duration downloadReceiveTimeout = Duration(seconds: 90);
  static const Duration discoveryCacheTtl = Duration(hours: 1);
  static const Duration categoriesCacheTtl = Duration(minutes: 30);
  static const Duration browseCacheTtl = Duration(minutes: 5);
  static const Duration searchCacheTtl = Duration(minutes: 2);
  static const Duration bookDetailCacheTtl = Duration(minutes: 10);

  void close({bool force = true}) => _resources.close(force: force);

  @override
  Future<List<SourceLoginField>> loadLoginFields(RegisteredBookSource source) =>
      _resources.readingBackend.loadLoginFields(source);

  @override
  Future<void> loginSource(
    RegisteredBookSource source,
    Map<String, String> values,
  ) => _resources.readingBackend.loginSource(source, values);

  @override
  Future<void> clearSourceLogin(RegisteredBookSource source) =>
      _resources.readingBackend.clearSourceLogin(source);

  static void ensureSafeTarget(Uri uri) {
    final address = InternetAddress.tryParse(uri.host);
    if (address != null && BookSourceNetworkPolicy.isBlockedAddress(address)) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
  }

  static Uri normalizeManifestUri(String input) =>
      OrspBookSourceBackend.normalizeManifestUri(input);

  @override
  Future<DiscoveredBookSource> discover(String input) =>
      _resources.orspBackend.discover(input);

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.search(
        source,
        query,
        page: page,
        pageSize: pageSize,
        cancellation: cancellation,
      );
    }
    return _resources.orspBackend.search(
      source,
      query,
      page: page,
      pageSize: pageSize,
      cancellation: cancellation,
    );
  }

  @override
  Future<BookSourceDiscoveryPage> getDiscovery(RegisteredBookSource source) =>
      _resources.orspBackend.getDiscovery(source);

  @override
  Future<List<BookSourceCategory>> getCategories(RegisteredBookSource source) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.getCategories(source);
    }
    return _resources.orspBackend.getCategories(source);
  }

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.browse(
        source,
        category: category,
        page: page,
        pageSize: pageSize,
      );
    }
    return _resources.orspBackend.browse(
      source,
      category: category,
      sort: sort,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.getBook(
        source,
        bookId,
        sourceVariables: sourceVariables,
      );
    }
    return _resources.orspBackend.getBook(source, bookId);
  }

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.getChapters(
        source,
        bookId,
        sourceVariables: sourceVariables,
      );
    }
    return _resources.orspBackend.getChapters(source, bookId);
  }

  @override
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.getChaptersForDownload(
        source,
        bookId,
        sourceVariables: sourceVariables,
        cancellation: cancellation,
      );
    }
    return _resources.orspBackend.getChaptersForDownload(
      source,
      bookId,
      cancellation: cancellation,
    );
  }

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.getChapterContent(
        source,
        bookId: bookId,
        chapterId: chapterId,
        sourceVariables: sourceVariables,
      );
    }
    return _resources.orspBackend.getChapterContent(
      source,
      bookId: bookId,
      chapterId: chapterId,
    );
  }

  @override
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) {
    if (source.sourceProtocol == BookSourceProtocolKind.readingSource) {
      return _resources.readingBackend.getChapterContentForDownload(
        source,
        bookId: bookId,
        chapterId: chapterId,
        sourceVariables: sourceVariables,
        cancellation: cancellation,
      );
    }
    return _resources.orspBackend.getChapterContentForDownload(
      source,
      bookId: bookId,
      chapterId: chapterId,
      cancellation: cancellation,
    );
  }

  @override
  Future<void> prefetchChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    try {
      await getChapterContent(
        source,
        bookId: bookId,
        chapterId: chapterId,
        sourceVariables: sourceVariables,
      );
    } catch (_) {
      // Prefetching is opportunistic and must not surface reader errors.
    }
  }

  @override
  Future<void> invalidateResponseCache(RegisteredBookSource source) {
    if (source.sourceProtocol != BookSourceProtocolKind.orsp) {
      return Future<void>.value();
    }
    return _resources.orspBackend.invalidateResponseCache(source);
  }

  @override
  Future<void> invalidateResponseCaches(
    Iterable<RegisteredBookSource> sources,
  ) => _resources.orspBackend.invalidateResponseCaches(
    sources.where(
      (source) => source.sourceProtocol == BookSourceProtocolKind.orsp,
    ),
  );

  @override
  Future<void> invalidateDiscoveryResponseCache(String input) =>
      _resources.orspBackend.invalidateDiscoveryResponseCache(input);
}

int compareBookSourceChapters(BookSourceChapter left, BookSourceChapter right) {
  final order = left.order.compareTo(right.order);
  return order != 0 ? order : left.id.compareTo(right.id);
}
