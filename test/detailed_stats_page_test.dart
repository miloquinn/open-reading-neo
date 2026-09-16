import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reading_stats/detailed_stats_page.dart';
import 'package:xxread/services/core/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporary;
  late Database database;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('reading_stats_widget_');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temporary.path,
        );
    // Open SQLite outside the widget fake clock and use a private directory;
    // this suite must not share a persistent /tmp database with reader tests.
    database = await DatabaseService().database;
  });
  tearDownAll(() async {
    await database.close();
    await temporary.delete(recursive: true);
  });

  testWidgets('reading stats tabs render without mobile overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF1976D2),
          fontFamily: 'SourceHanSerifCN',
        ),
        home: const DetailedStatsPage(),
      ),
    );

    // Each awaited SQLite operation may resume in the widget fake clock.
    // Pump between real I/O turns rather than assuming a single sleep drains
    // every chained query (additional schema work exposed that assumption).
    for (
      var attempt = 0;
      attempt < 100 && find.byType(PageView).evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.text('详细统计'), findsOneWidget);
    expect(find.text('账号统计与排行榜'), findsNothing);
    expect(find.text('总览'), findsOneWidget);
    expect(find.text('阅读总览'), findsOneWidget);
    expect(tester.takeException(), isNull);

    for (final pageTitle in ['阅读趋势分析', '书籍数量', '阅读成就']) {
      await tester.fling(find.byType(PageView), const Offset(-360, 0), 1000);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text(pageTitle), findsWidgets);
      expect(tester.takeException(), isNull);
    }

    for (var i = 0; i < 3; i++) {
      await tester.fling(find.byType(PageView), const Offset(360, 0), 1000);
      await tester.pump(const Duration(milliseconds: 350));
    }
    expect(find.text('阅读总览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
