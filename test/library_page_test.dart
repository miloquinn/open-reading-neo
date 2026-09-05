import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/library/library_page.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/services/core/app_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('library closes only a factory-created source shelf service', (
    tester,
  ) async {
    final ownedService = _CloseTrackingLibraryShelfService();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettingsNotifier(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(
            booksLoader: () async => const [],
            sourceShelfServiceFactory: () => ownedService,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(ownedService.closeCount, 1);

    final borrowedService = _CloseTrackingLibraryShelfService();
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettingsNotifier(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(
            booksLoader: () async => const [],
            sourceShelfService: borrowedService,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(borrowedService.closeCount, 0);
    borrowedService.close();
  });

  testWidgets('book options distinguish data and source-file exports', (
    tester,
  ) async {
    final book = Book(
      id: 1,
      title: 'Exportable Book',
      author: 'Author',
      filePath: '/tmp/exportable.epub',
      format: 'EPUB',
    );
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettingsNotifier(),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryPage(booksLoader: () async => [book]),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    await tester.longPress(find.text('Exportable Book').first);
    await tester.pumpAndSettle();

    expect(find.text('导出阅读数据'), findsOneWidget);
    expect(find.text('导出书籍文件'), findsOneWidget);
    expect(find.text('高亮、下划线与笔记'), findsOneWidget);
  });

  testWidgets('loads books and filters by title or author', (tester) async {
    final books = [
      Book(
        id: 1,
        title: 'Alpha Reader',
        author: 'Alice',
        filePath: '/tmp/alpha.txt',
        format: 'TXT',
        readingProgress: 0.4,
      ),
      Book(
        id: 2,
        title: 'Beta Library',
        author: 'Bob',
        filePath: '/tmp/beta.epub',
        format: 'EPUB',
        readingProgress: 1,
      ),
    ];

    final controller = LibraryPageController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettingsNotifier(),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(useMaterial3: true),
          home: LibraryPage(
            controller: controller,
            booksLoader: () async => books,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    expect(find.text('Alpha Reader'), findsWidgets);
    expect(find.text('Beta Library'), findsWidgets);

    controller.toggleSearch();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Alpha Reader'), findsWidgets);
    expect(find.text('Beta Library'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('shows an explicit load error and retries', (tester) async {
    var attempts = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppSettingsNotifier(),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(useMaterial3: true),
          home: LibraryPage(
            booksLoader: () async {
              attempts++;
              if (attempts == 1) throw StateError('database unavailable');
              return [
                Book(
                  id: 3,
                  title: 'Recovered Book',
                  filePath: '/tmp/recovered.txt',
                  format: 'TXT',
                ),
              ];
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('错误'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('Recovered Book'), findsNothing);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();

    expect(attempts, 2);
    expect(find.text('Recovered Book'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'tablet library keeps floating chrome insets and adapts columns',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(768, 1024);
      addTearDown(tester.view.reset);
      final books = List.generate(
        12,
        (index) => Book(
          id: index + 1,
          title: 'Tablet Book $index',
          author: 'Author',
          filePath: '/tmp/tablet-$index.txt',
          format: 'TXT',
        ),
      );
      const chrome = HomeMobileChromeMetrics(
        systemTopInset: 24,
        systemBottomInset: 20,
        navigationAtTop: true,
      );
      final controller = LibraryPageController();
      final settings = AppSettingsNotifier();
      addTearDown(controller.dispose);
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: HomeMobileChromeScope(
              metrics: chrome,
              child: LibraryPage(
                controller: controller,
                booksLoader: () async => books,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();

      GridView grid = tester.widget(
        find.byKey(const Key('library-cover-grid')),
      );
      var delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
      expect(tester.getTopLeft(find.text('Tablet Book 0')).dy, greaterThan(70));

      await tester.longPress(find.text('Tablet Book 0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select multiple'));
      await tester.pumpAndSettle();
      grid = tester.widget(find.byKey(const Key('library-cover-grid')));
      expect(
        (grid.padding! as EdgeInsets).bottom,
        chrome.navContainerHeight + 10,
      );
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('library-cover-grid')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.getBottomLeft(find.text('Tablet Book 11')).dy,
        lessThanOrEqualTo(1024 - chrome.navContainerHeight),
      );
      tester.view.physicalSize = const Size(1366, 900);
      await tester.pumpAndSettle();
      grid = tester.widget(find.byKey(const Key('library-cover-grid')));
      delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 6);
      expect(
        tester.getSize(find.byKey(const Key('library-cover-grid'))).width,
        1200,
      );

      await settings.setLibraryLayoutMode(LibraryLayoutMode.card);
      await tester.pump();
      final cardGrid = tester.widget<GridView>(
        find.byKey(const Key('library-card-grid')),
      );
      expect(
        (cardGrid.padding! as EdgeInsets).bottom,
        chrome.navContainerHeight + 10,
      );
      final cardScrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byKey(const Key('library-card-grid')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      cardScrollable.position.jumpTo(cardScrollable.position.maxScrollExtent);
      await tester.pump();
      expect(
        tester.getBottomLeft(find.text('Tablet Book 11')).dy,
        lessThanOrEqualTo(900 - chrome.navContainerHeight),
      );
      controller.exitSelection();
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1300));
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

class _CloseTrackingLibraryShelfService extends BookSourceShelfService {
  _CloseTrackingLibraryShelfService()
    : super(clientFactory: _CloseTrackingLibraryClient.new);

  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    super.close();
  }
}

class _CloseTrackingLibraryClient extends BookSourceClient {}
