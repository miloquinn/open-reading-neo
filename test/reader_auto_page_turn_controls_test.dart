import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_auto_page_turn_controls.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('interval sheet returns the selected interval on start', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    ReaderAutoPageTurnSelection? selection;

    await tester.pumpWidget(
      _localizedApp(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              selection = await showReaderAutoPageTurnSheet(
                context: context,
                palette: ReaderThemes.day,
                controller: controller,
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-auto-page-turn-interval-slider')),
    );
    slider.onChanged!(25);
    await tester.pump();
    final startButton = find.byKey(
      const ValueKey('reader-auto-page-turn-start'),
    );
    await tester.ensureVisible(startButton);
    await tester.pumpAndSettle();
    await tester.tap(startButton);
    await tester.pumpAndSettle();

    expect(selection?.mode, ReaderAutoPageTurnMode.timed);
    expect(selection?.seconds, 25);
    expect(controller.isActive, isFalse);
    controller.dispose();
  });

  testWidgets(
    'sheet offers the correct group and sweep defaults to 10 seconds',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      ReaderAutoPageTurnSelection? selection;

      await tester.pumpWidget(
        _localizedApp(
          Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selection = await showReaderAutoPageTurnSheet(
                  context: context,
                  palette: ReaderThemes.day,
                  controller: controller,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Timed page turn'), findsOneWidget);
      expect(find.text('Sweep page turn'), findsOneWidget);
      expect(find.text('Continuous scroll'), findsNothing);
      await tester.tap(find.text('Sweep page turn'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Slider>(
              find.byKey(
                const ValueKey('reader-auto-page-turn-interval-slider'),
              ),
            )
            .value,
        10,
      );
      final startButton = find.byKey(
        const ValueKey('reader-auto-page-turn-start'),
      );
      await tester.ensureVisible(startButton);
      await tester.pumpAndSettle();
      await tester.tap(startButton);
      await tester.pumpAndSettle();
      expect(selection?.mode, ReaderAutoPageTurnMode.sweep);
      expect(selection?.seconds, 10);
      controller.dispose();
    },
  );

  testWidgets('vertical sheet offers continuous and interval scrolling', (
    tester,
  ) async {
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );

    await tester.pumpWidget(
      _localizedApp(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showReaderAutoPageTurnSheet(
              context: context,
              palette: ReaderThemes.day,
              controller: controller,
              vertical: true,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Continuous scroll'), findsOneWidget);
    expect(find.text('Interval scroll'), findsOneWidget);
    expect(find.text('Timed page turn'), findsNothing);
    controller.dispose();
  });

  testWidgets('active chrome can pause, resume, and stop auto page turn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    var resumes = 0;
    controller.start();

    await tester.pumpWidget(
      _localizedApp(
        ReaderChromeOverlay(
          palette: ReaderThemes.day,
          visible: true,
          title: 'Chapter',
          statusBottom: 8,
          statusBuilder: (context, style, key) =>
              Text('1 / 2', key: key, style: style),
          onBack: () {},
          onBookmark: () {},
          onTableOfContents: () {},
          onSettings: () {},
          backTooltip: 'Back',
          bookmarkTooltip: 'Bookmark',
          tableOfContentsTooltip: 'Contents',
          settingsTooltip: 'Settings',
          bookmarked: false,
          autoPageTurnController: controller,
          onResumeAutoPageTurn: () {
            resumes++;
            controller.start();
          },
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('reader-auto-page-turn-control-bar')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('reader-auto-page-turn-pause')));
    await tester.pump();
    expect(controller.isActive, isTrue);
    expect(controller.isRunning, isFalse);

    await tester.tap(
      find.byKey(const ValueKey('reader-auto-page-turn-resume')),
    );
    await tester.pump();
    expect(resumes, 1);
    expect(controller.isRunning, isTrue);

    await tester.tap(find.byKey(const ValueKey('reader-auto-page-turn-stop')));
    await tester.pump();
    expect(controller.isActive, isFalse);
    final bar = find.byKey(const ValueKey('reader-auto-page-turn-control-bar'));
    expect(bar, findsOneWidget);
    final restingTop = tester.getTopLeft(bar).dy;
    await tester.pump(const Duration(milliseconds: 120));
    expect(bar, findsOneWidget);
    expect(tester.getTopLeft(bar).dy, greaterThan(restingTop));
    expect(tester.getTopLeft(bar).dy, lessThan(700));
    _expectNoGlassFade(tester, bar);
    await tester.pump(const Duration(milliseconds: 400));
    expect(bar, findsNothing);

    controller.dispose();
  });
  testWidgets(
    'right shortcut starts pauses and resumes without opening settings',
    (tester) async {
      final controller = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      addTearDown(controller.dispose);
      var starts = 0;
      await tester.pumpWidget(
        _localizedApp(
          ReaderChromeOverlay(
            palette: ReaderThemes.day,
            visible: true,
            title: 'Chapter',
            statusBottom: 8,
            statusBuilder: (context, style, key) =>
                Text('1 / 2', key: key, style: style),
            onBack: () {},
            onBookmark: () {},
            onTableOfContents: () {},
            onSettings: () {},
            backTooltip: 'Back',
            bookmarkTooltip: 'Bookmark',
            tableOfContentsTooltip: 'Contents',
            settingsTooltip: 'Settings',
            bookmarked: false,
            autoPageTurnController: controller,
            onResumeAutoPageTurn: () {
              starts++;
              controller.start();
            },
          ),
        ),
      );
      final shortcut = find.byKey(
        const ValueKey('reader-auto-page-turn-shortcut'),
      );
      expect(shortcut, findsOneWidget);
      expect(tester.getCenter(shortcut).dx, greaterThan(700));
      await tester.tap(shortcut);
      await tester.pump();
      expect(starts, 1);
      expect(controller.isRunning, isTrue);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(shortcut);
      await tester.pump();
      expect(controller.isRunning, isFalse);
      expect(controller.smoothPauseRequested, isTrue);
      await tester.tap(shortcut);
      await tester.pump();
      expect(starts, 2);
      expect(controller.isRunning, isTrue);
      controller.stop();
      await tester.pump(const Duration(milliseconds: 450));
    },
  );
  testWidgets('shortcut follows chrome with animated entry and exit', (
    tester,
  ) async {
    final visible = ValueNotifier(false);
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    addTearDown(visible.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _localizedApp(
        ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, shown, _) => ReaderChromeOverlay(
            palette: ReaderThemes.day,
            visible: shown,
            title: 'Chapter',
            statusBottom: 8,
            statusBuilder: (context, style, key) =>
                Text('1 / 2', key: key, style: style),
            onBack: () {},
            onBookmark: () {},
            onTableOfContents: () {},
            onSettings: () {},
            backTooltip: 'Back',
            bookmarkTooltip: 'Bookmark',
            tableOfContentsTooltip: 'Contents',
            settingsTooltip: 'Settings',
            bookmarked: false,
            autoPageTurnController: controller,
          ),
        ),
      ),
    );
    final shortcut = find.byKey(
      const ValueKey('reader-auto-page-turn-shortcut'),
    );
    double left() => tester.getTopLeft(shortcut).dx;
    final hiddenLeft = left();
    expect(hiddenLeft, greaterThanOrEqualTo(800));
    expect(shortcut.hitTestable(), findsNothing);

    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(left(), inExclusiveRange(700, hiddenLeft));
    await tester.pump(const Duration(milliseconds: 260));
    final restingLeft = left();
    expect(tester.getTopRight(shortcut).dx, lessThan(800));
    expect(shortcut.hitTestable(), findsOneWidget);
    await tester.tap(shortcut);
    await tester.pump();
    expect(controller.isRunning, isTrue);

    visible.value = false;
    await tester.pump();
    expect(shortcut.hitTestable(), findsNothing);
    await tester.pump(const Duration(milliseconds: 120));
    expect(left(), inExclusiveRange(restingLeft, hiddenLeft));
    expect(controller.isRunning, isTrue);
    await tester.pump(const Duration(milliseconds: 350));
    expect(left(), greaterThanOrEqualTo(800));
    expect(shortcut.hitTestable(), findsNothing);

    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final partial = left();
    visible.value = false;
    await tester.pump();
    expect(left(), closeTo(partial, 0.001));
    await tester.pump(const Duration(milliseconds: 80));
    visible.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(left(), closeTo(restingLeft, 0.01));
    _expectNoGlassFade(tester, shortcut);
    await controller.setShortcutVisible(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(left(), inExclusiveRange(restingLeft, hiddenLeft));
    expect(controller.isRunning, isTrue);
    await tester.pump(const Duration(milliseconds: 350));
    expect(left(), greaterThanOrEqualTo(800));
    expect(shortcut.hitTestable(), findsNothing);
    await controller.setShortcutVisible(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(left(), closeTo(restingLeft, 0.01));
    expect(shortcut.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.stop();
    await tester.pumpAndSettle();
  });
}

Widget _localizedApp(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

void _expectNoGlassFade(WidgetTester tester, Finder surface) {
  expect(
    find.ancestor(of: surface, matching: find.byType(AnimatedOpacity)),
    findsNothing,
  );
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(of: surface, matching: find.byType(FadeTransition)),
  )) {
    expect(fade.opacity.value, 1);
  }
}
