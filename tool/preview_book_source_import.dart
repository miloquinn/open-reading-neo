// Run each capture separately: flutter test --no-pub tool/preview_book_source_import.dart --plain-name 'capture link'
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_add_controller.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_add_panel.dart';
import 'package:xxread/utils/app_themes.dart';

void main() {
  for (final state in ['link', 'preview', 'loading-dark', 'file-error']) {
    testWidgets('capture $state', (tester) async {
      await tester.runAsync(() async {
        final root = Platform.resolvedExecutable.split('/bin/cache/').first;
        final iconBytes = await File(
          '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(iconBytes)))).load();
        final bytes = await File(
          '/System/Library/Fonts/Hiragino Sans GB.ttc',
        ).readAsBytes();
        await (FontLoader(
          'ImportPreviewChinese',
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final text = TextEditingController(
        text: state == 'preview' ? 'https://example.org/sources.json' : '',
      );
      addTearDown(text.dispose);
      final importer = SourceImportService();
      addTearDown(importer.close);
      final preview = importer.parseDecoded([
        for (var i = 0; i < 18; i++)
          {
            'bookSourceName': '示例书源 $i',
            'bookSourceUrl': 'https://example.org/$i',
            'searchUrl': '/search?key={{key}}',
            'ruleSearch': {'bookList': '.book'},
            'ruleToc': {'chapterList': '.chapter'},
            'ruleContent': {'content': '#content'},
          },
      ]);
      final dark = state == 'loading-dark';
      final scheme = ColorScheme.fromSeed(
        seedColor: AppThemes.defaultAccentColor,
        brightness: dark ? Brightness.dark : Brightness.light,
      );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            colorScheme: scheme,
            fontFamily: 'ImportPreviewChinese',
            useMaterial3: true,
          ),
          home: RepaintBoundary(
            key: const Key('capture'),
            child: Scaffold(
              backgroundColor: scheme.surfaceContainer,
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 36),
                  child: MediaQuery(
                    data: MediaQueryData(
                      textScaler: TextScaler.linear(dark ? 1.3 : 1),
                    ),
                    child: RepaintBoundary(
                      key: const Key('panel'),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 760),
                        child: BookSourceAddPanel(
                          controller: text,
                          connecting: dark,
                          phase: dark
                              ? BookSourceAddPhase.analyzing
                              : BookSourceAddPhase.idle,
                          responsibilityAccepted: state != 'link',
                          mode: state == 'file-error'
                              ? BookSourceAddMode.file
                              : BookSourceAddMode.link,
                          analysis: state == 'preview'
                              ? BookSourceImportAnalysis.additional(preview)
                              : null,
                          errorText: state == 'file-error'
                              ? '文件不是有效的 JSON，请检查内容后重试。'
                              : null,
                          fileName: state == 'file-error' ? '我的书源.json' : null,
                          sheet: false,
                          onModeChanged: (_) {},
                          onResponsibilityChanged: (_) {},
                          onCancel: () {},
                          onAnalyzeLink: () {},
                          onChooseFile: () {},
                          onAdd: () {},
                          onReviewDedupe: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 240));
      expect(tester.takeException(), isNull);
      for (final target in ['capture', 'panel']) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(Key(target)),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final directory = Directory(
            '.omx/book-source-import-revised-previews',
          )..createSync(recursive: true);
          final suffix = target == 'panel' ? '-panel' : '';
          File(
            '${directory.path}/$state$suffix.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
    });
  }
}
