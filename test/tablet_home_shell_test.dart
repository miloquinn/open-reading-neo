import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/home_navigation_destination.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/pages/home/widgets/home_bounce_navigation_item.dart';
import 'package:xxread/pages/home/widgets/home_tablet_toolbar.dart';
import 'package:xxread/pages/settings/settings_page.dart';
import 'package:xxread/services/ai/ai_chat_history_store.dart';
import 'package:xxread/services/core/theme_notifier.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/services/account/account.dart';
import 'package:xxread/services/books/book_services.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/reading/reading_stats_dao.dart';
import 'package:xxread/utils/layout_helper.dart';
import 'package:xxread/utils/ui_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dataDirectory;
  final screenshotDirectory = Platform.environment['TABLET_SCREENSHOT_DIR'];

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dataDirectory = await Directory.systemTemp.createTemp('tablet-shell-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dataDirectory.path,
        );
    if (screenshotDirectory != null) {
      final fontPath = Platform.environment['TABLET_PREVIEW_FONT'];
      if (fontPath != null) {
        for (final family in ['TabletPreview']) {
          final loader = FontLoader(family);
          loader.addFont(
            File(fontPath).readAsBytes().then(ByteData.sublistView),
          );
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons');
        icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      }
    }
    // Preview-only sample cover files exercise the same image path as imported books.
    // Canvas text without an explicit family uses Ahem in flutter_tester.
    Future<String?> previewCover(int index, String title) async {
      if (screenshotDirectory == null) return null;
      const colors = [
        Color(0xFFE7EEDC),
        Color(0xFFE9DFCD),
        Color(0xFFDCE6E8),
        Color(0xFFE6DFEB),
        Color(0xFFF0E5DC),
        Color(0xFFDCE5DA),
      ];
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(colors[index], BlendMode.src);
      final ink = Paint()..color = const Color(0xFF304749);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 12, 540), ink);
      canvas.drawRect(const Rect.fromLTWH(38, 48, 58, 4), ink);
      final titlePainter = TextPainter(
        text: TextSpan(
          text: title,
          style: const TextStyle(
            fontFamily: 'TabletPreview',
            fontSize: 38,
            height: 1.5,
            color: Color(0xFF304749),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 280);
      titlePainter.paint(canvas, const Offset(38, 176));
      titlePainter.dispose();
      canvas.drawRect(const Rect.fromLTWH(38, 442, 110, 1), ink);
      final picture = recorder.endRecording();
      final image = await picture.toImage(360, 540);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${dataDirectory.path}/cover-$index.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      PaintingBinding.instance.imageCache.putIfAbsent(
        await FileImage(file).obtainKey(ImageConfiguration.empty),
        () => OneFrameImageStreamCompleter(
          Future.value(ImageInfo(image: image.clone())),
        ),
      );
      if (index == 0) {
        // Seed the hero's resized variants: flutter_tester can stall on native
        // resize codecs while its fake clock is suspended for screenshot IO.
        for (final width in [102, 118]) {
          final key = await ResizeImage(
            FileImage(file),
            width: width,
          ).obtainKey(ImageConfiguration.empty);
          PaintingBinding.instance.imageCache.putIfAbsent(
            key,
            () => OneFrameImageStreamCompleter(
              Future.value(ImageInfo(image: image.clone())),
            ),
          );
        }
      }
      picture.dispose();
      image.dispose();
      return file.path;
    }

    final titles = ['瓦尔登湖', '小王子', '人类群星闪耀时', '月亮与六便士', '山茶文具店', '悉达多'];
    for (var i = 0; i < titles.length; i++) {
      final id = await BookDao().insertBook(
        Book(
          title: titles[i],
          coverImagePath: await previewCover(i, titles[i]),
          author: [
            '亨利·戴维·梭罗',
            '安托万·德·圣埃克苏佩里',
            '斯蒂芬·茨威格',
            '威廉·萨默塞特·毛姆',
            '小川糸',
            '赫尔曼·黑塞',
          ][i],
          filePath: '${dataDirectory.path}/sample-$i.epub',
          format: 'epub',
          currentPage: 32 + i * 10,
          totalPages: 240,
        ),
      );
      final end = DateTime.now().subtract(Duration(days: i));
      await ReadingStatsDao().recordReadingSession(
        startTime: end.subtract(Duration(minutes: 20 + i * 4)),
        endTime: end,
        bookId: id,
        pagesRead: 12,
      );
    }
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
    'touch window breakpoints preserve desktop rail and narrow mode',
    (tester) async {
      Future<void> verify(
        Size size,
        TargetPlatform platform,
        bool tablet,
        NavigationType navigation,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: size),
              child: Builder(
                builder: (context) {
                  expect(LayoutHelper.usesTabletLayout(context), tablet);
                  expect(LayoutHelper.getNavigationType(context), navigation);
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
      }

      await verify(
        const Size(744, 1133),
        TargetPlatform.iOS,
        true,
        NavigationType.bottom,
      );
      await verify(
        const Size(1366, 1024),
        TargetPlatform.iOS,
        true,
        NavigationType.bottom,
      );
      await verify(
        const Size(600, 960),
        TargetPlatform.android,
        true,
        NavigationType.bottom,
      );
      await verify(
        const Size(599, 960),
        TargetPlatform.iOS,
        false,
        NavigationType.bottom,
      );
      await verify(
        const Size(844, 390),
        TargetPlatform.iOS,
        false,
        NavigationType.bottom,
      );
      await verify(
        const Size(1366, 1024),
        TargetPlatform.macOS,
        false,
        NavigationType.rail,
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'tablet chrome reserves the top navigation and releases bottom space',
    () {
      final metrics = HomeMobileChromeMetrics.fromMediaQuery(
        const MediaQueryData(
          size: Size(834, 1194),
          viewPadding: EdgeInsets.only(top: 24, bottom: 20),
        ),
        navigationAtTop: true,
        floatingNavHeight: 60,
      );
      expect(metrics.navigationTopInset, 36);
      expect(metrics.toolbarTopInset, 108);
      expect(metrics.pageTopPadding, 208);
      expect(metrics.pageBottomPadding, 40);
      expect(metrics.floatingActionBottomMargin, 35);
    },
  );

  testWidgets('tablet navigation survives rotation and compact window resize', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final history = AiChatHistoryStore();
    final theme = ThemeNotifier();
    final webDav = WebDavSyncController();
    final account = MemberAccountController();
    addTearDown(theme.dispose);
    addTearDown(webDav.dispose);
    addTearDown(account.dispose);
    final settings = AppSettingsNotifier();
    addTearDown(history.dispose);
    addTearDown(settings.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await settings.setHideNavigationLabels(false);
    await settings.setHomeNavigationDestinationVisible(
      HomeNavigationDestination.ai,
      true,
    );
    final boundaryKey = GlobalKey();

    Future<void> pumpSize(
      Size size, {
      Brightness brightness = Brightness.light,
      double keyboard = 0,
      double scale = 1,
    }) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: theme),
            ChangeNotifierProvider.value(value: webDav),
            ChangeNotifierProvider.value(value: account),
          ],
          child: MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              brightness: brightness,
              colorSchemeSeed: const Color(0xFF356C88),
              fontFamily: screenshotDirectory != null ? 'TabletPreview' : null,
              extensions: const [
                UiStyleThemeExtension(style: AppUiStyle.glass),
              ],
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                viewPadding: const EdgeInsets.only(top: 24, bottom: 20),
                viewInsets: EdgeInsets.only(bottom: keyboard),
                textScaler: TextScaler.linear(scale),
              ),
              child: RepaintBoundary(
                key: boundaryKey,
                child: HomeShellPage(aiChatHistoryStore: history),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    }

    Finder nav(HomeNavigationDestination destination) => find.byWidgetPredicate(
      (w) => w is HomeBounceNavigationItem && w.item.destination == destination,
    );
    Future<void> capture(String name) async {
      if (screenshotDirectory == null) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      for (final rawImage in tester.widgetList<RawImage>(
        find.byType(RawImage),
      )) {
        expect(
          rawImage.image,
          isNotNull,
          reason: 'Preview images must finish loading.',
        );
      }
      await tester.runAsync(() async {
        final image =
            await (boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(screenshotDirectory).create(recursive: true);
        await File(
          '$screenshotDirectory/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await pumpSize(const Size(834, 1194));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byKey(const ValueKey('glass-top-bar-surface')), findsNothing);
    expect(
      tester.getTopLeft(nav(HomeNavigationDestination.home)).dy,
      lessThan(100),
    );
    expect(
      tester.getTopLeft(find.byType(HomeTabletToolbar)).dy,
      greaterThan(90),
    );
    expect(
      tester.widget<PageView>(find.byType(PageView).first).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    void expectPageLeftAligned(String title, Finder content) {
      final heading = find.descendant(
        of: find.byType(HomeTabletToolbar),
        matching: find.text(title),
      );
      expect(
        tester.getTopLeft(heading).dx,
        closeTo(tester.getTopLeft(content).dx, 0.1),
      );
    }

    final continueCard = find.byKey(
      const ValueKey('home-continue-reading-card'),
    );
    final rhythmCard = find.byKey(const ValueKey('home-reading-rhythm-card'));
    expectPageLeftAligned('首页', continueCard);
    await capture('tablet-home-portrait');

    await pumpSize(const Size(1194, 834));
    expectPageLeftAligned('首页', continueCard);
    final toolbar = find.byType(HomeTabletToolbar);
    expect(
      tester.getCenter(toolbar).dy,
      closeTo(tester.getCenter(nav(HomeNavigationDestination.home)).dy, 0.1),
    );
    expect(
      tester.getCenter(nav(HomeNavigationDestination.discover)).dx,
      closeTo(1194 / 2, 0.1),
    );
    expect(
      tester.getTopLeft(continueCard).dy,
      closeTo(tester.getTopLeft(rhythmCard).dy, 0.1),
    );
    expect(
      tester.getBottomLeft(continueCard).dy,
      closeTo(tester.getBottomLeft(rhythmCard).dy, 0.1),
    );
    await capture('tablet-home-landscape');
    await pumpSize(const Size(1366, 1024));
    expectPageLeftAligned('首页', continueCard);
    expect(tester.getTopLeft(continueCard).dx, 111);
    expect(tester.getBottomRight(rhythmCard).dx, 1366 - 111);
    await capture('tablet-home-large-landscape');
    await pumpSize(const Size(1194, 834));

    await tester.tap(nav(HomeNavigationDestination.library));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    expect(
      tester
          .widget<HomeBounceNavigationItem>(
            nav(HomeNavigationDestination.library),
          )
          .isSelected,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    final libraryGrid = tester.widget<GridView>(
      find.byKey(const ValueKey('library-cover-grid')),
    );
    final libraryPadding = libraryGrid.padding! as EdgeInsets;
    final libraryTitle = find.descendant(
      of: find.byType(HomeTabletToolbar),
      matching: find.text('书架'),
    );
    expect(
      tester.getTopLeft(libraryTitle).dx,
      closeTo(libraryPadding.left, 0.1),
    );
    final actions = find.descendant(
      of: toolbar,
      matching: find.byIcon(Icons.search_rounded),
    );
    expect(tester.getCenter(actions).dy, tester.getCenter(toolbar).dy);
    expect(
      tester.getTopLeft(actions).dx,
      greaterThan(
        tester.getBottomRight(nav(HomeNavigationDestination.settings)).dx,
      ),
    );
    await capture('tablet-library-landscape');
    await pumpSize(const Size(834, 1194));
    await tester.longPress(find.text('悉达多').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(
        AppLocalizations.of(tester.element(toolbar)).librarySelectMultiple,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-delete-selected')),
      findsOneWidget,
    );
    expect(tester.getTopLeft(toolbar).dy, lessThan(50));
    expect(find.byType(HomeBounceNavigationItem), findsNothing);
    await capture('tablet-library-selection');
    await tester.tap(
      find.descendant(of: toolbar, matching: find.byIcon(Icons.close_rounded)),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toolbar).dy, greaterThan(90));
    await pumpSize(const Size(1194, 834));

    await tester.tap(nav(HomeNavigationDestination.discover));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
    await capture('tablet-discover-landscape');

    await tester.tap(nav(HomeNavigationDestination.settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);
    expectPageLeftAligned(
      '设置',
      find.byKey(const ValueKey('settings-account-card')),
    );
    await capture('tablet-settings-landscape');
    final settingsScroll = find.descendant(
      of: find.byType(SettingsPage),
      matching: find.byType(ListView),
    );
    final fixedTitlePosition = tester.getTopLeft(toolbar);
    await tester.drag(settingsScroll, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toolbar), fixedTitlePosition);
    expect(find.byKey(const ValueKey('glass-top-bar-surface')), findsNothing);
    await capture('tablet-settings-scrolled-gradient');
    await tester.drag(settingsScroll, const Offset(0, -160));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(toolbar), fixedTitlePosition);
    await capture('tablet-settings-scrolled-content');
    tester.widget<ListView>(settingsScroll).controller!.jumpTo(0);
    await tester.pump();
    await pumpSize(const Size(1366, 1024));
    final accountCard = find.byKey(const ValueKey('settings-account-card'));
    expectPageLeftAligned('设置', accountCard);
    expect(tester.getTopLeft(accountCard).dx, 111);
    expect(tester.getBottomRight(accountCard).dx, 1366 - 111);
    await capture('tablet-settings-large-landscape');
    await pumpSize(const Size(1194, 834));

    await tester.tap(nav(HomeNavigationDestination.ai));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await capture('tablet-ai-landscape');
    await pumpSize(const Size(1194, 834), keyboard: 340);
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('ai-page-input'))).dy,
      lessThan(834 - 340),
    );
    await capture('tablet-ai-keyboard');
    await tester.tap(nav(HomeNavigationDestination.settings));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    await pumpSize(const Size(744, 1133), brightness: Brightness.dark);
    expect(
      tester
          .widget<HomeBounceNavigationItem>(
            nav(HomeNavigationDestination.settings),
          )
          .isSelected,
      isTrue,
    );
    await capture('tablet-settings-portrait-dark');
    await tester.drag(settingsScroll, const Offset(0, -160));
    await tester.pumpAndSettle();
    await capture('tablet-settings-scrolled-gradient-dark');
    tester.widget<ListView>(settingsScroll).controller!.jumpTo(0);
    await tester.pump();
    await pumpSize(const Size(600, 960), scale: 1.5);
    expect(
      tester.getTopLeft(nav(HomeNavigationDestination.home)).dy,
      lessThan(100),
    );
    await capture('tablet-settings-split-large-text');
    await pumpSize(const Size(600, 960), scale: 3);
    expect(tester.getSize(find.byType(HomeTabletToolbar)).height, 102);
    expect(
      tester.getSize(nav(HomeNavigationDestination.home)).height,
      greaterThanOrEqualTo(69),
    );
    await capture('tablet-settings-accessibility');
    await tester.drag(settingsScroll, const Offset(0, -220));
    await tester.pumpAndSettle();
    await capture('tablet-settings-scrolled-accessibility');
    tester.widget<ListView>(settingsScroll).controller!.jumpTo(0);
    await tester.pump();
    await pumpSize(const Size(390, 844));
    expect(
      tester.getTopLeft(nav(HomeNavigationDestination.home)).dy,
      greaterThan(700),
    );
    expect(
      tester
          .widget<HomeBounceNavigationItem>(
            nav(HomeNavigationDestination.settings),
          )
          .isSelected,
      isTrue,
    );
    await capture('phone-settings');
    await pumpSize(const Size(834, 1194), keyboard: 340);
    expect(
      tester.getTopLeft(nav(HomeNavigationDestination.home)).dy,
      lessThan(100),
    );
    expect(
      tester
          .widget<IgnorePointer>(
            find.byKey(const ValueKey('home-floating-navigation-pointer')),
          )
          .ignoring,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
