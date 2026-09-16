import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/source_book_update_info.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/library/library_event_bus_service.dart';
import 'package:xxread/pages/library/source_book_status_card.dart';

Book _book({bool bound = true}) => Book(
  id: 10,
  title: '连载小说',
  author: '作者',
  filePath: '/tmp/novel.txt',
  format: 'txt',
  sourceId: bound ? 's' : null,
  sourceBookId: bound ? 'b' : null,
  sourceJson: bound ? '{}' : null,
  sourceBookJson: bound
      ? jsonEncode({'id': 'b', 'latestChapter': '第一百章 · 新的旅途'})
      : null,
);
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final item in {
      'PreviewText': Platform.environment['SOURCE_UPDATE_PREVIEW_FONT'],
      'MaterialIcons': Platform.environment['SOURCE_UPDATE_PREVIEW_ICONS'],
    }.entries) {
      if (item.value == null) continue;
      final bytes = await File(item.value!).readAsBytes();
      await (FontLoader(
        item.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  Future<void> show(
    WidgetTester tester,
    Widget child, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          colorSchemeSeed: Colors.teal,
          useMaterial3: true,
          fontFamily: Platform.environment['SOURCE_UPDATE_PREVIEW_FONT'] == null
              ? null
              : 'PreviewText',
        ),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('open details reflect a completed background update', (
    tester,
  ) async {
    final original = _book();
    final pending = original.copyWith(
      sourceBookJson: const SourceBookUpdateInfo(
        status: SourceBookCheckStatus.available,
        newChapterCount: 2,
      ).encodeInto(original),
    );
    final completed = original.copyWith(
      contentHash: 'downloaded',
      sourceBookJson: SourceBookUpdateInfo(
        status: SourceBookCheckStatus.current,
        checkedAt: DateTime.utc(2026, 9, 16),
        latestChapter: '第一百零二章',
      ).encodeInto(original),
    );
    Book? delivered;
    await show(
      tester,
      SourceBookStatusCard(
        book: pending,
        bookLoader: (_) async => completed,
        onBookChanged: (book) => delivered = book,
      ),
    );
    expect(find.text('有新章节'), findsOneWidget);
    LibraryEventBus().notifyLibraryChanged();
    await tester.pumpAndSettle();
    expect(find.text('目录已是最新'), findsOneWidget);
    expect(find.textContaining('第一百零二章'), findsOneWidget);
    expect(delivered?.contentHash, 'downloaded');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unbound TXT offers binding and explanation without update button',
    (tester) async {
      await show(tester, SourceBookStatusCard(book: _book(bound: false)));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is TextButton && widget.onPressed != null,
        ),
        findsOneWidget,
      );
      expect(find.text('检查更新'), findsNothing);
      await tester.tap(find.byIcon(Icons.info_outline_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'check persists visible status, dates, and continuation on a narrow screen',
    (tester) async {
      final book = _book();
      var calls = 0;
      final boundaryKey = GlobalKey();
      await show(
        tester,
        RepaintBoundary(
          key: boundaryKey,
          child: SourceBookStatusCard(
            book: book,
            checkBook: (book) async {
              calls++;
              return book.copyWith(
                sourceBookJson: SourceBookUpdateInfo(
                  status: SourceBookCheckStatus.available,
                  checkedAt: DateTime.utc(2026, 9, 16, 8),
                  updatedAt: DateTime.utc(2026, 9, 15, 8),
                  latestChapter: '第一百零一章 · 新的旅途',
                  newChapterCount: 1,
                ).encodeInto(book),
              );
            },
          ),
        ),
      );
      expect(find.text('尚未检查'), findsOneWidget);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('有新章节'), findsOneWidget);
      expect(find.textContaining('上次更新于'), findsOneWidget);
      expect(find.textContaining('上次检查于'), findsOneWidget);
      expect(find.text('下载新章节'), findsOneWidget);
      expect(find.text('换源'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['SOURCE_UPDATE_PREVIEW'] != null) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            Platform.environment['SOURCE_UPDATE_PREVIEW']!,
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
  testWidgets('large text and long chapter titles wrap without overflow', (
    tester,
  ) async {
    final book = _book();
    final updated = book.copyWith(
      sourceBookJson: SourceBookUpdateInfo(
        status: SourceBookCheckStatus.needsMapping,
        checkedAt: DateTime.utc(2026, 9, 16),
        latestChapter: '这是一个非常长的章节标题，用于验证窄屏下书籍更新卡片的布局和按钮换行',
      ).encodeInto(book),
    );
    await show(tester, SourceBookStatusCard(book: updated), scale: 1.6);
    expect(find.text('待确认续更起点'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
