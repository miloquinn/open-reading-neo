import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_source_management_page.dart';
import 'package:xxread/services/core/app_settings_service.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  void unmountPage(WidgetTester tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('keeps native ORSP source management available', (tester) async {
    unmountPage(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1100);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(await BookSourceRegistry().load(), isEmpty);
    expect(find.text('Manage sources'), findsOneWidget);
    expect(find.byKey(const Key('bookSourcesToolButton')), findsOneWidget);
    expect(find.text('Open Reading Source Protocol'), findsNothing);
    await tester.tap(find.byKey(const Key('bookSourcesToolButton')));
    await tester.pumpAndSettle();
    expect(find.text('Open Reading Source Protocol'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('centers the title between matching glass controls', (
    tester,
  ) async {
    unmountPage(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pumpAndSettle();

    final backRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-back')),
    );
    final titleRect = tester.getRect(find.text('书源管理'));
    final toolRect = tester.getRect(
      find.byKey(const Key('bookSourcesToolButton')),
    );
    final screenCenter =
        tester.getSize(find.byType(BookSourceManagementPage)).width / 2;

    expect((titleRect.center.dx - screenCenter).abs(), lessThan(1));
    expect((titleRect.center.dy - backRect.center.dy).abs(), lessThan(8));
    expect(backRect.size, toolRect.size);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses one add flow regardless of the advanced toggle', (
    tester,
  ) async {
    unmountPage(tester);
    final settings = AppSettingsNotifier();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppSettingsNotifier>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BookSourceManagementPage(),
        ),
      ),
    );
    await tester.pump();
    for (
      var attempts = 0;
      attempts < 20 && !settings.isInitialized;
      attempts++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.byKey(const Key('additionalSourcesImportButton')),
      findsNothing,
    );
    expect(find.byKey(const Key('bookSourcesToolButton')), findsOneWidget);

    await settings.setAdditionalSourceProtocolsEnabled(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const Key('additionalSourcesImportButton')),
      findsNothing,
    );
    expect(find.byKey(const Key('bookSourcesToolButton')), findsOneWidget);
  });

  testWidgets('keeps dense source metadata readable on narrow phones', (
    tester,
  ) async {
    unmountPage(tester);
    await BookSourceRegistry().upsert(
      RegisteredBookSource(
        id: 'org.example.long-source',
        name: 'A deliberately long connected source name',
        description:
            'A long source description that still needs useful reading width.',
        manifestUrl: Uri.parse('https://example.org/source.json'),
        apiBaseUrl: Uri.parse('https://example.org/api/'),
        protocolVersion: '1.4',
        languages: const ['en'],
        capabilities: const {
          'browse',
          'catalog',
          'categories',
          'content',
          'detail',
          'discover',
          'search',
        },
        enabled: true,
        addedAt: DateTime.utc(2026, 7, 22),
      ),
    );

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(
      const ValueKey('bookSourceCard-org.example.long-source'),
    );
    expect(card, findsOneWidget);
    expect(
      find.text('A deliberately long connected source name'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Switch>(
            find.descendant(of: card, matching: find.byType(Switch)),
          )
          .value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('groups connected sources by protocol', (tester) async {
    unmountPage(tester);
    final orsp = RegisteredBookSource(
      id: 'org.example.orsp',
      name: 'ORSP Example',
      description: '',
      manifestUrl: Uri.parse('https://example.org/source.json'),
      apiBaseUrl: Uri.parse('https://example.org/api/'),
      protocolVersion: '1.5',
      languages: const ['en'],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      addedAt: DateTime.utc(2026, 7, 31),
    );
    final additional = RegisteredBookSource(
      id: 'source.example',
      name: 'Other Example',
      description: '',
      manifestUrl: Uri.parse('https://books.example'),
      apiBaseUrl: Uri.parse('https://books.example'),
      protocolVersion: 'reading-source-1',
      languages: const [],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: false,
      addedAt: DateTime.utc(2026, 7, 31),
      sourceProtocol: BookSourceProtocolKind.readingSource,
      sourceConfig: const {
        'bookSourceName': 'Other Example',
        'bookSourceUrl': 'https://books.example',
        '_openReadingReadingChainVerifiedAt': '2026-07-31T00:00:00Z',
      },
    );
    SharedPreferences.setMockInitialValues({
      'open_reading_book_sources_v1': jsonEncode([
        orsp.toJson(),
        additional.toJson(),
      ]),
    });

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('ORSP sources'), findsOneWidget);
    expect(find.text('Other protocol sources'), findsOneWidget);
    expect(find.text('ORSP Example'), findsOneWidget);
    expect(find.text('Other Example'), findsOneWidget);
  });

  testWidgets('adding a source requires explicit third-party acknowledgment', (
    tester,
  ) async {
    unmountPage(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1100);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('bookSourcesToolButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bookSourcesAddButton')));
    await tester.pumpAndSettle();

    expect(find.text('Import link'), findsOneWidget);
    expect(find.text('Add from JSON file'), findsOneWidget);
    final urlField = tester.widget<TextField>(
      find.byKey(const Key('bookSourceUnifiedUrlField')),
    );
    expect(urlField.autofocus, isFalse);

    expect(
      find.textContaining('OpenReading includes no sources'),
      findsOneWidget,
    );
    expect(find.textContaining('bypass sign-in, payment, DRM'), findsOneWidget);
    FilledButton connectButton() => tester.widget<FilledButton>(
      find.byKey(const Key('bookSourceConnectButton')),
    );
    expect(connectButton().onPressed, isNull);

    await tester.tap(find.byKey(const Key('bookSourceResponsibilityCheckbox')));
    await tester.pump();

    expect(connectButton().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection mode exposes bulk source actions', (tester) async {
    unmountPage(tester);
    await BookSourceRegistry().upsert(
      RegisteredBookSource(
        id: 'org.example.bulk',
        name: 'Bulk Example',
        description: '',
        manifestUrl: Uri.parse('https://example.org/source.json'),
        apiBaseUrl: Uri.parse('https://example.org/api/'),
        protocolVersion: '1.5',
        languages: const ['en'],
        capabilities: const {'search', 'detail', 'catalog', 'content'},
        enabled: true,
        addedAt: DateTime.utc(2026, 7, 31),
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('bookSourcesToolButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bookSourcesSelectionModeButton')));
    await tester.pump();

    expect(find.text('Select all'), findsOneWidget);
    expect(find.text('Enable selected'), findsOneWidget);
    expect(find.text('Disable selected'), findsOneWidget);
    expect(find.text('Delete selected'), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('shows operator-supplied rights metadata as unverified', (
    tester,
  ) async {
    unmountPage(tester);
    final source = RegisteredBookSource(
      id: 'org.example.public-books',
      name: 'Example Public Books',
      description: 'Licensed catalog',
      manifestUrl: Uri.parse('https://example.org/source.json'),
      apiBaseUrl: Uri.parse('https://example.org/api/'),
      protocolVersion: '1.2',
      languages: const ['en'],
      capabilities: const {'search', 'content'},
      operatorName: 'Example Library',
      contactUrl: Uri.parse('https://example.org/contact'),
      contentLicense: 'CC BY 4.0',
      rightsStatement: 'Licensed public catalog.',
      enabled: true,
      addedAt: DateTime.utc(2026, 7, 19),
    );
    SharedPreferences.setMockInitialValues({
      'open_reading_book_sources_v1': jsonEncode([source.toJson()]),
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1100);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('bookSourceCard-org.example.public-books')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Operator and rights'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Example Library'), findsOneWidget);
    expect(find.text('CC BY 4.0'), findsOneWidget);
    expect(find.text('Licensed public catalog.'), findsOneWidget);
    expect(find.textContaining('does not verify or endorse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large source collections build lazily and remain searchable', (
    tester,
  ) async {
    unmountPage(tester);
    final sources = List.generate(
      600,
      (index) => RegisteredBookSource(
        id: 'org.example.bulk-$index',
        name: 'Source ${index.toString().padLeft(3, '0')}',
        description: '',
        manifestUrl: Uri.parse('https://source-$index.example/source.json'),
        apiBaseUrl: Uri.parse('https://source-$index.example/api/'),
        protocolVersion: '1.5',
        languages: const ['en'],
        capabilities: const {'search', 'detail', 'catalog', 'content'},
        enabled: true,
        addedAt: DateTime.utc(2026, 8, 2),
      ),
    );
    SharedPreferences.setMockInitialValues({
      'open_reading_book_sources_v1': jsonEncode(
        sources.map((source) => source.toJson()).toList(),
      ),
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Showing 600 of 600'), findsOneWidget);
    expect(
      find.byKey(const Key('bookSourceManagementScrollbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bookSourceCard-org.example.bulk-599')),
      findsNothing,
    );

    final verticalScrollable = find
        .descendant(
          of: find.byKey(const Key('bookSourceManagementList')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Source 024'),
      500,
      scrollable: verticalScrollable,
      maxScrolls: 20,
    );
    expect(find.text('Source 024'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('bookSourceManagementSearchField')),
      -500,
      scrollable: verticalScrollable,
      maxScrolls: 20,
    );

    await tester.enterText(
      find.byKey(const Key('bookSourceManagementSearchField')),
      'Source 599',
    );
    await tester.pump();

    expect(find.text('Showing 1 of 600'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('bookSourceCard-org.example.bulk-599')),
        matching: find.text('Source 599'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('bookSourcesToolButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bookSourcesSelectionModeButton')));
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Select all'));
    await tester.pump();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(tester.takeException(), isNull);
  });
}
