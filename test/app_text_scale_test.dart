import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/native_text_paginator.dart';
import 'package:xxread/core/reader/reader_text_pagination.dart';
import 'package:xxread/widgets/reader_text_page_content.dart';
import 'package:xxread/widgets/reader_chapter_title_page.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/app_text_size_sheet.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/widgets/app_text_scale.dart';

Future<AppSettingsNotifier> _loadSettings() async {
  final settings = AppSettingsNotifier();
  final loaded = Completer<void>();
  void listener() {
    if (settings.isInitialized && !loaded.isCompleted) loaded.complete();
  }

  settings.addListener(listener);
  listener();
  await loaded.future;
  settings.removeListener(listener);
  addTearDown(settings.dispose);
  return settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'five UI sizes default to 100% and persist independently of reading',
    () async {
      SharedPreferences.setMockInitialValues({'native_reader_font_size': 27.0});
      final settings = await _loadSettings();
      expect(settings.appTextScaleFactor, 1);
      expect(AppSettingsNotifier.appTextScaleFactors, [0.9, 1, 1.1, 1.2, 1.3]);
      final readerFont = settings.readerFontId;
      var notifications = 0;
      settings.addListener(() => notifications++);
      for (var level = 0; level < 5; level++) {
        await settings.setAppTextScaleLevel(level);
        final restored = await _loadSettings();
        expect(restored.appTextScaleLevel, level);
        expect(
          restored.appTextScaleFactor,
          AppSettingsNotifier.appTextScaleFactors[level],
        );
        expect(restored.readerFontId, readerFont);
        expect(
          (await SharedPreferences.getInstance()).getDouble(
            'native_reader_font_size',
          ),
          27,
        );
      }
      expect(notifications, 5);
      await settings.setAppTextScaleLevel(4);
      await settings.setAppTextScaleLevel(-1);
      await settings.setAppTextScaleLevel(5);
      expect(notifications, 5);
      expect(settings.appTextScaleFactor, 1.3);
    },
  );

  for (final invalid in [-1, 5, 999, 'large', 1.5]) {
    test('invalid stored level $invalid falls back to 100%', () async {
      SharedPreferences.setMockInitialValues({
        'app_text_scale_level_v1': invalid,
      });
      expect((await _loadSettings()).appTextScaleFactor, 1);
    });
  }

  testWidgets(
    'UI scale updates routes and dialogs without multiplying OS scale or reader body',
    (tester) async {
      final settings = (await tester.runAsync(_loadSettings))!;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: AppTextScale(child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    const Text('UI text', style: TextStyle(fontSize: 20)),
                    const ReaderTextPageContent(
                      key: ValueKey('reader-body'),
                      page: ReaderTextPage(text: 'Reader body'),
                      chapterTitle: 'Chapter',
                      bodyStyle: TextStyle(fontSize: 20),
                      flowStyle: NativeTextFlowStyle(
                        textDirection: TextDirection.ltr,
                        textScaler: readerBodyTextScaler,
                        locale: null,
                        strutStyle: null,
                        textHeightBehavior: null,
                      ),
                    ),
                    const ReaderChapterTitlePage(
                      title: 'Chapter title',
                      bodyStyle: TextStyle(fontSize: 20),
                    ),
                    const ReaderInlineChapterTitle(
                      title: 'Inline title',
                      bodyStyle: TextStyle(fontSize: 20),
                    ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            const AlertDialog(content: Text('Dialog text')),
                      ),
                      child: const Text('Open dialog'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final uiSize = tester.getSize(find.text('UI text'));
      final readerSize = tester.getSize(
        find.byKey(const ValueKey('reader-body')),
      );
      final titleSize = tester.getSize(find.text('Chapter title'));
      final inlineTitleSize = tester.getSize(find.text('Inline title'));
      await settings.setAppTextScaleLevel(4);
      await tester.pump();
      expect(
        tester.getSize(find.text('UI text')).height,
        greaterThan(uiSize.height),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('reader-body'))),
        readerSize,
      );
      expect(tester.getSize(find.text('Chapter title')), titleSize);
      expect(tester.getSize(find.text('Inline title')), inlineTitleSize);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('UI text'))).scale(20),
        26,
      );
      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.text('Dialog text')),
        ).scale(20),
        26,
      );
      await settings.setAppTextScaleLevel(0);
      await tester.pumpAndSettle();
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.text('Dialog text')),
        ).scale(20),
        18,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final locale in const [
    Locale('zh'),
    Locale('zh', 'TW'),
    Locale('en'),
    Locale('ja'),
  ]) {
    for (final size in const [Size(320, 568), Size(568, 320)]) {
      testWidgets('five choices remain reachable at 130% in $locale at $size', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final settings = (await tester.runAsync(_loadSettings))!;
        await settings.setAppTextScaleLevel(4);
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: settings,
            child: MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              builder: (context, child) => AppTextScale(child: child!),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => const AppTextSizeSheet(),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(ListTile), findsNWidgets(5));
        for (final level in [4, 0, 1, 2, 3, 4, 1]) {
          final choice = find.byKey(ValueKey('app-text-size-$level'));
          await tester.ensureVisible(choice);
          await tester.pumpAndSettle();
          expect(choice.hitTestable(), findsOneWidget);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          expect(settings.appTextScaleLevel, level);
          expect(
            (await SharedPreferences.getInstance()).getInt(
              'app_text_scale_level_v1',
            ),
            level,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
