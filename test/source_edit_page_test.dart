import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_source_management_page.dart';
import 'package:xxread/pages/book_sources/source_edit_page.dart';
import 'package:xxread/widgets/app_menu.dart';

void main() {
  setUp(() async {
    await BookSourceRegistry.resetForTesting();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('management menu saves an edited source and refreshes its card', (
    tester,
  ) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    final registry = BookSourceRegistry(storage: _seededStorage());

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(registry: registry),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byType(AppPopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit source'));
    await tester.pumpAndSettle();

    expect(find.byType(SourceEditPage), findsOneWidget);
    for (final label in const [
      'Basic',
      'Search',
      'Explore',
      'Book info',
      'Table of contents',
      'Content',
    ]) {
      expect(_tab(label), findsOneWidget);
    }
    expect(find.byKey(const Key('sourceEditDebug')), findsOneWidget);
    expect(find.byKey(const Key('sourceEditSave')), findsOneWidget);

    await _enter(tester, 'sourceEdit.bookSourceName', 'Edited from menu');
    await tester.tap(find.byKey(const Key('sourceEditSave')));
    await _pumpUntilEditorCloses(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Edited from menu'), findsOneWidget);
    expect(find.text('Original source'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saves edited fields from all six tabs and preserves extensions',
    (tester) async {
      final storage = _seededStorage();
      final registry = BookSourceRegistry(storage: storage);
      await _openEditor(tester, registry: registry);

      await _enter(tester, 'sourceEdit.bookSourceName', 'Edited source');
      await _selectTab(tester, 'Search');
      await _enter(tester, 'sourceEdit.ruleSearch.name', '.title@text');
      await _selectTab(tester, 'Explore');
      await _enter(
        tester,
        'sourceEdit.ruleExplore.name',
        '.explore-title@text',
      );
      await _selectTab(tester, 'Book info');
      await _enter(tester, 'sourceEdit.ruleBookInfo.name', 'h1@text');
      await _selectTab(tester, 'Table of contents');
      await _enter(tester, 'sourceEdit.ruleToc.chapterName', 'a@text');
      await _selectTab(tester, 'Content');
      await _enter(
        tester,
        'sourceEdit.ruleContent.content',
        '#article@textNodes',
      );

      await tester.tap(find.byKey(const Key('sourceEditSave')));
      await _pumpUntilEditorCloses(tester);

      final reloaded = (await BookSourceRegistry(
        storage: _MemoryRegistryStorage(storage.raw),
      ).load()).single;
      expect(reloaded.name, 'Edited source');
      expect(reloaded.sourceConfig?['ruleSearch'], {
        'bookList': '.book',
        'name': '.title@text',
        'extension': {
          'labels': ['one', 'two'],
        },
      });
      expect(reloaded.sourceConfig?['ruleExplore'], {
        'name': '.explore-title@text',
        'unknownExploreRule': true,
      });
      expect(reloaded.sourceConfig?['ruleBookInfo'], {
        'name': 'h1@text',
        'unknownInfoRule': 7,
      });
      expect(reloaded.sourceConfig?['ruleToc'], {
        'chapterList': '.chapter',
        'chapterName': 'a@text',
        'unknownTocRule': 'keep',
      });
      expect(reloaded.sourceConfig?['ruleContent'], {
        'content': '#article@textNodes',
        'unknownContentRule': ['keep'],
      });
      expect(reloaded.sourceConfig?['unknownRoot'], {
        'nested': {'keep': true},
      });
      expect(find.text('Open editor'), findsOneWidget);
    },
  );

  testWidgets('back keeps editing first and discards without writing second', (
    tester,
  ) async {
    final storage = _seededStorage();
    final registry = BookSourceRegistry(storage: storage);
    final before = storage.raw;
    await _openEditor(tester, registry: registry);
    await _enter(tester, 'sourceEdit.bookSourceName', 'Unsaved source');

    await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();

    expect(find.byType(SourceEditPage), findsOneWidget);
    expect(_text(tester, 'sourceEdit.bookSourceName'), 'Unsaved source');
    expect(storage.raw, before);

    await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(find.byType(SourceEditPage), findsNothing);
    expect(storage.raw, before);
    expect((await registry.load()).single.name, 'Original source');
  });

  testWidgets('required source name and URL prevent saving', (tester) async {
    final registry = _RecordingRegistry();
    await _openEditor(tester, registry: registry);

    await _enter(tester, 'sourceEdit.bookSourceUrl', '');
    await _enter(tester, 'sourceEdit.bookSourceName', '');
    await tester.tap(find.byKey(const Key('sourceEditSave')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Enter a source name'), findsOneWidget);
    await tester.drag(
      find.byKey(const PageStorageKey('sourceEditSection0')),
      const Offset(0, 1000),
    );
    await tester.pump();
    expect(find.text('Enter a source URL'), findsOneWidget);
    expect(registry.updateCalls, 0);
    expect(find.byType(SourceEditPage), findsOneWidget);
  });

  testWidgets('a failed save retains the draft and can be retried', (
    tester,
  ) async {
    final registry = _RecordingRegistry(failures: 1);
    await _openEditor(tester, registry: registry);
    await _enter(tester, 'sourceEdit.bookSourceName', 'Retry source');

    await tester.tap(find.byKey(const Key('sourceEditSave')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Could not save the source. Try again.'), findsOneWidget);
    expect(_text(tester, 'sourceEdit.bookSourceName'), 'Retry source');
    expect(registry.updateCalls, 1);

    await tester.tap(find.byKey(const Key('sourceEditSave')));
    await _pumpUntilEditorCloses(tester);

    expect(registry.updateCalls, 2);
    expect(registry.lastConfig?['bookSourceName'], 'Retry source');
    expect(find.byType(SourceEditPage), findsNothing);
  });

  testWidgets('a duplicate URL error retains the draft for correction', (
    tester,
  ) async {
    final registry = _RecordingRegistry(
      failures: 1,
      failure: const ReadingSourceEditConflictException(
        conflictingSourceId: 'other-source',
      ),
    );
    await _openEditor(tester, registry: registry);
    await _enter(
      tester,
      'sourceEdit.bookSourceUrl',
      'https://duplicate.example',
    );

    await tester.tap(find.byKey(const Key('sourceEditSave')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text(
        'Another installed source uses this URL. Enter a different URL.',
      ),
      findsOneWidget,
    );
    expect(
      _text(tester, 'sourceEdit.bookSourceUrl'),
      'https://duplicate.example',
    );
    expect(find.byType(SourceEditPage), findsOneWidget);
  });

  testWidgets('dark large-text layout fits on a narrow screen', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: SourceEditPage(source: _source(), registry: _RecordingRegistry()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sourceEditSave')), findsOneWidget);
    expect(find.byKey(const Key('sourceEditDebug')), findsOneWidget);
    expect(find.byKey(const Key('sourceEdit.bookSourceUrl')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openEditor(
  WidgetTester tester, {
  required BookSourceRegistry registry,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      home: _EditorLauncher(source: _source(), registry: registry),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  expect(find.byType(SourceEditPage), findsOneWidget);
}

Future<void> _selectTab(WidgetTester tester, String label) async {
  const labels = [
    'Basic',
    'Search',
    'Explore',
    'Book info',
    'Table of contents',
    'Content',
  ];
  tester
      .widget<TabBar>(find.byType(TabBar))
      .controller!
      .animateTo(labels.indexOf(label));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _pumpUntilEditorCloses(WidgetTester tester) async {
  for (
    var i = 0;
    i < 40 && find.byType(SourceEditPage).evaluate().isNotEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(SourceEditPage), findsNothing);
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

class _EditorLauncher extends StatelessWidget {
  const _EditorLauncher({required this.source, required this.registry});

  final RegisteredBookSource source;
  final BookSourceRegistry registry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) =>
                  SourceEditPage(source: source, registry: registry),
            ),
          ),
          child: const Text('Open editor'),
        ),
      ),
    );
  }
}

Map<String, dynamic> _config() => {
  'bookSourceName': 'Original source',
  'bookSourceUrl': 'https://source.example',
  'bookSourceGroup': 'Original group',
  'enabled': true,
  'searchUrl': '/search?q={{key}}',
  'exploreUrl': 'Latest::/latest/{{page}}',
  'ruleSearch': {
    'bookList': '.book',
    'name': '.name@text',
    'extension': {
      'labels': ['one', 'two'],
    },
  },
  'ruleExplore': {'name': '.explore-name@text', 'unknownExploreRule': true},
  'ruleBookInfo': {'name': '.info-name@text', 'unknownInfoRule': 7},
  'ruleToc': {
    'chapterList': '.chapter',
    'chapterName': '.chapter-name@text',
    'unknownTocRule': 'keep',
  },
  'ruleContent': {
    'content': '#content@textNodes',
    'unknownContentRule': ['keep'],
  },
  'unknownRoot': {
    'nested': {'keep': true},
  },
};

RegisteredBookSource _source() => ReadingSourceConfig.fromJson(
  _config(),
).toRegisteredSource(id: 'editable-source', addedAt: DateTime.utc(2026));

_MemoryRegistryStorage _seededStorage() =>
    _MemoryRegistryStorage(jsonEncode([_source().toJson()]));

class _MemoryRegistryStorage implements BookSourceRegistryStorage {
  _MemoryRegistryStorage([this.raw]);

  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}

class _RecordingRegistry extends BookSourceRegistry {
  _RecordingRegistry({this.failures = 0, this.failure});

  int failures;
  final Object? failure;
  int updateCalls = 0;
  Map<String, dynamic>? lastConfig;

  @override
  Future<List<RegisteredBookSource>> updateReadingSource(
    String id,
    Map<String, dynamic> config,
  ) async {
    updateCalls += 1;
    lastConfig = config;
    if (failures > 0) {
      failures -= 1;
      throw failure ?? StateError('write failed');
    }
    return const [];
  }
}
