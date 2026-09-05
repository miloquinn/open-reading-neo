import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const fullscreenChannel = MethodChannel('com.niki.xxread/fullscreen');
  const readerKeysChannel = MethodChannel('com.niki.xxread/reader_keys');
  const readerStatusChannel = MethodChannel('com.niki.xxread/reader_status');
  late ReplaceRuleService replaceRuleService;
  late List<File> fixtureFiles;

  setUp(() {
    replaceRuleService = ReplaceRuleService();
    fixtureFiles = [];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fullscreenChannel, (_) async => null);
    messenger.setMockMethodCallHandler(readerKeysChannel, (_) async => null);
    messenger.setMockMethodCallHandler(
      readerStatusChannel,
      (_) async => <String, Object?>{'level': 80, 'charging': false},
    );
  });

  tearDown(() async {
    await replaceRuleService.close();
    for (final fixture in fixtureFiles) {
      if (fixture.existsSync()) fixture.deleteSync();
    }
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fullscreenChannel, null);
    messenger.setMockMethodCallHandler(readerKeysChannel, null);
    messenger.setMockMethodCallHandler(readerStatusChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'starts auto page turn from paging settings and advances a page',
    (tester) async {
      final fixture = _longHtmlFixture(fixtureFiles, 'advance');
      await _openHorizontalReader(tester, fixture, replaceRuleService);
      final initialPage = _currentPage(tester);

      await _startAutoPageTurnFromSettings(tester);
      expect(
        find.byKey(const ValueKey('reader-auto-page-turn-control-bar')),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();

      expect(_currentPage(tester), initialPage + 1);
      await _closeReader(tester);
    },
  );

  testWidgets('opening reader controls pauses auto page turn', (tester) async {
    final fixture = _longHtmlFixture(fixtureFiles, 'menu-pause');
    await _openHorizontalReader(tester, fixture, replaceRuleService);
    await _startAutoPageTurnFromSettings(tester);
    final pageBeforeMenu = _currentPage(tester);

    await tester.tapAt(const Offset(240, 400));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('reader-auto-page-turn-resume')),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(_currentPage(tester), pageBeforeMenu);
    await _closeReader(tester);
  });

  testWidgets('backgrounding pauses auto page turn without automatic resume', (
    tester,
  ) async {
    final fixture = _longHtmlFixture(fixtureFiles, 'lifecycle-pause');
    await _openHorizontalReader(tester, fixture, replaceRuleService);
    await _startAutoPageTurnFromSettings(tester);
    final pageBeforeBackground = _currentPage(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(_currentPage(tester), pageBeforeBackground);
    expect(
      find.byKey(const ValueKey('reader-auto-page-turn-resume')),
      findsOneWidget,
    );
    await _closeReader(tester);
  });

  testWidgets('auto page turn stops when the last page is reached', (
    tester,
  ) async {
    final fixture = _htmlFixture(
      fixtureFiles,
      'book-end',
      '<h1>Only page</h1><p>This is the complete book.</p>',
    );
    await _openHorizontalReader(tester, fixture, replaceRuleService);
    expect(_pageStatus(tester).page, 1);
    expect(_pageStatus(tester).pageCount, 1);
    await _startAutoPageTurnFromSettings(tester);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('reader-auto-page-turn-control-bar')),
      findsNothing,
    );
    expect(_pageStatus(tester).page, 1);
    await _closeReader(tester);
  });

  testWidgets('auto page turn advances across an EPUB chapter boundary', (
    tester,
  ) async {
    final fixture = File(
      '${Directory.systemTemp.path}/open-reading-auto-page-turn-boundary.epub',
    )..writeAsBytesSync(_twoChapterEpubFixture());
    fixtureFiles.add(fixture);
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
      ReaderSettingsStore.tapPageAnimationKey: false,
      ReaderAutoPageTurnController.intervalPreferenceKey: 5,
    });
    await _openReader(tester, fixture, replaceRuleService, format: 'epub');
    await _pumpUntilFound(tester, find.byType(PageView));
    expect(_pageStatus(tester).chapter, 1);
    expect(_pageStatus(tester).pageCount, 1);
    await _startAutoPageTurnFromSettings(tester);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();

    expect(_pageStatus(tester).chapter, 2);
    expect(_pageStatus(tester).page, 1);
    await _closeReader(tester);
  });

  testWidgets('auto page turn scrolls a vertical reader by one viewport', (
    tester,
  ) async {
    final fixture = _longHtmlFixture(fixtureFiles, 'vertical');
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.verticalScroll.name,
      ReaderSettingsStore.scrollByChapterKey: true,
      ReaderAutoPageTurnController.intervalPreferenceKey: 5,
      ReaderAutoPageTurnController.verticalModePreferenceKey:
          ReaderAutoPageTurnMode.interval.name,
    });
    await _openReader(tester, fixture, replaceRuleService);
    await _pumpUntilFound(tester, find.byType(ScrollablePositionedList));
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ScrollablePositionedList),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final initialPixels = scrollable.position.pixels;
    await _startAutoPageTurnFromSettings(tester);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 250));

    expect(scrollable.position.pixels, greaterThan(initialPixels));
    await _closeReader(tester);
  });

  testWidgets(
    'sweep uses the ten second default and resumes from a paused midpoint',
    (tester) async {
      final fixture = _longHtmlFixture(fixtureFiles, 'sweep');
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
        ReaderSettingsStore.tapPageAnimationKey: false,
        ReaderAutoPageTurnController.horizontalModePreferenceKey:
            ReaderAutoPageTurnMode.sweep.name,
      });
      await _openReader(tester, fixture, replaceRuleService);
      await _pumpUntilFound(
        tester,
        find.byKey(const ValueKey('native-reader-status')),
      );
      final initialPage = _currentPage(tester);

      await _startAutoPageTurnFromSettings(tester, expectedSeconds: 10);
      expect(
        find.byKey(const ValueKey('reader-sweep-surface')),
        findsOneWidget,
      );
      await _pumpFrames(tester, const Duration(seconds: 7));
      expect(_currentPage(tester), initialPage);

      await tester.tapAt(const Offset(240, 400));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reader-auto-page-turn-resume')),
        findsOneWidget,
      );
      await _pumpFrames(tester, const Duration(seconds: 6));
      expect(_currentPage(tester), initialPage);

      await tester.tap(
        find.byKey(const ValueKey('reader-auto-page-turn-resume')),
      );
      await tester.pump();
      await _pumpFrames(tester, const Duration(seconds: 6));
      expect(_currentPage(tester), initialPage + 1);
      await _closeReader(tester);
    },
  );

  testWidgets('two-page sweep scans both leaves before committing the spread', (
    tester,
  ) async {
    final fixture = _longHtmlFixture(fixtureFiles, 'two-page-sweep');
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
      ReaderSettingsStore.tabletTwoPageKey: true,
      ReaderSettingsStore.tapPageAnimationKey: false,
      ReaderAutoPageTurnController.horizontalModePreferenceKey:
          ReaderAutoPageTurnMode.sweep.name,
    });
    await _openReader(
      tester,
      fixture,
      replaceRuleService,
      surfaceSize: const Size(1000, 800),
    );
    await _pumpUntilFound(tester, find.byType(PageView));
    final initialPage = _currentPage(tester);

    await _startAutoPageTurnFromSettings(tester, expectedSeconds: 10);
    await _pumpFrames(tester, const Duration(seconds: 13));
    expect(_currentPage(tester), initialPage);
    await _pumpFrames(tester, const Duration(seconds: 10));
    expect(_currentPage(tester), initialPage + 2);
    await _closeReader(tester);
  });

  testWidgets('continuous mode scrolls smoothly with chapter paging enabled', (
    tester,
  ) async {
    final fixture = _longHtmlFixture(fixtureFiles, 'continuous');
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.verticalScroll.name,
      ReaderSettingsStore.scrollByChapterKey: true,
      ReaderAutoPageTurnController.verticalModePreferenceKey:
          ReaderAutoPageTurnMode.continuous.name,
      ReaderAutoPageTurnController.continuousSecondsPreferenceKey: 5.0,
    });
    await _openReader(tester, fixture, replaceRuleService);
    await _pumpUntilFound(tester, find.byType(ScrollablePositionedList));

    await _startAutoPageTurnFromSettings(tester, expectedSeconds: 5);
    await tester.pump();
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ScrollablePositionedList),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final initialPixels = scrollable.position.pixels;
    await _pumpFrames(tester, const Duration(seconds: 2));

    expect(scrollable.position.pixels, greaterThan(initialPixels + 100));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(ReaderSettingsStore.scrollByChapterKey), isTrue);
    await _closeReader(tester);
  });

  testWidgets('dragging takes over a smooth continuous pause immediately', (
    tester,
  ) async {
    final fixture = _longHtmlFixture(fixtureFiles, 'continuous-drag');
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.verticalScroll.name,
      ReaderSettingsStore.scrollByChapterKey: true,
      ReaderAutoPageTurnController.verticalModePreferenceKey:
          ReaderAutoPageTurnMode.continuous.name,
      ReaderAutoPageTurnController.continuousSecondsPreferenceKey: 5.0,
    });
    await _openReader(tester, fixture, replaceRuleService);
    await _pumpUntilFound(tester, find.byType(ScrollablePositionedList));
    await _startAutoPageTurnFromSettings(tester, expectedSeconds: 5);
    await _pumpFrames(tester, const Duration(seconds: 1));
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ScrollablePositionedList),
            matching: find.byType(Scrollable),
          )
          .first,
    );

    final gesture = await tester.startGesture(const Offset(240, 400));
    final atTouchDown = scrollable.position.pixels;
    await tester.pump(const Duration(milliseconds: 16));
    await _pumpFrames(tester, const Duration(milliseconds: 100));
    expect(scrollable.position.pixels, greaterThan(atTouchDown));

    await gesture.moveBy(const Offset(0, -1));
    await tester.pump();
    final atDrag = scrollable.position.pixels;
    await _pumpFrames(tester, const Duration(milliseconds: 500));
    expect(scrollable.position.pixels, closeTo(atDrag, 0.1));
    await gesture.up();
    await _closeReader(tester);
  });

  testWidgets('continuous mode crosses an EPUB chapter without changing mode', (
    tester,
  ) async {
    final fixture = File(
      '${Directory.systemTemp.path}/open-reading-auto-scroll-boundary.epub',
    )..writeAsBytesSync(_twoChapterEpubFixture(paragraphsPerChapter: 12));
    fixtureFiles.add(fixture);
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.verticalScroll.name,
      ReaderSettingsStore.scrollByChapterKey: true,
      ReaderAutoPageTurnController.verticalModePreferenceKey:
          ReaderAutoPageTurnMode.continuous.name,
      ReaderAutoPageTurnController.continuousSecondsPreferenceKey: 5.0,
    });
    await _openReader(tester, fixture, replaceRuleService, format: 'epub');
    await _pumpUntilFound(tester, find.byType(ScrollablePositionedList));
    expect(_pageStatus(tester).chapter, 1);

    await _startAutoPageTurnFromSettings(tester, expectedSeconds: 5);
    for (var frame = 0; frame < 160; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (_pageStatus(tester).chapter == 2) break;
    }

    expect(_pageStatus(tester).chapter, 2);
    final wholeBookScrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ScrollablePositionedList),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final pixelsBeforeStop = wholeBookScrollable.position.pixels;
    tester
        .widget<IconButton>(
          find.byKey(const ValueKey('reader-auto-page-turn-stop')),
        )
        .onPressed!();
    await tester.pump();
    await _pumpFrames(tester, const Duration(seconds: 1));
    expect(_pageStatus(tester).chapter, 2);
    final scrollableAfterStop = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ScrollablePositionedList),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollableAfterStop, same(wholeBookScrollable));
    expect(scrollableAfterStop.position.pixels, closeTo(pixelsBeforeStop, 0.1));
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(ReaderSettingsStore.scrollByChapterKey), isTrue);
    await _closeReader(tester);
  });
}

Future<void> _openHorizontalReader(
  WidgetTester tester,
  File fixture,
  ReplaceRuleService replaceRuleService,
) async {
  SharedPreferences.setMockInitialValues({
    ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
    ReaderSettingsStore.tapPageAnimationKey: false,
    ReaderAutoPageTurnController.intervalPreferenceKey: 5,
  });
  await _openReader(tester, fixture, replaceRuleService);
  await _pumpUntilFound(tester, find.byType(PageView));
}

Future<void> _openReader(
  WidgetTester tester,
  File fixture,
  ReplaceRuleService replaceRuleService, {
  String format = 'html',
  Size surfaceSize = const Size(480, 800),
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  await tester.binding.setSurfaceSize(surfaceSize);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: NativeReaderPage(
        replaceRuleService: replaceRuleService,
        book: Book(
          title: 'Auto page turn test',
          filePath: fixture.path,
          format: format,
          fileModifiedTime: fixture.lastModifiedSync().millisecondsSinceEpoch,
        ),
      ),
    ),
  );
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 30; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      if (find
          .byKey(const ValueKey('native-reader-status'))
          .evaluate()
          .isNotEmpty) {
        return;
      }
    }
  });
  await _pumpUntilFound(
    tester,
    find.byKey(const ValueKey('native-reader-status')),
  );
}

Future<void> _startAutoPageTurnFromSettings(
  WidgetTester tester, {
  double expectedSeconds = 5,
}) async {
  tester
      .widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.tune_rounded),
          matching: find.byType(IconButton),
        ),
      )
      .onPressed!();
  await tester.pumpAndSettle();
  final tabBar = find.byKey(const ValueKey('reader-settings-tab-bar'));
  final tabBarRect = tester.getRect(tabBar);
  await tester.tapAt(
    Offset(tabBarRect.left + tabBarRect.width * 0.875, tabBarRect.center.dy),
  );
  await tester.pumpAndSettle();
  final autoPageTurnTile = find.byKey(
    const ValueKey('reader-auto-page-turn-tile'),
  );
  await tester.ensureVisible(autoPageTurnTile);
  await tester.pumpAndSettle();
  await tester.tap(autoPageTurnTile);
  await tester.pumpAndSettle();
  expect(
    tester
        .widget<Slider>(
          find.byKey(const ValueKey('reader-auto-page-turn-interval-slider')),
        )
        .value,
    expectedSeconds,
  );
  final startButton = find.byKey(const ValueKey('reader-auto-page-turn-start'));
  await tester.ensureVisible(startButton);
  await tester.pumpAndSettle();
  await tester.tap(startButton);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpFrames(WidgetTester tester, Duration duration) async {
  final frameCount = (duration.inMilliseconds / 100).ceil();
  for (var frame = 0; frame < frameCount; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _closeReader(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.binding.setSurfaceSize(null);
  debugDefaultTargetPlatformOverride = null;
}

({int chapter, int chapterCount, int page, int pageCount}) _pageStatus(
  WidgetTester tester,
) {
  final text = tester
      .widget<Text>(find.byKey(const ValueKey('native-reader-status')))
      .data!;
  final fractions = RegExp(r'(\d+)/(\d+)').allMatches(text).toList();
  expect(fractions, hasLength(2), reason: 'Unexpected reader status: $text');
  return (
    chapter: int.parse(fractions[0].group(1)!),
    chapterCount: int.parse(fractions[0].group(2)!),
    page: int.parse(fractions[1].group(1)!),
    pageCount: int.parse(fractions[1].group(2)!),
  );
}

int _currentPage(WidgetTester tester) => _pageStatus(tester).page;

File _longHtmlFixture(List<File> fixtures, String name) => _htmlFixture(
  fixtures,
  name,
  '<h1>Long chapter</h1>'
  '${List.generate(180, (index) => '<p>Paragraph $index gives the native '
      'reader enough content to exercise automatic page turns.</p>').join()}',
);

File _htmlFixture(List<File> fixtures, String name, String body) {
  final file =
      File(
        '${Directory.systemTemp.path}/open-reading-auto-page-turn-$name.html',
      )..writeAsStringSync(
        '<!doctype html><html lang="en"><body>$body</body></html>',
      );
  fixtures.add(file);
  return file;
}

List<int> _twoChapterEpubFixture({int paragraphsPerChapter = 0}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  add('OEBPS/content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">auto-turn-boundary</dc:identifier>
    <dc:title>Auto turn boundary</dc:title><dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''');
  add('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="auto-turn-boundary"/></head>
  <docTitle><text>Auto turn boundary</text></docTitle>
  <navMap>
    <navPoint id="nav1" playOrder="1"><navLabel><text>Chapter 1</text></navLabel><content src="chapter1.xhtml"/></navPoint>
    <navPoint id="nav2" playOrder="2"><navLabel><text>Chapter 2</text></navLabel><content src="chapter2.xhtml"/></navPoint>
  </navMap>
</ncx>''');
  for (var chapter = 1; chapter <= 2; chapter++) {
    final paragraphs = paragraphsPerChapter <= 0
        ? '<p>Short chapter $chapter.</p>'
        : List.generate(
            paragraphsPerChapter,
            (index) =>
                '<p>Chapter $chapter paragraph $index provides enough '
                'text for continuous automatic scrolling across chapters.</p>',
          ).join();
    add('OEBPS/chapter$chapter.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $chapter</title></head>
<body><h1>Chapter $chapter</h1>$paragraphs</body></html>''');
  }
  return ZipEncoder().encode(archive)!;
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder; exception=${tester.takeException()}');
}
