import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_source_management_page.dart';

void main() {
  Future<void> mount(WidgetTester tester, BookSourceRegistry registry) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 850);
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceManagementPage(registry: registry),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'favorite and single-source group controls work on a narrow screen',
    (tester) async {
      final registry = _MemoryRegistry([_source('alpha')], ['Useful']);
      await mount(tester, registry);

      await tester.tap(find.byKey(const ValueKey('bookSourceFavorite-alpha')));
      await tester.pumpAndSettle();
      expect((await registry.load()).single.isFavorite, isTrue);
      expect(find.byTooltip('Remove from favorites'), findsOneWidget);

      final card = find.byKey(const ValueKey('bookSourceCard-alpha'));
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit groups'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('bookSourceGroupChoice-Useful')),
      );
      await tester.tap(find.byKey(const Key('bookSourceGroupEditorDone')));
      await tester.pumpAndSettle();
      expect((await registry.load()).single.groups, ['Useful']);
      expect(
        find.descendant(of: card, matching: find.text('Useful')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'bulk grouping retains selection and empty folders remain filterable',
    (tester) async {
      final registry = _MemoryRegistry(
        [_source('alpha'), _source('beta')],
        ['Empty folder', 'Useful'],
      );
      await mount(tester, registry);

      await tester.tap(find.byKey(const Key('bookSourcesToolButton')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bookSourcesManageGroupsButton')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('bookSourcesSelectionModeButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Select all'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('bookSourceGroupSelected')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('bookSourceGroupChoice-Useful')),
      );
      await tester.tap(find.byKey(const Key('bookSourceGroupEditorDone')));
      await tester.pumpAndSettle();
      expect(
        (await registry.load()).every(
          (source) => source.groups.contains('Useful'),
        ),
        isTrue,
      );
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((checkbox) => checkbox.value == true),
        isTrue,
      );

      final filter = find.byKey(const Key('bookSourceGroupFilter'));
      await tester.dragUntilVisible(
        filter,
        find.byType(ListView).first,
        const Offset(-200, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expect(find.text('Empty folder'), findsOneWidget);
      await tester.tap(find.text('Empty folder'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('bookSourceCard-alpha')), findsNothing);
      expect(find.byKey(const ValueKey('bookSourceCard-beta')), findsNothing);
      expect(await registry.loadGroups(), ['Empty folder', 'Useful']);
      expect(tester.takeException(), isNull);
    },
  );
}

RegisteredBookSource _source(String id) => RegisteredBookSource(
  id: id,
  name: 'Source $id',
  description: 'A source for testing',
  manifestUrl: Uri.parse('https://example.org/$id/manifest.json'),
  apiBaseUrl: Uri.parse('https://example.org/$id/api'),
  protocolVersion: '1.0',
  languages: const ['en'],
  capabilities: const {'search', 'categories'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);

class _MemoryRegistry extends BookSourceRegistry {
  _MemoryRegistry(this.sources, this.groups);
  List<RegisteredBookSource> sources;
  final List<String> groups;

  @override
  Future<List<RegisteredBookSource>> load() async => sources;

  @override
  Future<List<RegisteredBookSource>> loadInBackground() async => sources;

  @override
  Future<List<String>> loadGroups() async => List.of(groups);

  @override
  Future<List<RegisteredBookSource>> setFavorite(String id, bool value) async {
    sources = [
      for (final source in sources)
        source.id == id ? source.copyWith(isFavorite: value) : source,
    ];
    return sources;
  }

  @override
  Future<List<RegisteredBookSource>> updateGroups(
    Iterable<String> ids, {
    Iterable<String> added = const [],
    Iterable<String> removed = const [],
  }) async {
    sources = [
      for (final source in sources)
        if (ids.contains(source.id))
          source.copyWith(
            groups: {
              ...source.groups.where((group) => !removed.contains(group)),
              ...added,
            }.toList(),
          )
        else
          source,
    ];
    return sources;
  }
}
