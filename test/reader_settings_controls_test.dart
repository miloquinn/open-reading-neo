import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_settings_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'typography sliders expose discrete values and rounded callbacks',
    (tester) async {
      int? changedIndent;
      int? changedSpacing;
      int? changedFontWeight;
      int? changedTextBrightness;
      bool? dimTextInDarkMode;
      double? changedLetterSpacing;
      ReaderTextAlignment? changedAlignment;
      bool? pullBookmark;
      bool? tapAnimation;
      bool? tabletTwoPage;
      bool? txtChapterTitlePage;
      var fontPickerOpened = false;
      final autoPageTurnController = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      addTearDown(autoPageTurnController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: ReaderSettingsSheet(
            title: 'Reading settings',
            tabThemeLabel: 'Theme tab',
            tabTextLabel: 'Text tab',
            tabLayoutLabel: 'Layout tab',
            tabPagingLabel: 'Paging tab',
            advancedTypographyTitle: 'Advanced typography',
            themeDescription: 'Choose a theme',
            pageModeTitle: 'Page mode',
            pageModeSummary: 'Page curl',
            topBarStyleTitle: 'Top information',
            topBarStyleSummary: 'Reader information bar',
            pullBookmarkTitle: 'Pull bookmark',
            pullBookmarkHint: 'Pull down from the top',
            tapPageAnimationTitle: 'Tap animation',
            tapPageAnimationHint: 'Animate side taps',
            tapZonesTitle: 'Tap zones',
            tapZonesHint: 'Customize the nine tap areas',
            showTabletTwoPageToggle: true,
            tabletTwoPageTitle: 'Tablet two-page layout',
            tabletTwoPageHint: 'Show two pages in landscape',
            fontFamilyLabel: 'Font',
            fontFamilyValueLabel: 'Book and system font',
            fontFamilyHint: 'Uses the book font when available',
            onFontFamilyTap: () async {
              fontPickerOpened = true;
              return const ReaderFontChoice(
                valueLabel: 'Reader Serif',
                hint: 'Overrides the book font',
                family: 'ReaderSerif',
                fallbackFamilies: <String>[],
                supportsVariableWeight: true,
                fontWeightHint: 'True variable range 200–800',
                variableWeightMin: 200,
                variableWeightMax: 800,
              );
            },
            fontSizeLabel: 'Font size',
            textBrightnessLabel: 'Text brightness',
            dimTextInDarkModeTitle: 'Dim text in dark mode',
            dimTextInDarkModeHint: 'Use 70% brightness in dark mode',
            fontWeightLabel: 'Font weight',
            fontWeightValueLabels: const <String>[
              'Light',
              'Regular',
              'Medium',
              'Semi-bold',
              'Bold',
            ],
            fontWeightHint: 'True variable range 200–900',
            fontWeightPreviewText: 'A quiet page reads farther',
            lineHeightLabel: 'Line height',
            letterSpacingLabel: 'Letter spacing',
            textAlignmentLabel: 'Alignment',
            textAlignmentNaturalLabel: 'Natural',
            textAlignmentJustifiedLabel: 'Justified',
            firstLineIndentLabel: 'First-line indent',
            paragraphSpacingLabel: 'Paragraph spacing',
            horizontalMarginLabel: 'Horizontal margin',
            topMarginLabel: 'Top margin',
            bottomMarginLabel: 'Bottom margin',
            txtChapterTitlePageTitle: 'Chapter title on its own page',
            txtChapterTitlePageHint: 'Show the title above body text when off',
            themeId: ReaderThemes.day.id,
            fontSize: 19,
            textBrightness: 42,
            dimTextInDarkMode: true,
            fontWeight: 400,
            lineHeight: 1.7,
            letterSpacing: 0.3,
            textAlignment: ReaderTextAlignment.natural,
            firstLineIndent: 2,
            paragraphSpacing: 1,
            horizontalMargin: 18,
            topMargin: 4,
            bottomMargin: 0,
            pullBookmarkEnabled: false,
            tapPageAnimationEnabled: true,
            tabletTwoPageEnabled: true,
            txtChapterTitlePageEnabled: true,
            themeLabelFor: (themeId) => themeId,
            onThemeChanged: (_) {},
            onCustomThemeTap: () {},
            onPageModeTap: () {},
            autoPageTurnController: autoPageTurnController,
            onAutoPageTurnSettings: () {},
            onTopBarStyleTap: () {},
            onTapZonesTap: () {},
            onFontSizeChanged: (_) {},
            onTextBrightnessChanged: (value) => changedTextBrightness = value,
            onDimTextInDarkModeChanged: (value) => dimTextInDarkMode = value,
            onFontWeightChanged: (value) => changedFontWeight = value,
            onLineHeightChanged: (_) {},
            onLetterSpacingChanged: (value) => changedLetterSpacing = value,
            onTextAlignmentChanged: (value) => changedAlignment = value,
            onFirstLineIndentChanged: (value) => changedIndent = value,
            onParagraphSpacingChanged: (value) => changedSpacing = value,
            onHorizontalMarginChanged: (_) {},
            onTopMarginChanged: (_) {},
            onBottomMarginChanged: (_) {},
            onPullBookmarkChanged: (value) => pullBookmark = value,
            onTapPageAnimationChanged: (value) => tapAnimation = value,
            onTabletTwoPageChanged: (value) => tabletTwoPage = value,
            onTxtChapterTitlePageChanged: (value) =>
                txtChapterTitlePage = value,
          ),
        ),
      );

      final animatedSizeFinder = find.byKey(
        const ValueKey('reader-settings-tab-animated-size'),
      );
      final themeContentHeight = tester.getSize(animatedSizeFinder).height;
      await tester.tap(find.text('Text tab'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('reader-settings-tab-content-theme')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-settings-tab-content-text')),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('reader-settings-tab-content-theme')),
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
        findsWidgets,
      );
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('reader-settings-tab-content-theme')),
          matching: find.byWidgetPredicate(
            (widget) => widget is ExcludeSemantics && widget.excluding,
          ),
        ),
        findsWidgets,
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(animatedSizeFinder).height,
        greaterThan(themeContentHeight),
      );
      expect(
        find.byKey(const ValueKey('reader-font-choice-tile')),
        findsOneWidget,
      );
      expect(find.text('Book and system font'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reader-font-choice-tile')));
      await tester.pumpAndSettle();
      expect(fontPickerOpened, isTrue);
      expect(find.text('Reader Serif'), findsOneWidget);
      expect(find.text('Overrides the book font'), findsOneWidget);

      final textBrightnessFinder = find.descendant(
        of: find.byKey(const ValueKey('reader-text-brightness-slider')),
        matching: find.byType(Slider),
      );
      final textBrightnessSlider = tester.widget<Slider>(textBrightnessFinder);
      expect(textBrightnessSlider.value, 42);
      expect(textBrightnessSlider.min, 0);
      expect(textBrightnessSlider.max, 100);
      textBrightnessSlider.onChanged!(67.4);
      await tester.pump();
      tester.widget<Slider>(textBrightnessFinder).onChangeEnd!(67.4);
      expect(changedTextBrightness, 67);
      final dimSwitch = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Dim text in dark mode'),
      );
      dimSwitch.onChanged!(false);
      expect(dimTextInDarkMode, isFalse);
      final fontWeightFinder = find.byKey(
        const ValueKey('reader-font-weight-slider'),
      );
      final initialFontWeight = tester.widget<Slider>(fontWeightFinder);
      expect(initialFontWeight.value, 400);
      expect(initialFontWeight.min, 300);
      expect(initialFontWeight.max, 700);
      expect(initialFontWeight.divisions, 4);
      expect(find.text('Regular · 400'), findsOneWidget);
      expect(find.text('A quiet page reads farther'), findsOneWidget);
      initialFontWeight.onChanged!(600);
      await tester.pump();
      expect(tester.widget<Slider>(fontWeightFinder).value, 600);
      expect(find.text('Semi-bold · 600'), findsOneWidget);
      final weightPreviewStyle = tester
          .widget<AnimatedDefaultTextStyle>(
            find.descendant(
              of: find.byKey(const ValueKey('reader-font-weight-control')),
              matching: find.byType(AnimatedDefaultTextStyle),
            ),
          )
          .style;
      expect(weightPreviewStyle.fontWeight, FontWeight.w600);
      tester.widget<Slider>(fontWeightFinder).onChangeEnd!(600);
      expect(changedFontWeight, 600);
      expect(
        find.byKey(const ValueKey('reader-letter-spacing-slider')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-advanced-typography-tile')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Advanced typography'));
      await tester.pumpAndSettle();

      final indentFinder = find.descendant(
        of: find.byKey(const ValueKey('reader-first-line-indent-slider')),
        matching: find.byType(Slider),
      );
      final spacingFinder = find.descendant(
        of: find.byKey(const ValueKey('reader-paragraph-spacing-slider')),
        matching: find.byType(Slider),
      );
      final letterSpacingFinder = find.descendant(
        of: find.byKey(const ValueKey('reader-letter-spacing-slider')),
        matching: find.byType(Slider),
      );

      final initialIndent = tester.widget<Slider>(indentFinder);
      expect(initialIndent.value, 2);
      expect(initialIndent.min, 0);
      expect(initialIndent.max, 4);
      expect(initialIndent.divisions, 4);

      final initialSpacing = tester.widget<Slider>(spacingFinder);
      expect(initialSpacing.value, 1);
      expect(initialSpacing.min, 0);
      expect(initialSpacing.max, 2);
      expect(initialSpacing.divisions, 2);

      final initialLetterSpacing = tester.widget<Slider>(letterSpacingFinder);
      expect(initialLetterSpacing.value, 0.3);
      expect(initialLetterSpacing.min, ReaderSettings.minLetterSpacing);
      expect(initialLetterSpacing.max, ReaderSettings.maxLetterSpacing);

      initialIndent.onChanged!(3.6);
      await tester.pump();
      expect(tester.widget<Slider>(indentFinder).value, 4);
      tester.widget<Slider>(indentFinder).onChangeEnd!(3.6);

      initialSpacing.onChanged!(1.6);
      await tester.pump();
      expect(tester.widget<Slider>(spacingFinder).value, 2);
      tester.widget<Slider>(spacingFinder).onChangeEnd!(1.6);

      initialLetterSpacing.onChanged!(0.8);
      await tester.pump();
      tester.widget<Slider>(letterSpacingFinder).onChangeEnd!(0.8);
      tester
          .widget<SegmentedButton<ReaderTextAlignment>>(
            find.byKey(const ValueKey('reader-text-alignment-control')),
          )
          .onSelectionChanged!({ReaderTextAlignment.justified});
      await tester.pump();

      expect(changedIndent, 4);
      expect(changedSpacing, 2);
      expect(changedLetterSpacing, 0.8);
      expect(changedAlignment, ReaderTextAlignment.justified);

      await tester.ensureVisible(find.text('Layout tab'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Layout tab'));
      await tester.pumpAndSettle();
      final titlePageSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('reader-txt-chapter-title-page-switch')),
      );
      expect(titlePageSwitch.value, isTrue);
      titlePageSwitch.onChanged!(false);
      expect(txtChapterTitlePage, isFalse);

      await tester.tap(find.text('Theme tab'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(ReaderThemeStrip));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ReaderThemeStrip), const Offset(-900, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reader-custom-theme-card')), findsOne);

      await tester.tap(find.text('Paging tab'));
      await tester.pumpAndSettle();
      final pullSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('reader-pull-bookmark-switch')),
      );
      final animationSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('reader-tap-page-animation-switch')),
      );
      final tabletSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('reader-tablet-two-page-switch')),
      );
      final shortcutSwitch = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('reader-auto-page-turn-shortcut-switch')),
      );
      expect(shortcutSwitch.value, isTrue);
      pullSwitch.onChanged!(true);
      animationSwitch.onChanged!(false);
      tabletSwitch.onChanged!(false);
      shortcutSwitch.onChanged!(false);
      await tester.pump();
      expect(pullBookmark, isTrue);
      expect(tapAnimation, isFalse);
      expect(tabletTwoPage, isFalse);
      expect(autoPageTurnController.shortcutVisible, isFalse);
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(
                const ValueKey('reader-auto-page-turn-shortcut-switch'),
              ),
            )
            .value,
        isFalse,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('reader-settings-tab-bar')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Text tab'));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(textBrightnessFinder).value, 67);

      await tester.tap(find.text('Layout tab'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Paging tab'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Theme tab'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Text tab'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('reader-settings-tab-content-text')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-settings-tab-content-theme')),
        findsNothing,
      );

      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      expect(
        tester.widget<AnimatedSize>(animatedSizeFinder).duration,
        Duration.zero,
      );
      expect(
        tester
            .widget<AnimatedSwitcher>(
              find.byKey(const ValueKey('reader-settings-tab-switcher')),
            )
            .duration,
        Duration.zero,
      );
    },
  );

  testWidgets('top bar style sheet offers all shared reader styles', (
    tester,
  ) async {
    var selectedStyle = ReaderTopBarStyle.reader;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ReaderTopBarStyleSheet(
              palette: ReaderThemes.day,
              title: 'Top information',
              selectedStyle: selectedStyle,
              titleFor: (style) => style.name,
              hintFor: (style) => '${style.name} hint',
              onSelected: (style) {
                setState(() => selectedStyle = style);
              },
            ),
          ),
        ),
      ),
    );

    for (final style in ReaderTopBarStyle.values) {
      expect(
        find.byKey(ValueKey('reader-top-bar-style-${style.name}')),
        findsOneWidget,
      );
    }

    await tester.tap(find.text('floating'));
    await tester.pump();
    expect(selectedStyle, ReaderTopBarStyle.floating);

    await tester.tap(find.text('hidden'));
    await tester.pump();
    expect(selectedStyle, ReaderTopBarStyle.hidden);
  });

  testWidgets('selected theme card paints its border above the background', (
    tester,
  ) async {
    ReaderThemes.setCustomThemes(const []);
    ReaderThemes.setThemeOrder(const []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderThemeStrip(
            selectedThemeId: ReaderThemes.day.id,
            labelFor: (id) => id,
            onSelected: (_) {},
            onCustomThemeTap: () {},
          ),
        ),
      ),
    );

    final card = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(const ValueKey('reader-theme-day')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is AnimatedContainer &&
              widget.clipBehavior == Clip.antiAlias,
        ),
      ),
    );
    final decoration = card.decoration! as BoxDecoration;
    final foreground = card.foregroundDecoration! as BoxDecoration;

    expect(decoration.border, isNull);
    expect(foreground.border, isNotNull);
    expect(foreground.borderRadius, BorderRadius.circular(18));
  });

  testWidgets('system theme card is the first reading theme option', (
    tester,
  ) async {
    ReaderThemes.setCustomThemes(const []);
    ReaderThemes.setThemeOrder(const []);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderThemeStrip(
            selectedThemeId: ReaderThemes.systemId,
            labelFor: (id) => id,
            onSelected: (_) {},
            onCustomThemeTap: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('reader-theme-system')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('reader-theme-system'))).dx,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('reader-theme-day'))).dx,
      ),
    );
  });

  testWidgets('theme strip accepts mouse drag and vertical wheel scrolling', (
    tester,
  ) async {
    ReaderThemes.setCustomThemes(const []);
    ReaderThemes.setThemeOrder(const []);
    final outerController = ScrollController();
    addTearDown(outerController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 240,
              child: SingleChildScrollView(
                controller: outerController,
                child: Column(
                  children: [
                    ReaderThemeStrip(
                      selectedThemeId: ReaderThemes.systemId,
                      labelFor: (id) => id,
                      onSelected: (_) {},
                      onCustomThemeTap: () {},
                    ),
                    const SizedBox(height: 400),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final listView = tester.widget<ListView>(
      find.descendant(
        of: find.byType(ReaderThemeStrip),
        matching: find.byType(ListView),
      ),
    );
    final controller = listView.controller!;
    expect(controller.offset, 0);

    final stripCenter = tester.getCenter(find.byType(ReaderThemeStrip));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: stripCenter,
        scrollDelta: const Offset(0, 100),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    expect(outerController.offset, 0);

    final offsetAfterWheel = controller.offset;
    final mouse = await tester.startGesture(
      stripCenter,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveBy(const Offset(-20, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(-100, 0));
    await tester.pump();
    await mouse.up();
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(offsetAfterWheel));

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: stripCenter,
        scrollDelta: const Offset(0, 100),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    expect(outerController.offset, greaterThan(0));
  });
}
