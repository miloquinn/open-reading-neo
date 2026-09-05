import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_mobile_dashboard_page.dart';
import 'package:xxread/pages/settings/settings_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/services/books/book_services.dart';
import 'package:xxread/services/core/core_services.dart';
import 'package:xxread/services/reading/reading_stats_dao.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/layout_helper.dart';

class _FakeCacheManager extends AppCacheManager {
  @override
  Future<AppCacheUsage> usage() async => AppCacheUsage({
    for (final category in AppCacheCategory.values) category: 0,
  });
}

class _FakePreferencesStore implements SettingsPagePreferencesStore {
  @override
  Future<SettingsPagePreferences> load() async =>
      const SettingsPagePreferences();

  @override
  Future<void> save(SettingsPagePreferences preferences) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databaseDirectory = await Directory.systemTemp.createTemp(
      'open-reading-tablet-layout-test-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => databaseDirectory.path,
        );

    final bookDao = BookDao();
    final statsDao = ReadingStatsDao();
    for (var index = 0; index < 4; index++) {
      final bookId = await bookDao.insertBook(
        Book(
          title: '平板测试书 ${index + 1}',
          author: '测试作者',
          filePath: '${databaseDirectory.path}/tablet-$index.epub',
          format: 'epub',
          currentPage: 20 + index,
          totalPages: 100,
        ),
      );
      final end = DateTime.now().subtract(Duration(days: index));
      await statsDao.recordReadingSession(
        startTime: end.subtract(const Duration(minutes: 12)),
        endTime: end,
        bookId: bookId,
        pagesRead: 8,
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('平板首页使用双栏主区域、封面网格和顶部导航避让', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1366, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(useMaterial3: true),
        home: HomeMobileChromeScope(
          metrics: const HomeMobileChromeMetrics(
            systemTopInset: 24,
            systemBottomInset: 20,
            navigationAtTop: true,
          ),
          child: const Scaffold(body: HomeMobileDashboardPage()),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
    await tester.pumpAndSettle();

    final wideLayout = find.byKey(const ValueKey('home-dashboard-wide-layout'));
    final continueCard = find.byKey(
      const ValueKey('home-continue-reading-card'),
    );
    final rhythmCard = find.byKey(const ValueKey('home-reading-rhythm-card'));

    expect(wideLayout, findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-recent-books-grid')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-recent-books-carousel')),
      findsNothing,
    );
    expect(
      tester.getSize(wideLayout).width,
      lessThanOrEqualTo(LayoutHelper.tabletContentMaxWidth),
    );
    expect(tester.getCenter(wideLayout).dx, 1366 / 2);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('home-recent-book-grid-item-0')))
          .width,
      lessThanOrEqualTo(180),
    );
    expect(
      tester.getCenter(continueCard).dx,
      lessThan(tester.getCenter(rhythmCard).dx),
    );
    expect(tester.getTopLeft(continueCard).dy, greaterThanOrEqualTo(172));
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('平板设置宽屏分成逻辑双列，较窄窗口保留单列', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<void> pumpSettings(Size size) async {
      tester.view.physicalSize = size;
      final theme = ThemeNotifier();
      final appSettings = AppSettingsNotifier();
      final webDav = WebDavSyncController();
      final account = MemberAccountController();
      addTearDown(theme.dispose);
      addTearDown(appSettings.dispose);
      addTearDown(webDav.dispose);
      addTearDown(account.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider.value(value: appSettings),
            ChangeNotifierProvider.value(value: webDav),
            ChangeNotifierProvider.value(value: account),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(useMaterial3: true),
            home: HomeMobileChromeScope(
              metrics: const HomeMobileChromeMetrics(
                systemTopInset: 24,
                systemBottomInset: 20,
                navigationAtTop: true,
              ),
              child: SettingsPage(
                cacheManager: _FakeCacheManager(),
                preferencesStore: _FakePreferencesStore(),
                aiService: MockAIService(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    await pumpSettings(const Size(1024, 900));

    expect(find.byKey(const ValueKey('settings-wide-layout')), findsOneWidget);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('settings-primary-column')))
          .dx,
      lessThan(
        tester
            .getCenter(find.byKey(const ValueKey('settings-secondary-column')))
            .dx,
      ),
    );
    expect(
      find.byKey(const ValueKey('settings-single-column-layout')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);

    await pumpSettings(const Size(700, 900));

    expect(find.byKey(const ValueKey('settings-wide-layout')), findsNothing);
    expect(
      find.byKey(const ValueKey('settings-single-column-layout')),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });
}
