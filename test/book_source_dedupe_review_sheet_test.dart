import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_engine.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_models.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_dedupe_review_sheet.dart';

void main() {
  testWidgets('import review shows canonical group without narrow overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final preview = SourceImportPreview(
      sources: [
        _config('Old', 'https://EXAMPLE.com:443/?utm_source=list'),
        _config('New', 'https://example.com'),
      ],
      errors: const [],
    );

    await tester.pumpWidget(
      _app(BookSourceImportDedupeReviewSheet(preview: preview)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Review duplicate sources'), findsOneWidget);
    expect(find.text('Same normalized source address'), findsOneWidget);
    expect(find.text('Standard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('installed review keeps same-site candidates unselected', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 900);
    addTearDown(tester.view.reset);
    final sources = [
      _registered('old', 'Old', 'https://EXAMPLE.com:443/?utm_source=list'),
      _registered('new', 'New', 'https://example.com'),
      _registered('path', 'Other path', 'https://example.com/catalog'),
    ];
    final candidates = [
      for (final entry in sources.indexed)
        BookSourceDedupeCandidate(
          index: entry.$1,
          rawConfig: entry.$2.sourceConfig!,
          installedSourceId: entry.$2.id,
        ),
    ];
    final result = const BookSourceDedupeEngine().analyze(candidates);

    await tester.pumpWidget(
      _app(
        BookSourceInstalledDedupeReviewSheet(
          result: result,
          sourcesByIndex: {
            for (final entry in sources.indexed) entry.$1: entry.$2,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disable 1 selected'), findsOneWidget);
    await tester.tap(find.text('Same site'));
    await tester.pumpAndSettle();
    expect(find.text('Disable 0 selected'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Disable 0 selected'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: home),
);

ReadingSourceConfig _config(String name, String url) =>
    ReadingSourceConfig.fromJson({
      'bookSourceName': name,
      'bookSourceUrl': url,
      'searchUrl': '/search?q={{key}}',
      'ruleSearch': {'bookList': '.book'},
      'ruleToc': {'chapterList': '.chapter'},
      'ruleContent': {'content': '#content'},
    });

RegisteredBookSource _registered(String id, String name, String url) =>
    _config(name, url).toRegisteredSource(id: id);
