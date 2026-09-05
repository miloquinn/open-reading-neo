import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/pages/book_sources/controllers/book_sources_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_discovery_sections.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_pill.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/glass_control_surface.dart';

void main() {
  testWidgets(
    'pill presses to 97 percent and uses the specified release timing',
    (tester) async {
      await tester.pumpWidget(_pillHost());

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Source')),
      );
      await tester.pump();

      var scale = tester.widget<AnimatedScale>(
        find.byKey(const Key('bookSourcePillScale')),
      );
      expect(scale.scale, BookSourcePill.pressedScale);
      expect(scale.duration, BookSourcePill.pressDuration);

      await gesture.up();
      await tester.pump();
      scale = tester.widget<AnimatedScale>(
        find.byKey(const Key('bookSourcePillScale')),
      );
      expect(scale.scale, 1);
      expect(scale.duration, BookSourcePill.releaseDuration);
    },
  );

  testWidgets(
    'selected pill exposes semantics and supports keyboard activation',
    (tester) async {
      var activations = 0;
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(
        _pillHost(selected: true, onPressed: () => activations++),
      );

      expect(
        tester.getSemantics(find.byType(BookSourcePill)),
        matchesSemantics(
          label: 'Source',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
          isFocusable: true,
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(activations, 1);

      final surface = tester.widget<GlassControlSurface>(
        find.byType(GlassControlSurface),
      );
      expect(surface.duration, BookSourcePill.selectionDuration);
      expect(
        tester.getSize(find.byType(BookSourcePill)).height,
        greaterThanOrEqualTo(44),
      );
      semantics.dispose();
    },
  );

  testWidgets('reduced motion suppresses scale and transition durations', (
    tester,
  ) async {
    await tester.pumpWidget(_pillHost(disableAnimations: true));

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Source')),
    );
    await tester.pump();

    final scale = tester.widget<AnimatedScale>(
      find.byKey(const Key('bookSourcePillScale')),
    );
    final surface = tester.widget<GlassControlSurface>(
      find.byType(GlassControlSurface),
    );
    expect(scale.scale, 1);
    expect(scale.duration, Duration.zero);
    expect(surface.duration, Duration.zero);
    await gesture.up();
  });

  testWidgets('pill glass follows style and global effect preferences', (
    tester,
  ) async {
    addTearDown(() => GlassEffectConfig.setDisableAllGlassEffects(false));
    GlassEffectConfig.setDisableAllGlassEffects(false);

    await tester.pumpWidget(_pillHost(uiStyle: AppUiStyle.glass));
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.pumpWidget(_pillHost(uiStyle: AppUiStyle.material3));
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);

    GlassEffectConfig.setDisableAllGlassEffects(true);
    await tester.pumpWidget(
      _pillHost(
        key: const ValueKey('glass-disabled'),
        uiStyle: AppUiStyle.glass,
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('selected pill keeps readable defaults in both UI styles', (
    tester,
  ) async {
    await tester.pumpWidget(
      _pillHost(selected: true, uiStyle: AppUiStyle.glass),
    );
    var context = tester.element(find.byType(BookSourcePill));
    var scheme = Theme.of(context).colorScheme;
    var surface = tester.widget<GlassControlSurface>(
      find.byType(GlassControlSurface),
    );
    var label = DefaultTextStyle.of(tester.element(find.text('Source')));
    expect(surface.color, scheme.primaryContainer);
    expect(label.style.color, scheme.onPrimaryContainer);

    await tester.pumpWidget(
      _pillHost(selected: true, uiStyle: AppUiStyle.material3),
    );
    await tester.pumpAndSettle();
    context = tester.element(find.byType(BookSourcePill));
    scheme = Theme.of(context).colorScheme;
    surface = tester.widget<GlassControlSurface>(
      find.byType(GlassControlSurface),
    );
    label = DefaultTextStyle.of(tester.element(find.text('Source')));
    expect(surface.color, scheme.primary);
    expect(label.style.color, scheme.onPrimary);
  });

  testWidgets('pill can leave its surface to a shared glass parent', (
    tester,
  ) async {
    await tester.pumpWidget(_pillHost(enableSurface: false));

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(GlassControlSurface), findsNothing);
    await tester.tap(find.text('Source'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long labels remain usable with large text', (tester) async {
    await tester.pumpWidget(
      _pillHost(
        textScaler: const TextScaler.linear(2.5),
        label: 'A very long source name that must fit inside the pill',
      ),
    );

    expect(tester.getSize(find.byType(BookSourcePill)).height, greaterThan(44));
    expect(
      tester.getSize(find.byType(BookSourcePill)).width,
      lessThanOrEqualTo(280),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('category selection preserves the supplied lazy-list order', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _CategoryHarness()));

    List<String> visibleLabels() => find
        .descendant(
          of: find.byKey(const Key('bookSourceDiscoveryChannels')),
          matching: find.byType(BookSourcePill),
        )
        .evaluate()
        .map((element) => (element.widget as BookSourcePill).label)
        .toList(growable: false);

    expect(visibleLabels(), ['Alpha', 'Beta', 'Gamma', 'All']);
    await tester.tap(
      find.byKey(const Key('bookSourceDiscoveryChannel-source-gamma')),
    );
    await tester.pumpAndSettle();

    expect(visibleLabels(), ['Alpha', 'Beta', 'Gamma', 'All']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an externally selected far category is lazily revealed', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: _CategoryHarness(categoryCount: 500, showSelectLast: true),
      ),
    );

    expect(find.text('Category 499'), findsNothing);
    expect(find.byType(BookSourcePill).evaluate().length, lessThan(30));

    await tester.tap(find.byKey(const Key('selectLastCategory')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('bookSourceDiscoveryChannel-source-category-499')),
      findsOneWidget,
    );
    expect(
      find
          .byKey(const Key('bookSourceDiscoveryChannel-source-category-499'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.byType(BookSourcePill).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a visible category keeps the rail in place', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: _CategoryHarness(categoryCount: 500)),
    );
    final first = find.byKey(
      const Key('bookSourceDiscoveryChannel-source-category-0'),
    );
    final second = find.byKey(
      const Key('bookSourceDiscoveryChannel-source-category-1'),
    );
    expect(
      tester.getTopRight(second).dx,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('bookSourceCategoryPickerButton')))
            .dx,
      ),
    );
    final before = tester.getTopLeft(first).dx;
    await tester.tap(second);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(first).dx, closeTo(before, 1));
    expect(tester.takeException(), isNull);
  });
}

Widget _pillHost({
  Key? key,
  bool selected = false,
  bool disableAnimations = false,
  bool enableSurface = true,
  String label = 'Source',
  TextScaler textScaler = TextScaler.noScaling,
  VoidCallback? onPressed,
  AppUiStyle uiStyle = AppUiStyle.glass,
}) {
  return MaterialApp(
    key: key,
    theme: ThemeData(extensions: [UiStyleThemeExtension(style: uiStyle)]),
    home: MediaQuery(
      data: MediaQueryData(
        disableAnimations: disableAnimations,
        textScaler: textScaler,
      ),
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: BookSourcePill(
              label: label,
              selected: selected,
              onPressed: onPressed ?? () {},
              enableSurface: enableSurface,
            ),
          ),
        ),
      ),
    ),
  );
}

class _CategoryHarness extends StatefulWidget {
  const _CategoryHarness({this.categoryCount = 3, this.showSelectLast = false});

  final int categoryCount;
  final bool showSelectLast;

  @override
  State<_CategoryHarness> createState() => _CategoryHarnessState();
}

class _CategoryHarnessState extends State<_CategoryHarness> {
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

  late final List<SourcedBookCategory> _categories = widget.categoryCount == 3
      ? ['alpha', 'beta', 'gamma']
            .map(
              (id) => SourcedBookCategory(
                source: _source,
                id: id,
                name: '${id[0].toUpperCase()}${id.substring(1)}',
              ),
            )
            .toList(growable: false)
      : List.generate(
          widget.categoryCount,
          (index) => SourcedBookCategory(
            source: _source,
            id: 'category-$index',
            name: 'Category ${index.toString().padLeft(3, '0')}',
          ),
          growable: false,
        );
  late SourcedBookCategory _selected = _categories.first;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          if (widget.showSelectLast)
            TextButton(
              key: const Key('selectLastCategory'),
              onPressed: () => setState(() => _selected = _categories.last),
              child: const Text('Select last'),
            ),
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 600,
              child: BookSourceCategoryChannels(
                categories: _categories,
                selectedCategory: _selected,
                pickerLabel: 'All',
                onSelected: (category) => setState(() => _selected = category),
                onOpenPicker: () {},
              ),
            ),
          ),
        ],
      ),
    );
  }
}
