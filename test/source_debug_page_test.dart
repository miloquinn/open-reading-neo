import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/source_debug_page.dart';

void main() {
  testWidgets('keeps debugger controls below the floating header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewPadding: EdgeInsets.only(top: 32),
          ),
          child: child!,
        ),
        home: SourceDebugPage(source: _source),
      ),
    );
    await tester.pump();

    final headerRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-header')),
    );
    final inputRect = tester.getRect(find.byType(TextField));
    final runButton = find.byType(FilledButton);

    expect(inputRect.top, greaterThanOrEqualTo(headerRect.bottom));
    expect(
      tester.getRect(runButton).top,
      greaterThanOrEqualTo(headerRect.bottom),
    );
    expect(runButton.hitTestable(), findsOneWidget);
  });
}

final _source = RegisteredBookSource(
  id: 'debug-test',
  name: 'Debug source',
  description: '',
  manifestUrl: Uri.parse('https://example.com/source.json'),
  apiBaseUrl: Uri.parse('https://example.com'),
  protocolVersion: '1.0',
  languages: const ['zh'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);
