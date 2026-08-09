import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_sources_page.dart';
import 'package:xxread/pages/book_sources/source_search_page.dart';
import 'package:xxread/services/core/app_settings_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('discover page shows the empty-source call to action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: BookSourcesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No sources yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('discover page closes only factory-created source resources', (
    tester,
  ) async {
    final ownedClient = _CloseTrackingBookSourceClient();
    late final _CloseTrackingShelfService ownedShelf;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourcesPage(
          clientFactory: () => ownedClient,
          shelfServiceFactory: (client) {
            ownedShelf = _CloseTrackingShelfService(client);
            return ownedShelf;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );

    expect(ownedShelf.closeCount, 1);
    expect(ownedClient.closeCount, 1);

    final borrowedClient = _CloseTrackingBookSourceClient();
    final borrowedShelf = _CloseTrackingShelfService(borrowedClient);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourcesPage(
          client: borrowedClient,
          shelfService: borrowedShelf,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(borrowedShelf.closeCount, 0);
    expect(borrowedClient.closeCount, 0);
    borrowedShelf.close();
    borrowedClient.close();
  });

  testWidgets('search page closes only factory-created source resources', (
    tester,
  ) async {
    final ownedClient = _CloseTrackingBookSourceClient();
    late final _CloseTrackingShelfService ownedShelf;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: const [],
          clientFactory: () => ownedClient,
          shelfServiceFactory: (client) {
            ownedShelf = _CloseTrackingShelfService(client);
            return ownedShelf;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(ownedShelf.closeCount, 1);
    expect(ownedClient.closeCount, 1);

    final borrowedClient = _CloseTrackingBookSourceClient();
    final borrowedShelf = _CloseTrackingShelfService(borrowedClient);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: const [],
          client: borrowedClient,
          shelfService: borrowedShelf,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(borrowedShelf.closeCount, 0);
    expect(borrowedClient.closeCount, 0);
    borrowedShelf.close();
    borrowedClient.close();
  });

  testWidgets('search page focuses the query field and searches on submit', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final client = _PagingBookSourceClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [_source()],
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final queryField = find.byKey(const Key('bookSourceQueryControl'));
    expect(tester.widget<TextField>(queryField).focusNode?.hasFocus, isTrue);

    await tester.enterText(queryField, 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(client.requestedPages, isNotEmpty);
    expect(find.text('Book 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search settings sheet persists the concurrency change', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final client = _PagingBookSourceClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [_source()],
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bookSourceSearchSettingsButton')));
    await tester.pumpAndSettle();

    final concurrencySlider = find.byKey(
      const Key('bookSourceSearchConcurrencySlider'),
    );
    expect(concurrencySlider, findsOneWidget);
    expect(
      find.byKey(const Key('bookSourceSearchSourceLimitSlider')),
      findsOneWidget,
    );

    tester.widget<Slider>(concurrencySlider).onChanged!(4);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('book_source_search_concurrency_v1'), 4);
  });

  testWidgets('loads the next source page when search results reach the end', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final source = _source();
    SharedPreferences.setMockInitialValues({
      'open_reading_book_sources_v1': jsonEncode([source.toJson()]),
    });
    final client = _PagingBookSourceClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [source],
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final queryField = find.byKey(const Key('bookSourceQueryControl'));
    await tester.enterText(queryField, 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    if (client.requestedPages.length == 1) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
      await tester.pumpAndSettle();
    }

    expect(client.requestedPages, [1, 2]);
    // 第 11 本书在首屏之外，滚到底部让 Sliver 构建它再断言。搜索框改为带
    // 图标的圆角容器后头部更高，多滚一屏确保结果仍然可见。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1600));
    await tester.pumpAndSettle();
    expect(find.text('Book 11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear button resets search results', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final client = _PagingBookSourceClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [_source()],
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final queryField = find.byKey(const Key('bookSourceQueryControl'));
    await tester.enterText(queryField, 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Book 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('bookSourceSearchClearButton')));
    await tester.pumpAndSettle();

    expect(find.text('Book 1'), findsNothing);
    expect(tester.widget<TextField>(queryField).controller?.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scope chips switch between all sources and a single source', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final sourceA = _source();
    final sourceB = RegisteredBookSource(
      id: 'source-b',
      name: 'Source B',
      description: '',
      manifestUrl: Uri.parse('https://example.org/b/source.json'),
      apiBaseUrl: Uri.parse('https://example.org/b/api/'),
      protocolVersion: '1.1',
      languages: const ['en'],
      capabilities: const {'search'},
      enabled: true,
      addedAt: DateTime.utc(2026, 7, 13),
    );
    final client = _ScopeTrackingClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [sourceA, sourceB],
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 默认“全部”：两个书源都被请求。
    final queryField = find.byKey(const Key('bookSourceQueryControl'));
    await tester.enterText(queryField, 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(client.searchedSourceIds, ['source-a', 'source-b']);

    // 选中单个书源 Chip：自动用当前关键词只搜该书源。
    client.searchedSourceIds.clear();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Source B'));
    await tester.pumpAndSettle();
    expect(client.searchedSourceIds, ['source-b']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large source lists build scope chips lazily', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final sources = List.generate(
      600,
      (index) => _sourceWithId('large-$index', 'Large Source $index'),
      growable: false,
    );
    final client = _ScopeTrackingClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: sources,
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ChoiceChip).evaluate().length, lessThan(20));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'caps concurrent search targets when enabled sources exceed the limit',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.reset);

      final sources = List.generate(
        600,
        (index) => _sourceWithId('cap-$index', 'Cap Source $index'),
        growable: false,
      );
      final client = _ScopeTrackingClient();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SourceSearchPage(
            sources: sources,
            client: client,
            shelfService: BookSourceShelfService(client: client),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Warning banner shows up front, before a search even runs.
      expect(
        find.byKey(const Key('bookSourceSearchLimitBanner')),
        findsOneWidget,
      );

      final queryField = find.byKey(const Key('bookSourceQueryControl'));
      await tester.enterText(queryField, 'test');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      // Once a search starts, the banner gives way to results/progress.
      expect(
        find.byKey(const Key('bookSourceSearchLimitBanner')),
        findsNothing,
      );

      // Default limit is 300; only the first 300 sources (list order) run.
      expect(client.searchedSourceIds.length, 300);
      expect(client.searchedSourceIds, contains('cap-0'));
      expect(client.searchedSourceIds, contains('cap-299'));
      expect(client.searchedSourceIds, isNot(contains('cap-300')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all-source search uses bounded concurrency and streams results',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.reset);

      final sources = List.generate(
        10,
        (index) => _sourceWithId('progress-$index', 'Progress $index'),
        growable: false,
      );
      final client = _ProgressiveSearchClient();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SourceSearchPage(
            sources: sources,
            client: client,
            shelfService: BookSourceShelfService(client: client),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final queryField = find.byKey(const Key('bookSourceQueryControl'));
      await tester.enterText(queryField, 'test');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      expect(
        client.startedSourceIds,
        List.generate(8, (index) => 'progress-$index'),
      );
      expect(client.maxActive, 8);

      client.complete('progress-0');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(find.text('Book from Progress 0'), findsOneWidget);
      expect(find.text('1/10'), findsOneWidget);
      expect(client.startedSourceIds, contains('progress-8'));
      expect(client.maxActive, 8);

      for (var index = 1; index < sources.length; index++) {
        final sourceId = 'progress-$index';
        while (!client.startedSourceIds.contains(sourceId)) {
          await tester.pump(const Duration(milliseconds: 1));
        }
        client.complete(sourceId);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
      }
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();

      expect(find.text('Book from Progress 9'), findsOneWidget);
      expect(client.maxActive, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a timed-out source does not block the remaining sources', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);

    final client = _TimeoutSearchClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [
            _sourceWithId('slow', 'Slow'),
            _sourceWithId('fast', 'Fast'),
          ],
          client: client,
          shelfService: BookSourceShelfService(client: client),
          perSourceSearchTimeout: const Duration(milliseconds: 30),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final queryField = find.byKey(const Key('bookSourceQueryControl'));
    await tester.enterText(queryField, 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(client.startedSourceIds, ['slow', 'fast']);
    expect(find.text('Book from Fast'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpAndSettle();

    expect(client.slowWasCancelled, isTrue);
    expect(find.text('Book from Fast'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores an old search after changing source scope', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.reset);
    final sourceA = _source();
    final sourceB = RegisteredBookSource(
      id: 'source-b',
      name: 'Source B',
      description: '',
      manifestUrl: Uri.parse('https://example.org/b/source.json'),
      apiBaseUrl: Uri.parse('https://example.org/b/api/'),
      protocolVersion: '1.5',
      languages: const ['en'],
      capabilities: const {'search'},
      enabled: true,
      addedAt: DateTime.utc(2026, 7, 31),
    );
    final client = _DelayedScopeClient();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SourceSearchPage(
          sources: [sourceA, sourceB],
          client: client,
          shelfService: BookSourceShelfService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final queryField = find.byKey(const Key('bookSourceQueryControl'));
    await tester.enterText(queryField, 'test');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Source B'));
    await tester.pump();
    client.releaseSourceB();
    await tester.pump();
    client.releaseSourceA();
    await tester.pumpAndSettle();

    expect(find.text('Book of Source B'), findsOneWidget);
    expect(find.text('Book of Source A'), findsNothing);
  });

  testWidgets(
    'a more relevant result that arrives later moves above an earlier weak match',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.reset);

      final weakSource = _sourceWithId('weak-source', 'Weak Source');
      final strongSource = _sourceWithId('strong-source', 'Strong Source');
      final client = _RelevanceOrderClient();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SourceSearchPage(
            sources: [weakSource, strongSource],
            client: client,
            shelfService: BookSourceShelfService(client: client),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final queryField = find.byKey(const Key('bookSourceQueryControl'));
      await tester.enterText(queryField, 'Target');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();

      // The weak match (title does not contain the query at all) arrives first.
      client.releaseWeak();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Unrelated Novel'), findsOneWidget);
      expect(find.text('Target Book'), findsNothing);

      // The exact title match arrives later but should still land above it.
      client.releaseStrong();
      await tester.pumpAndSettle();

      expect(find.text('Target Book'), findsOneWidget);
      expect(find.text('Unrelated Novel'), findsOneWidget);
      final strongY = tester.getTopLeft(find.text('Target Book')).dy;
      final weakY = tester.getTopLeft(find.text('Unrelated Novel')).dy;
      expect(strongY, lessThan(weakY));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discover page selects a reading source, channel, and next page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.reset);
      final source = _readingDiscoverySource();
      SharedPreferences.setMockInitialValues({
        'open_reading_book_sources_v1': jsonEncode([source.toJson()]),
        additionalSourceProtocolsPreferenceKey: true,
      });
      final client = _DiscoveryBookSourceClient();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: BookSourcesPage(client: client)),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(ChoiceChip, 'reading source E'),
        findsOneWidget,
      );
      expect(find.text('Ranking'), findsOneWidget);
      expect(find.text('Channel Book 1'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'reading source E'));
      await tester.pumpAndSettle();

      expect(find.text('Ranking'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bookSourceCategoryLoadMore')));
      await tester.pumpAndSettle();

      expect(client.requestedPages, [1, 1, 2]);
      expect(find.text('Channel Book 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _CloseTrackingBookSourceClient extends BookSourceClient {
  int closeCount = 0;

  @override
  void close({bool force = true}) {
    closeCount++;
    super.close(force: force);
  }
}

class _CloseTrackingShelfService extends BookSourceShelfService {
  _CloseTrackingShelfService(BookSourceClient client) : super(client: client);

  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    super.close();
  }
}

class _DelayedScopeClient extends BookSourceClient {
  final _completers = <String, List<Completer<void>>>{};

  void releaseSourceA() => _release('source-a');
  void releaseSourceB() => _release('source-b');

  void _release(String id) {
    for (final completer in _completers[id] ?? const []) {
      if (!completer.isCompleted) completer.complete();
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
    final completer = Completer<void>();
    _completers.putIfAbsent(source.id, () => []).add(completer);
    await completer.future;
    return BookSourceSearchPage(
      items: [
        BookSourceBook(
          id: '${source.id}-book',
          title: 'Book of ${source.name}',
          author: 'Author',
          description: '',
          categories: const [],
        ),
      ],
      page: page,
      pageSize: pageSize,
      total: 1,
      hasMore: false,
    );
  }
}

class _RelevanceOrderClient extends BookSourceClient {
  final _weak = Completer<void>();
  final _strong = Completer<void>();

  void releaseWeak() => _weak.complete();
  void releaseStrong() => _strong.complete();

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    final String title;
    if (source.id == 'weak-source') {
      await _weak.future;
      title = 'Unrelated Novel';
    } else {
      await _strong.future;
      title = 'Target Book';
    }
    return BookSourceSearchPage(
      items: [
        BookSourceBook(
          id: '${source.id}-book',
          title: title,
          author: 'Author',
          description: '',
          categories: const [],
        ),
      ],
      page: page,
      pageSize: pageSize,
      total: 1,
      hasMore: false,
    );
  }
}

class _ScopeTrackingClient extends BookSourceClient {
  final List<String> searchedSourceIds = [];

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    searchedSourceIds.add(source.id);
    return BookSourceSearchPage(
      items: [
        BookSourceBook(
          id: '${source.id}-book',
          title: 'Book of ${source.name}',
          author: 'Author',
          description: '',
          categories: const [],
        ),
      ],
      page: page,
      pageSize: pageSize,
      total: 1,
      hasMore: false,
    );
  }
}

RegisteredBookSource _source() => RegisteredBookSource(
  id: 'source-a',
  name: 'Source A',
  description: '',
  manifestUrl: Uri.parse('https://example.org/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026, 7, 13),
);

RegisteredBookSource _sourceWithId(String id, String name) =>
    RegisteredBookSource(
      id: id,
      name: name,
      description: '',
      manifestUrl: Uri.parse('https://$id.example/source.json'),
      apiBaseUrl: Uri.parse('https://$id.example/api/'),
      protocolVersion: '1.5',
      languages: const ['en'],
      capabilities: const {'search'},
      enabled: true,
      addedAt: DateTime.utc(2026, 8, 3),
    );

RegisteredBookSource _readingDiscoverySource() => RegisteredBookSource(
  id: 'reading-source',
  name: 'reading source E',
  description: '',
  manifestUrl: Uri.parse('https://source.example'),
  apiBaseUrl: Uri.parse('https://source.example'),
  protocolVersion: 'reading-source-1',
  languages: const [],
  capabilities: const {
    'search',
    'detail',
    'catalog',
    'content',
    'categories',
    'browse',
  },
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 1),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: const {
    'bookSourceName': 'reading source E',
    'bookSourceUrl': 'https://source.example',
    'searchUrl': '/search?q={{key}}',
    'exploreUrl': 'Ranking::/rank?page={{page}}',
    'ruleSearch': {'bookList': '.book', 'bookUrl': 'a@href', 'name': 'a@text'},
    'ruleBookInfo': {'name': 'h1@text'},
    'ruleToc': {
      'chapterList': '.chapter',
      'chapterName': 'text',
      'chapterUrl': 'href',
    },
    'ruleContent': {'content': '#content@text'},
    '_openReadingReadingChainVerifiedAt': '2026-08-01T00:00:00Z',
  },
);

class _DiscoveryBookSourceClient extends BookSourceClient {
  final List<int> requestedPages = [];

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
  ) async => const [BookSourceCategory(id: '/rank', name: 'Ranking')];

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
  }) async {
    requestedPages.add(page);
    return BookSourceSearchPage(
      items: [
        BookSourceBook(
          id: 'channel-book-$page',
          title: 'Channel Book $page',
          author: 'Author',
          description: '',
          categories: const [],
        ),
      ],
      page: page,
      pageSize: 1,
      hasMore: page == 1,
    );
  }
}

class _PagingBookSourceClient extends BookSourceClient {
  final List<int> requestedPages = [];

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    requestedPages.add(page);
    final start = page == 1 ? 1 : 11;
    final count = page == 1 ? 10 : 1;
    return BookSourceSearchPage(
      items: List.generate(
        count,
        (index) => BookSourceBook(
          id: 'book-${start + index}',
          title: 'Book ${start + index}',
          author: 'Author',
          description: '',
          categories: const [],
        ),
      ),
      page: page,
      pageSize: pageSize,
      total: 11,
      hasMore: page == 1,
    );
  }
}

class _ProgressiveSearchClient extends BookSourceClient {
  final List<String> startedSourceIds = [];
  final Map<String, Completer<BookSourceSearchPage>> _completers = {};
  int active = 0;
  int maxActive = 0;

  void complete(String sourceId) {
    _completers[sourceId]!.complete(
      BookSourceSearchPage(
        items: [
          BookSourceBook(
            id: '$sourceId-book',
            title:
                'Book from ${sourceId.replaceFirst('progress-', 'Progress ')}',
            author: 'Author',
            description: '',
            categories: const [],
          ),
        ],
        page: 1,
        pageSize: 20,
        total: 1,
        hasMore: false,
      ),
    );
  }

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    startedSourceIds.add(source.id);
    active++;
    if (active > maxActive) maxActive = active;
    final completer = Completer<BookSourceSearchPage>();
    _completers[source.id] = completer;
    try {
      return await completer.future;
    } finally {
      active--;
    }
  }
}

class _TimeoutSearchClient extends BookSourceClient {
  final List<String> startedSourceIds = [];
  bool slowWasCancelled = false;

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    startedSourceIds.add(source.id);
    if (source.id == 'slow') {
      cancellation?.addListener(() => slowWasCancelled = true);
      return Completer<BookSourceSearchPage>().future;
    }
    return BookSourceSearchPage(
      items: const [
        BookSourceBook(
          id: 'fast-book',
          title: 'Book from Fast',
          author: 'Author',
          description: '',
          categories: [],
        ),
      ],
      page: page,
      pageSize: pageSize,
      total: 1,
      hasMore: false,
    );
  }
}
