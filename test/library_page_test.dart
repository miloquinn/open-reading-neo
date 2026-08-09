import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/library/library_page.dart';
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
