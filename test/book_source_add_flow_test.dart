import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_add_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_add_flow.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_add_panel.dart';

void main() {
  testWidgets('editing the address invalidates the previous preview', (
    tester,
  ) async {
    final analyzer = _Analyzer();
    await _open(tester, analyzer: analyzer);
    await _start(tester);
    analyzer.pending.complete(_analysis);
    await tester.pumpAndSettle();
    expect(find.text('Import 1 source'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('bookSourceUnifiedUrlField')),
      'https://new.example',
    );
    await tester.pump();
    expect(find.byKey(const Key('bookSourceImportPreview')), findsNothing);
    expect(find.text('Read sources'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'phase feedback updates and late analysis is ignored after cancel',
    (tester) async {
      final analyzer = _Analyzer();
      await _open(tester, analyzer: analyzer);
      await _start(tester);
      expect(find.text('Downloading source…'), findsOneWidget);
      analyzer.downloadComplete!();
      await tester.pump();
      expect(
        find.text('Reading rules and checking duplicates…'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      analyzer.pending.complete(_analysis);
      await tester.pumpAndSettle();
      expect(find.byType(BookSourceAddFlow), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving blocks repeat submit and back until the result is ready',
    (tester) async {
      final analyzer = _Analyzer();
      final registry = _Registry();
      await _open(tester, analyzer: analyzer, registry: registry);
      await _start(tester);
      analyzer.pending.complete(_analysis);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bookSourceConnectButton')));
      await tester.pump();
      expect(find.text('Saving sources…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('bookSourceConnectButton')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('bookSourceImportCloseButton')),
            )
            .onPressed,
        isNull,
      );
      final context = tester.element(find.byType(BookSourceAddFlow));
      await Navigator.of(context).maybePop();
      await tester.pump();
      expect(find.byType(BookSourceAddFlow), findsOneWidget);
      expect(registry.writes, 1);
      registry.pending.complete([_source]);
      await tester.pumpAndSettle();
      expect(find.byType(BookSourceAddFlow), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing during file selection ignores the late file', (
    tester,
  ) async {
    final picker = Completer<FilePickerResult?>();
    final analyzer = _Analyzer();
    await _open(tester, analyzer: analyzer, pickFile: () => picker.future);
    await tester.tap(find.text('JSON file'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bookSourceChooseJsonButton')));
    await tester.pump();
    expect(find.text('Opening file picker…'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    picker.complete(
      FilePickerResult([
        PlatformFile(
          name: 'sources.json',
          size: 2,
          bytes: Uint8List.fromList([91, 93]),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(analyzer.byteCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file picker failure stays in the route and can be retried', (
    tester,
  ) async {
    var calls = 0;
    await _open(
      tester,
      pickFile: () async {
        calls++;
        if (calls == 1) throw StateError('file provider unavailable');
        return null;
      },
    );
    await tester.tap(find.text('JSON file'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('bookSourceChooseJsonButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bookSourceImportError')), findsOneWidget);
    await tester.tap(find.byKey(const Key('bookSourceChooseJsonButton')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(BookSourceAddFlow), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty previews cannot be committed', (tester) async {
    final analyzer = _Analyzer();
    await _open(tester, analyzer: analyzer);
    await _start(tester);
    analyzer.pending.complete(
      BookSourceImportAnalysis.additional(
        SourceImportPreview(sources: const [], errors: const []),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('bookSourceConnectButton')),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.text('No sources selected. Check the file or duplicate selection.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'unsupported protocol setting preserves preview and explains the gate',
    (tester) async {
      final analyzer = _Analyzer();
      await _open(
        tester,
        analyzer: analyzer,
        additionalProtocolsEnabled: false,
      );
      await _start(tester);
      final importer = SourceImportService();
      addTearDown(importer.close);
      analyzer.pending.complete(
        BookSourceImportAnalysis.additional(
          importer.parseDecoded([
            {
              'bookSourceName': 'Example',
              'bookSourceUrl': 'https://example.org',
            },
          ]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bookSourceImportPreview')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('bookSourceConnectButton')),
            )
            .onPressed,
        isNull,
      );
      final context = tester.element(find.byType(BookSourceAddFlow));
      expect(
        find.text(
          AppLocalizations.of(context).bookSourcesAdvancedFeatureRequired,
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('timeout shows a recovery message without opening error details', (
    tester,
  ) async {
    final analyzer = _Analyzer();
    await _open(tester, analyzer: analyzer);
    await _start(tester);
    analyzer.pending.completeError(TimeoutException('source timed out'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Reading took too long. Check your connection or try importing a downloaded JSON file.',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('bookSourceConnectButton')),
          )
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final locale in const [Locale('zh'), Locale('en'), Locale('ja')]) {
    testWidgets(
      'narrow large text keeps actions visible in ${locale.languageCode}',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final text = TextEditingController();
        addTearDown(text.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
                child: BookSourceAddPanel(
                  controller: text,
                  connecting: true,
                  phase: BookSourceAddPhase.analyzing,
                  responsibilityAccepted: true,
                  mode: BookSourceAddMode.link,
                  analysis: _analysis,
                  errorText: null,
                  sheet: true,
                  onModeChanged: (_) {},
                  onResponsibilityChanged: (_) {},
                  onCancel: () {},
                  onAnalyzeLink: () {},
                  onChooseFile: () {},
                  onAdd: () {},
                  onReviewDedupe: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(
          find.byKey(const Key('bookSourceConnectButton')),
        );
        expect(rect.bottom, lessThanOrEqualTo(640));
        expect(rect.top, greaterThan(0));
      },
    );
  }
}

Future<void> _open(
  WidgetTester tester, {
  _Analyzer? analyzer,
  _Registry? registry,
  bool additionalProtocolsEnabled = true,
  Future<FilePickerResult?> Function()? pickFile,
}) async {
  tester.view.physicalSize = const Size(600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 520,
                    maxHeight: 850,
                  ),
                  child: BookSourceAddFlow(
                    sheet: false,
                    additionalProtocolsEnabled: additionalProtocolsEnabled,
                    pickFile: pickFile,
                    createController: () => BookSourceAddController(
                      analyzer: analyzer ?? _Analyzer(),
                      registry: registry ?? _Registry(),
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _start(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('bookSourceUnifiedUrlField')),
    'https://source.example',
  );
  await tester.tap(find.byKey(const Key('bookSourceResponsibilityCheckbox')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('bookSourceConnectButton')));
  await tester.pump();
}

final _source = RegisteredBookSource(
  id: 'source',
  name: 'Example source',
  description: '',
  manifestUrl: Uri.parse('https://source.example/source.json'),
  apiBaseUrl: Uri.parse('https://source.example/api/'),
  protocolVersion: '1.5',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);
final _analysis = BookSourceImportAnalysis.orsp(_source);

class _Analyzer extends BookSourceImportAnalyzer {
  final pending = Completer<BookSourceImportAnalysis>();
  VoidCallback? downloadComplete;
  int byteCalls = 0;
  @override
  Future<BookSourceImportAnalysis> analyzeUrl(
    String input, {
    VoidCallback? onDownloadComplete,
    VoidCallback? onDownloadStarted,
  }) {
    downloadComplete = onDownloadComplete;
    return pending.future;
  }

  @override
  Future<BookSourceImportAnalysis> analyzeBytesAsync(
    Uint8List bytes, {
    Uri? documentUri,
  }) {
    byteCalls++;
    return pending.future;
  }
}

class _Registry extends BookSourceRegistry {
  int writes = 0;
  final pending = Completer<List<RegisteredBookSource>>();
  @override
  Future<List<RegisteredBookSource>> upsert(RegisteredBookSource source) {
    writes++;
    return pending.future;
  }
}
