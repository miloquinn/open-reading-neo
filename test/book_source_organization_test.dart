import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_organization_actions.dart';

void main() {
  testWidgets('favorite action saves immediately and offers undo', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 800);
    addTearDown(tester.view.reset);
    final registry = _FakeRegistry();
    final source = _source('one');
    var changed = 0;

    await tester.pumpWidget(
      _host(
        BookSourceOrganizationActions(
          source: source,
          registry: registry,
          onChanged: () => changed++,
        ),
      ),
    );

    final favorite = find.byKey(const ValueKey('bookSourceFavorite-one'));
    expect(tester.getSize(favorite).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(favorite).width, greaterThanOrEqualTo(44));

    await tester.tap(favorite);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(registry.favoriteWrites, [('one', true)]);
    expect(changed, 1);
    expect(find.text('Source added to favorites'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(registry.favoriteWrites, [('one', true), ('one', false)]);
    expect(changed, 2);
  });

  testWidgets('favorite undo remains safe after the source action is removed', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 800);
    addTearDown(tester.view.reset);
    final registry = _FakeRegistry();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _FavoriteRemovalHarness(registry: registry)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('bookSourceFavorite-one')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BookSourceOrganizationActions), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(registry.favoriteWrites, [('one', false), ('one', true)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorite action rolls its icon back when persistence fails', (
    tester,
  ) async {
    final registry = _FakeRegistry(favoriteError: StateError('write failed'));
    var changed = 0;

    await tester.pumpWidget(
      _host(
        BookSourceOrganizationActions(
          source: _source('one'),
          registry: registry,
          onChanged: () => changed++,
        ),
      ),
    );
    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bookSourceFavorite-one')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(registry.favoriteWrites, [('one', true)]);
    expect(find.byIcon(Icons.star_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsNothing);
    expect(find.text('Could not save the change. Try again.'), findsOneWidget);
    expect(changed, 0);
  });

  testWidgets('mixed group membership only changes touched groups', (
    tester,
  ) async {
    final registry = _FakeRegistry(groups: ['Reading', 'Backup']);
    final sources = [
      _source('one', groups: ['Reading']),
      _source('two', groups: ['Backup']),
    ];

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showBookSourceGroupEditor(
              context,
              registry: registry,
              sources: sources,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final reading = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('bookSourceGroupChoice-Reading')),
    );
    final backup = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('bookSourceGroupChoice-Backup')),
    );
    expect(reading.value, isNull);
    expect(backup.value, isNull);

    await tester.tap(find.text('Reading'));
    await tester.tap(find.byKey(const Key('bookSourceGroupEditorDone')));
    await tester.pumpAndSettle();

    expect(registry.lastUpdatedIds, {'one', 'two'});
    expect(registry.lastAdded, ['Reading']);
    expect(registry.lastRemoved, isEmpty);
  });

  testWidgets('new group is staged, checked, and discarded on cancel', (
    tester,
  ) async {
    final registry = _FakeRegistry();

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showBookSourceGroupEditor(
              context,
              registry: registry,
              sources: [_source('one')],
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bookSourceGroupEditorCreate')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('bookSourceGroupNameField')),
      'Comics',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final choice = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('bookSourceGroupChoice-Comics')),
    );
    expect(choice.value, isTrue);

    await tester.tap(find.byKey(const Key('bookSourceGroupEditorCancel')));
    await tester.pumpAndSettle();
    expect(registry.groups, isEmpty);
    expect(registry.lastAdded, isEmpty);
  });

  testWidgets('group editor reloads current memberships by source id', (
    tester,
  ) async {
    final current = _source('one', groups: ['Current']);
    final registry = _FakeRegistry(
      groups: ['Current'],
      storedSources: [current],
    );

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showBookSourceGroupEditor(
              context,
              registry: registry,
              sources: [_source('one')],
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final choice = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('bookSourceGroupChoice-Current')),
    );
    expect(choice.value, isTrue);
  });

  testWidgets('group picker searches and returns a non-empty group', (
    tester,
  ) async {
    final registry = _FakeRegistry(groups: ['Novels', 'Comics']);
    String? selection;

    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              selection = await showBookSourceOrganizationGroupPicker(
                context,
                registry: registry,
                selected: 'Novels',
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('bookSourceGroupPickerSearch')),
      'com',
    );
    await tester.pump();
    expect(find.text('Novels'), findsNothing);
    expect(find.text('Comics'), findsOneWidget);

    await tester.tap(find.text('Comics'));
    await tester.pumpAndSettle();
    expect(selection, 'Comics');
  });

  testWidgets(
    'group manager creates renames reorders and deletes without removing sources',
    (tester) async {
      final source = _source('one');
      final registry = _FakeRegistry(storedSources: [source]);

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => FilledButton(
              onPressed: () =>
                  showBookSourceGroupManager(context, registry: registry),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('No groups yet'), findsOneWidget);

      Future<void> createGroup(String name) async {
        await tester.tap(find.byKey(const Key('bookSourceGroupManagerCreate')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('bookSourceGroupNameField')),
          name,
        );
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
      }

      await createGroup('Alpha');
      await createGroup('Beta');
      expect(registry.createCalls, ['Alpha', 'Beta']);
      expect(registry.groups, ['Alpha', 'Beta']);

      await tester.tap(find.byTooltip('Rename').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bookSourceGroupNameField')),
        'Novels',
      );
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(registry.renameCalls, [('Alpha', 'Novels')]);
      expect(registry.groups, ['Novels', 'Beta']);

      final list = tester.widget<ReorderableListView>(
        find.byKey(const Key('bookSourceGroupManagerList')),
      );
      list.onReorderItem!(1, 0);
      await tester.pumpAndSettle();
      expect(registry.reorderCalls, [
        ['Beta', 'Novels'],
      ]);
      expect(registry.groups, ['Beta', 'Novels']);

      await tester.tap(find.byTooltip('Delete').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Sources in it will be kept.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(registry.deleteCalls, ['Beta']);
      expect(registry.groups, ['Novels']);
      expect(registry.storedSources, [source]);
    },
  );
}

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

RegisteredBookSource _source(
  String id, {
  List<String> groups = const [],
  bool isFavorite = false,
}) {
  return RegisteredBookSource(
    id: id,
    name: 'Source $id',
    description: '',
    manifestUrl: Uri.parse('https://$id.example/manifest'),
    apiBaseUrl: Uri.parse('https://$id.example/api'),
    protocolVersion: '1.4',
    languages: const ['en'],
    capabilities: const {'search'},
    enabled: true,
    isFavorite: isFavorite,
    groups: groups,
    addedAt: DateTime(2026),
  );
}

class _FakeRegistry extends BookSourceRegistry {
  _FakeRegistry({
    List<String> groups = const [],
    List<RegisteredBookSource> storedSources = const [],
    this.favoriteError,
  }) : groups = [...groups],
       storedSources = [...storedSources];

  final List<String> groups;
  final List<RegisteredBookSource> storedSources;
  final Object? favoriteError;
  final List<(String, bool)> favoriteWrites = [];
  final List<String> createCalls = [];
  final List<(String, String)> renameCalls = [];
  final List<String> deleteCalls = [];
  final List<List<String>> reorderCalls = [];
  Set<String> lastUpdatedIds = {};
  List<String> lastAdded = [];
  List<String> lastRemoved = [];

  @override
  Future<List<RegisteredBookSource>> load() async => List.of(storedSources);

  @override
  Future<List<RegisteredBookSource>> setFavorite(String id, bool value) async {
    favoriteWrites.add((id, value));
    if (favoriteError case final error?) throw error;
    return const [];
  }

  @override
  Future<List<String>> loadGroups() async => List.of(groups);

  @override
  Future<List<String>> createGroup(String name) async {
    createCalls.add(name);
    if (!groups.contains(name)) groups.add(name);
    return List.of(groups);
  }

  @override
  Future<List<String>> renameGroup(String oldName, String newName) async {
    renameCalls.add((oldName, newName));
    groups[groups.indexOf(oldName)] = newName;
    return List.of(groups);
  }

  @override
  Future<List<String>> deleteGroup(String name) async {
    deleteCalls.add(name);
    groups.remove(name);
    return List.of(groups);
  }

  @override
  Future<List<String>> reorderGroups(List<String> next) async {
    reorderCalls.add(List.of(next));
    groups
      ..clear()
      ..addAll(next);
    return List.of(groups);
  }

  @override
  Future<List<RegisteredBookSource>> updateGroups(
    Iterable<String> ids, {
    required Iterable<String> added,
    required Iterable<String> removed,
  }) async {
    lastUpdatedIds = ids.toSet();
    lastAdded = added.toList();
    lastRemoved = removed.toList();
    return const [];
  }
}

class _FavoriteRemovalHarness extends StatefulWidget {
  const _FavoriteRemovalHarness({required this.registry});

  final _FakeRegistry registry;

  @override
  State<_FavoriteRemovalHarness> createState() =>
      _FavoriteRemovalHarnessState();
}

class _FavoriteRemovalHarnessState extends State<_FavoriteRemovalHarness> {
  bool _visible = true;

  void _reload() {
    setState(() => _visible = widget.registry.favoriteWrites.last.$2);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return BookSourceOrganizationActions(
      source: _source('one', isFavorite: true),
      registry: widget.registry,
      onChanged: _reload,
    );
  }
}
