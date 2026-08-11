import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_list_directory.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_list_reveal.dart';

void main() {
  testWidgets('new lazy rows pop in and release their animation wrapper', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: BookSourceListReveal(
          animate: true,
          child: SizedBox(key: Key('row'), width: 100, height: 40),
        ),
      ),
    );

    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0);

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<Opacity>(find.byType(Opacity)).opacity,
      inExclusiveRange(0, 1),
    );

    await tester.pumpAndSettle();
    expect(find.byKey(const Key('row')), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('reduced motion shows lazy rows immediately', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: BookSourceListReveal(
            animate: true,
            child: SizedBox(key: Key('row')),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('row')), findsOneWidget);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
  });

  testWidgets('source categories animate open and unload after collapsing', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _DirectoryHarness()));

    await tester.tap(
      find.byKey(const Key('bookSourceListSourceToggle-source')),
    );
    await tester.pump();
    final transition = find.descendant(
      of: find.byKey(const Key('bookSourceListSource-source')),
      matching: find.byType(SizeTransition),
    );
    expect(transition, findsOneWidget);
    expect(tester.widget<SizeTransition>(transition).sizeFactor.value, 0);

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<SizeTransition>(transition).sizeFactor.value,
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('Category 000'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('bookSourceListSourceToggle-source')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Category 000'), findsNothing);
    expect(find.byType(SizeTransition), findsNothing);

    await tester.tap(
      find.byKey(const Key('bookSourceListSourceToggle-source')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Category 000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large category sets only build visible rows', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: _DirectoryHarness(channelCount: 500)),
    );
    await tester.tap(
      find.byKey(const Key('bookSourceListSourceToggle-source')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bookSourceListLazyChannels')), findsOneWidget);
    expect(find.byType(ActionChip).evaluate().length, lessThan(30));
    expect(find.text('Category 000'), findsOneWidget);
    expect(find.text('Category 499'), findsNothing);
  });
}

class _DirectoryHarness extends StatefulWidget {
  const _DirectoryHarness({this.channelCount = 1});

  final int channelCount;

  @override
  State<_DirectoryHarness> createState() => _DirectoryHarnessState();
}

class _DirectoryHarnessState extends State<_DirectoryHarness> {
  static final _source = RegisteredBookSource(
    id: 'source',
    name: 'Source',
    description: '',
    manifestUrl: Uri.parse('https://example.org/source.json'),
    apiBaseUrl: Uri.parse('https://example.org/api/'),
    protocolVersion: '1.1',
    languages: const ['en'],
    capabilities: const {'categories'},
    enabled: true,
    addedAt: DateTime.utc(2026),
  );

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final channels = List.generate(
      widget.channelCount,
      (index) => SourcedBookCategory(
        source: _source,
        id: 'category-$index',
        name: 'Category ${index.toString().padLeft(3, '0')}',
      ),
      growable: false,
    );
    final group = BookSourceListChannels(source: _source, channels: channels);
    final state = BookSourcesState(
      expandedListSourceId: _expanded ? _source.id : null,
      listChannelsBySource: {_source.id: channels},
    );
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          BookSourceListDirectory(
            searchController: TextEditingController(),
            groups: [group],
            filteredGroups: [group],
            state: state,
            searchHint: 'Search',
            clearSearchTooltip: 'Clear',
            noMatchesLabel: 'No matches',
            resetFiltersLabel: 'Reset',
            retryLabel: 'Retry',
            channelCountLabel: (count) => '$count categories',
            onQueryChanged: (_) {},
            onClearQuery: () {},
            onToggleSource: (_) => setState(() => _expanded = !_expanded),
            onExpandSource: (_) {},
            onSelectCategory: (_) {},
            shouldAnimateSource: (_) => false,
          ),
        ],
      ),
    );
  }
}
