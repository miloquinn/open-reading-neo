import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_widgets.dart';
import 'package:xxread/widgets/generated_book_cover.dart';

void main() {
  testWidgets('source metadata action does not open the book', (tester) async {
    var bookOpened = false;
    var sourceOpened = false;
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SourcedBookListTile(
            result: _result(),
            editorial: true,
            onTap: () => bookOpened = true,
            onSourceTap: () => sourceOpened = true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Source ›'));
    expect(sourceOpened, isTrue);
    expect(bookOpened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card preserves fallback cover, source label, and tap', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SourcedBookCard(
            result: _result(author: ''),
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.byType(GeneratedBookCover), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
    await tester.tap(find.byType(SourcedBookCard));
    expect(tapped, isTrue);
  });

  testWidgets('list tile renders normalized metadata and invokes tap', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SourcedBookListTile(
            result: _result(description: '<p>Hello&nbsp;world</p>'),
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(find.text('Author · Source'), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    await tester.tap(find.byType(SourcedBookListTile));
    expect(tapped, isTrue);
  });

  testWidgets('editorial list tile uses a clean divider row', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.indigo),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SourcedBookListTile(
            result: _result(description: '<p>Hello&nbsp;world</p>'),
            editorial: true,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('sourcedBookEditorialDivider')),
      findsOneWidget,
    );
    expect(find.text('Author · Source'), findsOneWidget);
    expect(find.text('Hello world'), findsOneWidget);
    expect(
      tester.getSize(find.byType(GeneratedBookCover)),
      const Size(78, 108),
    );

    await tester.tap(find.byType(SourcedBookListTile));
    expect(tapped, isTrue);
  });

  testWidgets('editorial cards fit narrow layouts with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Scaffold(
            body: SourcedBookCard(
              result: _result(),
              editorial: true,
              width: 92,
              onTap: () {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(SourcedBookCard)).width, 92);
    expect(find.byType(GeneratedBookCover), findsOneWidget);
  });
}

SourcedBook _result({String author = 'Author', String description = ''}) =>
    SourcedBook(
      source: RegisteredBookSource(
        id: 'source',
        name: 'Source',
        description: '',
        manifestUrl: Uri.parse('https://example.org/source.json'),
        apiBaseUrl: Uri.parse('https://example.org/api/'),
        protocolVersion: '1.1',
        languages: const ['en'],
        capabilities: const {'search'},
        enabled: true,
        addedAt: DateTime.utc(2026),
      ),
      book: BookSourceBook(
        id: 'book',
        title: 'Book',
        author: author,
        description: description,
        categories: const [],
      ),
    );
