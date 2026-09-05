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
    await _waitForMode(tester);
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

  testWidgets(
    'import mode computes before confirm and returns the prepared preview',
    (tester) async {
      final preview = SourceImportPreview(
        sources: [
          _config('Old', 'https://EXAMPLE.com:443/?utm_source=list'),
          _config('New', 'https://example.com'),
        ],
        errors: const [],
      );
      BookSourceImportDedupeSelection? selection;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selection =
                    await showModalBottomSheet<BookSourceImportDedupeSelection>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) =>
                          BookSourceImportDedupeReviewSheet(preview: preview),
                    );
              },
              child: const Text('Open review'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Same site'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
            .onPressed,
        isNull,
      );
      await _waitForMode(tester);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(selection?.preview?.mode, BookSourceDedupeMode.siteReview);
      expect(selection?.preview?.selectedIndices, selection?.selectedIndices);
      expect(selection?.preview?.candidates.length, preview.candidates.length);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('duplicate groups are built lazily for large reviews', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final sources = <RegisteredBookSource>[];
    for (var group = 0; group < 40; group++) {
      final url = 'https://source-$group.example';
      sources
        ..add(_registered('$group-old', 'Old $group', url))
        ..add(_registered('$group-new', 'New $group', url));
    }
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

    final builtGroups = find.byType(ExpansionTile).evaluate().length;
    expect(result.groups, hasLength(40));
    expect(builtGroups, greaterThan(0));
    expect(builtGroups, lessThan(result.groups.length));
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

Future<void> _waitForMode(WidgetTester tester) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Background duplicate analysis did not complete.');
}
