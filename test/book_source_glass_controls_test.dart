import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_discovery_sections.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';

void main() {
  tearDown(() => GlassEffectConfig.setDisableAllGlassEffects(false));

  testWidgets('section track shares one blur and keeps selection interactive', (
    tester,
  ) async {
    BookSourcesSection? selected;
    await tester.pumpWidget(_host(onSelected: (section) => selected = section));
    final track = find.byKey(const Key('bookSourceSectionTrackSurface'));
    expect(
      find.descendant(of: track, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    await tester.tap(find.text('Categories'));
    await tester.pumpAndSettle();
    expect(selected, BookSourcesSection.categories);
    expect(tester.takeException(), isNull);
  });

  testWidgets('header actions and channels follow the same glass setting', (
    tester,
  ) async {
    var searches = 0;
    await tester.pumpWidget(_host(onSearch: () => searches++));
    expect(find.byType(FloatingSubpageAction), findsNWidgets(3));
    for (final action in find.byType(FloatingSubpageAction).evaluate()) {
      expect(
        find.descendant(
          of: find.byWidget(action.widget),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
    }
    await tester.tap(find.byKey(const Key('bookSourceSearchEntry')));
    await tester.pumpAndSettle();
    expect(searches, 1);

    GlassEffectConfig.setDisableAllGlassEffects(true);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);

    GlassEffectConfig.setDisableAllGlassEffects(false);
    await tester.pumpWidget(_host(style: AppUiStyle.material3));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
  });
}

Widget _host({
  AppUiStyle style = AppUiStyle.glass,
  ValueChanged<BookSourcesSection>? onSelected,
  VoidCallback? onSearch,
}) => MaterialApp(
  theme: ThemeData(extensions: [UiStyleThemeExtension(style: style)]),
  home: Scaffold(
    body: Column(
      children: [
        BookSourceRailHeader(
          title: 'Discover',
          standardLayout: true,
          layoutTooltip: 'Layout',
          searchTooltip: 'Search',
          managementTooltip: 'Manage',
          onToggleLayout: () {},
          onSearch: onSearch ?? () {},
          onManage: () {},
        ),
        BookSourceDiscoveryControls(
          sources: [
            RegisteredBookSource(
              id: 'source',
              name: 'Source',
              description: '',
              manifestUrl: Uri.parse('https://example.org/source.json'),
              apiBaseUrl: Uri.parse('https://example.org/api/'),
              protocolVersion: '1.1',
              languages: const ['en'],
              capabilities: const {'discover', 'categories', 'browse'},
              enabled: true,
              addedAt: DateTime.utc(2026),
            ),
          ],
          includeAllSources: true,
          selectedSourceId: null,
          sections: BookSourcesSection.values,
          selectedSection: BookSourcesSection.recommended,
          allLabel: 'All',
          recommendedLabel: 'Recommended',
          categoriesLabel: 'Categories',
          latestLabel: 'Latest',
          onSourceSelected: (_) {},
          onSectionSelected: onSelected ?? (_) {},
        ),
      ],
    ),
  ),
);
