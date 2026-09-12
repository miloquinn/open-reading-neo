// flutter test tool/preview_source_editor.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/source_edit_page.dart';
import 'package:xxread/utils/app_themes.dart';

void main() {
  testWidgets('capture source editor light and dark', (tester) async {
    // This explicit preview harness uses in-memory preferences like widget tests.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      final bytes = await File(
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      ).readAsBytes();
      await (FontLoader(
        'EditorPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      final root = Platform.resolvedExecutable.split('/bin/cache').first;
      final icons = await File(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
    addTearDown(tester.view.reset);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceUrl': 'https://www.baoshuxuan.com',
      'bookSourceName': '宝书网',
      'bookSourceGroup': '普通, 耽美, 言情',
      'searchUrl': '/search.html?searchkey={{key}}&searchtype=all',
      'exploreUrl':
          '最近更新::/type/0_0_0_lastupdate_{{page}}.html\n玄幻::/type/1_0_0_lastupdate_{{page}}.html',
      'ruleSearch': {
        'bookList': 'id.waterfall@class.item',
        'name': 'tag.a.0@text',
        'author': 'class.nickname@text## / 著',
      },
      'ruleExplore': {'bookList': 'id.waterfall@class.item'},
      'ruleToc': {
        'chapterList': 'li',
        'chapterName': 'tag.a@text',
        'chapterUrl': 'tag.a@href',
      },
      'ruleContent': {
        'content': 'id.chaptercontent@textNodes',
        'replaceRegex': '##[(本章完)]',
      },
    }).toRegisteredSource();
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(dark),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'EditorPreview',
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppThemes.defaultAccentColor,
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(dark ? 1.4 : 1)),
            child: RepaintBoundary(
              key: const Key('editorPreview'),
              child: child!,
            ),
          ),
          home: SourceEditPage(source: source),
        ),
      );
      await tester.pumpAndSettle();
      for (final tab in ['基本', '搜索', '发现', '详情', '目录', '正文']) {
        final target = find.widgetWithText(Tab, tab);
        await tester.ensureVisible(target);
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('editorPreview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final output = Directory('.omx/source-editor-previews')
            ..createSync(recursive: true);
          await File(
            '${output.path}/${dark ? 'dark-large' : 'light'}-$tab.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
