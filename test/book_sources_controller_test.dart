import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';

void main() {
  test('state freezes nested source and channel collections', () {
    final source = _source('source');
    final category = SourcedBookCategory(
      source: source,
      id: 'category',
      name: 'Category',
    );
    final sectionSources = <BookSourcesSection, List<RegisteredBookSource>>{
      BookSourcesSection.categories: [source],
    };
    final channels = <String, List<SourcedBookCategory>>{
      source.id: [category],
    };

    final state = BookSourcesState(
      sectionSources: sectionSources,
      listChannelsBySource: channels,
    );
    sectionSources[BookSourcesSection.categories]!.clear();
    channels[source.id]!.clear();

    expect(state.sourcesFor(BookSourcesSection.categories), [source]);
    expect(state.listChannelsBySource[source.id], [category]);
    expect(
      () => state.sourcesFor(BookSourcesSection.categories).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => state.listChannelsBySource[source.id]!.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'indexes capabilities and scopes large libraries before fetching',
    () async {
      final sources = List.generate(
        41,
        (index) => _source('source-$index'),
        growable: false,
      );
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
      );

      await controller.load();

      expect(controller.state.discoverySources, hasLength(41));
      expect(controller.state.selectedSourceId, 'source-0');
      expect(gateway.discoveryIds, ['source-0']);
      expect(controller.state.sourcesFor(BookSourcesSection.latest), sources);
      await controller.close();
    },
  );

  test(
    'listGroupsRevision bumps only on a real load or channel fetch, not on unrelated updates',
    () async {
      final sources = [_source('a'), _source('b')];
      final gateway = _ControllerGateway();
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
      );

      await controller.load();
      final afterLoad = controller.state.listGroupsRevision;
      expect(afterLoad, greaterThan(0));

      // Memoized callers (the discover list view) key their cache on this
      // revision, so an unrelated state change — like typing into the
      // source search box — must leave it untouched, or the whole point of
      // memoizing is defeated.
      controller.setListSourceQuery('a');
      expect(controller.state.listGroupsRevision, afterLoad);

      final group = BookSourceListChannels(
        source: sources.first,
        channels: const [],
      );
      await controller.expandListSource(group);
      expect(controller.state.listGroupsRevision, greaterThan(afterLoad));

      await controller.close();
    },
  );

  test(
    'bounds concurrent source requests and preserves partial results',
    () async {
      final sources = List.generate(
        20,
        (index) => _source('source-$index'),
        growable: false,
      );
      final gateway = _ControllerGateway(failingIds: {'source-3'});
      final controller = BookSourcesController(
        gateway: gateway,
        registry: _FakeRegistry.completed(sources),
        largeSourceLibraryThreshold: 100,
      );

      await controller.load();

      final cache = controller.state.caches[BookSourcesSection.recommended]!;
      expect(cache.error, isNull);
      expect(cache.shelves, hasLength(19));
      expect(gateway.maxActive, lessThanOrEqualTo(8));
      await controller.close();
    },
  );

  test('stale registry loads cannot replace a newer reload', () async {
    final first = Completer<List<RegisteredBookSource>>();
    final second = Completer<List<RegisteredBookSource>>();
    final registry = _FakeRegistry([first.future, second.future]);
    final controller = BookSourcesController(
      gateway: _ControllerGateway(),
      registry: registry,
    );

    final initialLoad = controller.load();
    final reload = controller.reload();
    second.complete([_source('new')]);
    await reload;
    first.complete([_source('old')]);
    await initialLoad;

    expect(controller.state.sources.single.id, 'new');
    await controller.close();
  });

  test('stale section completion cannot replace the active section', () async {
    final source = _source('source');
    final discovery = Completer<BookSourceDiscoveryPage>();
    final gateway = _ControllerGateway(discoveryResults: [discovery.future]);
    final controller = BookSourcesController(
      gateway: gateway,
      registry: _FakeRegistry.completed([source]),
    );

    final initialLoad = controller.load();
    while (gateway.discoveryIds.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.changeSection(BookSourcesSection.categories);
    discovery.complete(
      BookSourceDiscoveryPage(
        sections: [
          BookSourceDiscoverySection(
            id: 'late',
            title: 'Late',
            items: [_book('late')],
          ),
        ],
      ),
    );
    await initialLoad;

    expect(controller.state.section, BookSourcesSection.categories);
    expect(controller.state.caches[BookSourcesSection.recommended], isNull);
    await controller.close();
  });

  test('stale category completion is ignored', () async {
    final source = _source('source');
    final first = Completer<BookSourceSearchPage>();
    final second = Completer<BookSourceSearchPage>();
    final gateway = _ControllerGateway(
      browseResults: [first.future, second.future],
    );
    final controller = BookSourcesController(gateway: gateway);
    final categoryA = SourcedBookCategory(source: source, id: 'a', name: 'A');
    final categoryB = SourcedBookCategory(source: source, id: 'b', name: 'B');

    final loadA = controller.selectCategory(categoryA);
    final loadB = controller.selectCategory(categoryB);
    second.complete(_page([_book('b')]));
    await loadB;
    first.complete(_page([_book('a')]));
    await loadA;

    expect(controller.state.selectedCategory, categoryB);
    expect(controller.state.categoryBooks.single.book.id, 'b');
    await controller.close();
  });

  test('category paging retries and deduplicates appended books', () async {
    final source = _source('source');
    final gateway = _ControllerGateway(
      browseResults: [
        Future.value(_page([_book('a')], hasMore: true)),
        Future.error(StateError('temporary')),
        Future.value(_page([_book('a'), _book('b')], page: 2)),
      ],
    );
    final controller = BookSourcesController(gateway: gateway);
    final category = SourcedBookCategory(
      source: source,
      id: 'category',
      name: 'Category',
    );

    await controller.selectCategory(category);
    await controller.loadMoreCategory();
    expect(controller.state.categoryLoadMoreFailed, isTrue);
    await controller.loadMoreCategory();

    expect(controller.state.categoryBooks.map((item) => item.book.id), [
      'a',
      'b',
    ]);
    expect(controller.state.categoryLoadMoreFailed, isFalse);
    await controller.close();
  });

  test(
    'close cancels registry changes and suppresses late load completion',
    () async {
      final load = Completer<List<RegisteredBookSource>>();
      final registry = _FakeRegistry([load.future]);
      final controller = BookSourcesController(
        gateway: _ControllerGateway(),
        registry: registry,
      );

      final pending = controller.load();
      await controller.close();
      await controller.close();
      load.complete([_source('late')]);
      await pending;

      expect(registry.cancelCount, 1);
      expect(controller.state.sources, isEmpty);
    },
  );
}

class _FakeRegistry extends BookSourceRegistry {
  _FakeRegistry(this.loads) {
    _changes = StreamController<void>.broadcast(onCancel: () => cancelCount++);
  }

  _FakeRegistry.completed(List<RegisteredBookSource> sources)
    : this([Future.value(sources)]);

  final List<Future<List<RegisteredBookSource>>> loads;
  late final StreamController<void> _changes;
  int _loadIndex = 0;
  int cancelCount = 0;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<RegisteredBookSource>> loadRunnableInBackground() =>
      loads[_loadIndex++];
}

class _ControllerGateway extends BookSourceClient {
  _ControllerGateway({
    this.failingIds = const {},
    this.discoveryResults = const [],
    this.browseResults = const [],
  });

  final Set<String> failingIds;
  final List<Future<BookSourceDiscoveryPage>> discoveryResults;
  final List<Future<BookSourceSearchPage>> browseResults;
  final List<String> discoveryIds = [];
  int _browseIndex = 0;
  int _discoveryIndex = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source,
  ) async {
    discoveryIds.add(source.id);
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
    if (failingIds.contains(source.id)) throw StateError('failed');
    if (discoveryResults.isNotEmpty) {
      return discoveryResults[_discoveryIndex++];
    }
    return BookSourceDiscoveryPage(
      sections: [
        BookSourceDiscoverySection(
          id: source.id,
          title: source.id,
          items: [_book(source.id)],
        ),
      ],
    );
  }

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
  ) async => [const BookSourceCategory(id: 'category', name: 'Category')];

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) {
    if (browseResults.isNotEmpty) return browseResults[_browseIndex++];
    return Future.value(_page([_book('${source.id}-$page')]));
  }
}

RegisteredBookSource _source(String id) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://example.org/$id/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/$id/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'discover', 'categories', 'browse'},
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 9),
);

BookSourceBook _book(String id) => BookSourceBook(
  id: id,
  title: id,
  author: 'Author',
  description: '',
  categories: const [],
);

BookSourceSearchPage _page(
  List<BookSourceBook> items, {
  int page = 1,
  bool hasMore = false,
}) => BookSourceSearchPage(
  items: items,
  page: page,
  pageSize: items.length,
  total: items.length,
  hasMore: hasMore,
);
