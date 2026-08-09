import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_widgets.dart';
import 'package:xxread/services/library/download_task_controller.dart';

void main() {
  testWidgets('actions present provider-backed details with reduced motion', (
    tester,
  ) async {
    tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(
      tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
    );
    final source = _source();
    final summary = SourcedBook(
      source: source,
      book: _book(title: 'Summary title'),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => DownloadTaskController(),
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                key: const Key('openDetails'),
                onPressed: () => SourcedBookActions(
                  context: context,
                  client: _DetailsClient(),
                  shelfService: _ShelfService(),
                ).showBookDetails(summary),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('openDetails')));
    await tester.pumpAndSettle();

    expect(find.text('Detailed title'), findsOneWidget);
    expect(find.byKey(const Key('bookSourceDetailsContent')), findsOneWidget);
    final animatedSize = tester.widget<AnimatedSize>(
      find.byKey(const Key('bookSourceSheetAnimatedSize')),
    );
    expect(animatedSize.duration, Duration.zero);
    final switcher = tester.widget<AnimatedSwitcher>(
      find.byType(AnimatedSwitcher),
    );
    expect(switcher.duration, Duration.zero);
  });
}

class _DetailsClient extends BookSourceClient {
  @override
  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async => _book(title: 'Detailed title');
}

class _ShelfService extends BookSourceShelfService {}

RegisteredBookSource _source() => RegisteredBookSource(
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
);

BookSourceBook _book({required String title}) => BookSourceBook(
  id: 'book',
  title: title,
  author: 'Author',
  description: 'Description',
  categories: const [],
);
