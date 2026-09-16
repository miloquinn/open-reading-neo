import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(320, 568),
    const Size(844, 390),
  ]) {
    testWidgets('locate follows listening and chrome visibility at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auto = ReaderAutoPageTurnController(onAdvance: () async => true);
      addTearDown(auto.dispose);
      var located = 0;
      var openedPlayer = 0;
      Future<void> show({required bool visible, required bool active}) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ReaderChromeOverlay(
                palette: ReaderThemes.day,
                visible: visible,
                readAloudActive: active,
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
                autoPageTurnController: auto,
                onReadAloud: () => openedPlayer++,
                onLocateReadAloud: () => located++,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final locate = find.byKey(const ValueKey('reader-aloud-locate'));
      await show(visible: true, active: false);
      expect(locate.hitTestable(), findsNothing);
      await show(visible: false, active: true);
      expect(locate.hitTestable(), findsNothing);
      await show(visible: true, active: true);
      expect(locate.hitTestable(), findsOneWidget);
      final rect = tester.getRect(locate);
      final autoRect = tester.getRect(
        find.byKey(const ValueKey('reader-auto-page-turn-shortcut')),
      );
      expect(rect.overlaps(autoRect), isFalse);
      expect(rect.left, greaterThan(size.width / 2));
      expect(rect.right, lessThanOrEqualTo(size.width - 8));
      await tester.tap(locate);
      expect(located, 1);
      expect(openedPlayer, 0);
      await show(visible: false, active: true);
      expect(locate.hitTestable(), findsNothing);
      final hiddenSemantics = tester.widget<ExcludeSemantics>(
        find
            .ancestor(of: locate, matching: find.byType(ExcludeSemantics))
            .first,
      );
      expect(hiddenSemantics.excluding, isTrue);
      await show(visible: true, active: false);
      expect(locate.hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
