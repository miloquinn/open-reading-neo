import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_response_cache.dart';

/// Protocol-independent cache for content shown on the discovery page.
///
/// Both ORSP sources and compatible reading/comic sources pass through this
/// layer. Cached values use protocol DTO JSON rather than runtime-specific
/// response objects, so source type (including comic type 64), cover headers,
/// and source variables survive memory and disk persistence consistently.
class BookSourceDiscoveryCache {
  BookSourceDiscoveryCache({
    BookSourceResponseCache? responseCache,
    this.discoveryTtl = const Duration(hours: 1),
    this.categoriesTtl = const Duration(minutes: 30),
    this.browseTtl = const Duration(minutes: 5),
  }) : _responseCache = responseCache ?? BookSourceResponseCache.instance;

  static const int schemaVersion = 1;
  static const String _namespace = 'discovery-page-v$schemaVersion|';

  final BookSourceResponseCache _responseCache;
  final Duration discoveryTtl;
  final Duration categoriesTtl;
  final Duration browseTtl;

  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source,
    Future<BookSourceDiscoveryPage> Function() loader,
  ) async {
    final json = await _responseCache.getOrLoadJson(
      key: _key(source, 'recommended'),
      ttl: discoveryTtl,
      loader: () async => _discoveryToJson(await loader()),
      persistToDisk: _mayPersistPayload(source),
    );
    return BookSourceDiscoveryPage.fromJson(json);
  }

  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
    Future<List<BookSourceCategory>> Function() loader,
  ) async {
    final json = await _responseCache.getOrLoadJson(
      key: _key(source, 'categories'),
      ttl: categoriesTtl,
      loader: () async => {
        'items': (await loader())
            .map((category) => {'id': category.id, 'name': category.name})
            .toList(growable: false),
      },
      persistToDisk: _mayPersistPayload(source),
    );
    final items = json['items'];
    if (items is! List) {
      throw const BookSourceProtocolException(
        'Cached discovery categories must contain an items array.',
      );
    }
    return items
        .map(
          (item) => BookSourceCategory.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList(growable: false);
  }

  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    required String? category,
    required String sort,
    required int page,
    required int pageSize,
    required Future<BookSourceSearchPage> Function() loader,
  }) async {
    final json = await _responseCache.getOrLoadJson(
      key: _key(source, 'browse', {
        'category': category ?? '',
        'sort': sort,
        'page': '$page',
        'pageSize': '$pageSize',
      }),
      ttl: browseTtl,
      loader: () async => _searchPageToJson(await loader()),
      persistToDisk: _mayPersistPayload(source),
    );
    return BookSourceSearchPage.fromJson(json);
  }

  Future<void> invalidateSource(RegisteredBookSource source) =>
      _responseCache.invalidatePrefix(_sourcePrefix(source.id));

  Future<void> invalidateSources(Iterable<RegisteredBookSource> sources) =>
      _responseCache.invalidatePrefixes(
        sources.map((source) => _sourcePrefix(source.id)),
      );

  /// Compatible reading sources may place authentication or transient script
  /// state in book `sourceVariables`. Keep those DTOs in memory only rather
  /// than serializing them into the shared plaintext response-cache directory.
  bool _mayPersistPayload(RegisteredBookSource source) =>
      source.sourceProtocol == BookSourceProtocolKind.orsp;

  String _key(
    RegisteredBookSource source,
    String operation, [
    Map<String, String> parameters = const {},
  ]) {
    final sorted = parameters.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final query = sorted
        .map(
          (entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
    return '${_sourcePrefix(source.id)}${_sourceRevision(source)}|$operation|$query';
  }

  static String _sourcePrefix(String sourceId) =>
      '$_namespace${Uri.encodeComponent(sourceId)}|';

  static String _sourceRevision(RegisteredBookSource source) {
    final stable = _stableJson(source.toJson());
    return sha256.convert(utf8.encode(jsonEncode(stable))).toString();
  }
}

Map<String, dynamic> _discoveryToJson(BookSourceDiscoveryPage page) => {
  'sections': page.sections
      .map(
        (section) => {
          'id': section.id,
          'title': section.title,
          'items': section.items.map((book) => book.toJson()).toList(),
        },
      )
      .toList(growable: false),
};

Map<String, dynamic> _searchPageToJson(BookSourceSearchPage page) => {
  'items': page.items.map((book) => book.toJson()).toList(growable: false),
  'page': page.page,
  'pageSize': page.pageSize,
  if (page.total != null) 'total': page.total,
  'hasMore': page.hasMore,
};

Object? _stableJson(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((left, right) => '${left.key}'.compareTo('${right.key}'));
    return <String, Object?>{
      for (final entry in entries) '${entry.key}': _stableJson(entry.value),
    };
  }
  if (value is Iterable) {
    return value.map(_stableJson).toList(growable: false);
  }
  return value;
}
