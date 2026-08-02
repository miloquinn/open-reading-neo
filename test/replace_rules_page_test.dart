import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/replace_rules_page.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ReplaceRuleService.instance.resetForTesting();
  });

  testWidgets(
    'rule editor keeps its handle and actions inside the usable screen',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 44, bottom: 24);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ReplaceRulesPage(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      final handle = find.byKey(
        const ValueKey('replace-rule-editor-drag-handle'),
      );
      final save = find.byKey(const ValueKey('replace-rule-editor-save'));
      expect(tester.getRect(handle).top, greaterThanOrEqualTo(44));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(900));

      final editorFields = find.byKey(
        const ValueKey('replace-rule-editor-fields'),
      );
      await tester.tap(
        find
            .descendant(of: editorFields, matching: find.byType(TextField))
            .first,
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();

      expect(tester.getRect(handle).top, greaterThanOrEqualTo(44));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(580));
    },
  );
}
