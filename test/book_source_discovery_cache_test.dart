import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/caching/book_source_discovery_cache.dart';
import 'package:xxread/book_sources/caching/book_source_response_cache.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';

void main() {
  test('keeps reading-source payloads out of persistent storage', () async {
    final responseCache = _RecordingDiscoveryResponseCache();
    final cache = BookSourceDiscoveryCache(responseCache: responseCache);

    await cache.browse(
      _source(
        id: 'private-source',
        protocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {'bookSourceType': 2},
      ),
      category: null,
      sort: 'latest',
      page: 1,
      pageSize: 20,
      loader: () async => const BookSourceSearchPage(
        items: [],
        page: 1,
        pageSize: 20,
        hasMore: false,
      ),
    );
    await cache.browse(
      _source(id: 'public-source'),
      category: null,
      sort: 'latest',
      page: 1,
      pageSize: 20,
      loader: () async => const BookSourceSearchPage(
        items: [],
        page: 1,
        pageSize: 20,
        hasMore: false,
      ),
    );

    expect(responseCache.persistToDiskValues, [isFalse, isTrue]);
  });

  test(
    'caches reading-source comic browse results and preserves media data',
    () async {
      final responseCache = BookSourceResponseCache();
      final cache = BookSourceDiscoveryCache(responseCache: responseCache);
      final source = _source(
        id: 'comic-source',
        protocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {'bookSourceType': 2},
      );
      var loads = 0;

      Future<BookSourceSearchPage> load() async {
        loads++;
        return BookSourceSearchPage(
          items: [
            BookSourceBook(
              id: 'comic',
              title: 'Comic',
              author: 'Author',
              description: '',
              type: 64,
              coverUrl: Uri.parse('https://example.org/comic.jpg'),
              coverHeaders: const {'Referer': 'https://example.org/'},
              categories: const ['manga'],
              sourceVariables: const {'token': 'value'},
            ),
          ],
          page: 1,
          pageSize: 20,
          hasMore: false,
        );
      }

      final first = await cache.browse(
        source,
        category: 'manga',
        sort: 'popular',
        page: 1,
        pageSize: 20,
        loader: load,
      );
      final second = await cache.browse(
        source,
        category: 'manga',
        sort: 'popular',
        page: 1,
        pageSize: 20,
        loader: load,
      );

      expect(loads, 1);
      expect(second.items.single.type, 64);
      expect(second.items.single.coverHeaders, {
        'Referer': 'https://example.org/',
      });
      expect(second.items.single.sourceVariables, {'token': 'value'});
      expect(second.items.single.coverUrl, first.items.single.coverUrl);
    },
  );

  test(
    'separates operations and parameters and invalidates one source',
    () async {
      final responseCache = BookSourceResponseCache();
      final cache = BookSourceDiscoveryCache(responseCache: responseCache);
      final source = _source(id: 'source');
      var categoryLoads = 0;
      var browseLoads = 0;

      Future<List<BookSourceCategory>> categories() async {
        categoryLoads++;
        return const [BookSourceCategory(id: 'all', name: 'All')];
      }

      Future<BookSourceSearchPage> browse() async {
        browseLoads++;
        return const BookSourceSearchPage(
          items: [],
          page: 1,
          pageSize: 20,
          hasMore: false,
        );
      }

      await cache.getCategories(source, categories);
      await cache.getCategories(source, categories);
      await cache.browse(
        source,
        category: 'a',
        sort: 'latest',
        page: 1,
        pageSize: 20,
        loader: browse,
      );
      await cache.browse(
        source,
        category: 'b',
        sort: 'latest',
        page: 1,
        pageSize: 20,
        loader: browse,
      );

      expect(categoryLoads, 1);
      expect(browseLoads, 2);

      await cache.invalidateSource(source);
      await cache.getCategories(source, categories);
      expect(categoryLoads, 2);
    },
  );

  test(
    'source configuration revision prevents stale cross-version reuse',
    () async {
      final cache = BookSourceDiscoveryCache(
        responseCache: BookSourceResponseCache(),
      );
      final original = _source(
        id: 'source',
        protocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {'exploreUrl': '/old'},
      );
      final updated = _source(
        id: 'source',
        protocol: BookSourceProtocolKind.readingSource,
        sourceConfig: const {'exploreUrl': '/new'},
      );
      var loads = 0;

      Future<List<BookSourceCategory>> load() async {
        loads++;
        return [BookSourceCategory(id: '$loads', name: 'Category $loads')];
      }

      expect((await cache.getCategories(original, load)).single.id, '1');
      expect((await cache.getCategories(updated, load)).single.id, '2');
      expect(loads, 2);
    },
  );
}

class _RecordingDiscoveryResponseCache extends BookSourceResponseCache {
  final List<bool> persistToDiskValues = <bool>[];

  @override
  Future<Map<String, dynamic>> getOrLoadJson({
    required String key,
    required Duration ttl,
    required Future<Map<String, dynamic>> Function() loader,
    bool forceRefresh = false,
    bool deduplicateInFlight = true,
    bool persistToDisk = true,
  }) async {
    persistToDiskValues.add(persistToDisk);
    return loader();
  }
}

RegisteredBookSource _source({
  required String id,
  BookSourceProtocolKind protocol = BookSourceProtocolKind.orsp,
  Map<String, dynamic>? sourceConfig,
}) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://example.org/$id/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/$id/api/'),
  protocolVersion: protocol == BookSourceProtocolKind.orsp
      ? '1.5'
      : 'reading-source-1',
  languages: const [],
  capabilities: const {'categories', 'browse'},
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 10),
  sourceProtocol: protocol,
  sourceConfig: sourceConfig,
);
