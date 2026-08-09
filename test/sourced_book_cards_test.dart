import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_widgets.dart';
import 'package:xxread/widgets/generated_book_cover.dart';

void main() {
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
