import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';
import 'package:xxread/widgets/reader_shader_page_curl.dart';

void main() {
  test('reader font overrides EPUB font except for the system default', () {
    expect(
      resolveNativeReaderFontFamily(
        readerFontFamily: null,
        epubFontFamily: 'Embedded EPUB Font',
      ),
      'Embedded EPUB Font',
    );
    expect(
      resolveNativeReaderFontFamily(
        readerFontFamily: 'PingFang SC',
        epubFontFamily: 'Embedded EPUB Font',
      ),
      'PingFang SC',
    );
  });

  testWidgets(
    'EPUB precaches adjacent horizontal images before the first turn',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
        ReaderSettingsStore.txtChapterTitlePageKey: false,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-image-precache-',
      );
      final epub = File('${directory.path}/image-precache.epub');
      epub.writeAsBytesSync(
        _epubFixture(
          chapterCount: 3,
          imageOnlyChapterCount: 3,
          uniqueImagePerChapter: true,
        ),
      );
      final precachedImages = <ImageProvider>[];

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              book: Book(
                title: 'EPUB image precache fixture',
                filePath: epub.path,
                format: 'epub',
                fileModifiedTime: epub
                    .lastModifiedSync()
                    .millisecondsSinceEpoch,
              ),
              imagePrecacher: (image) async => precachedImages.add(image),
            ),
          ),
        );
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 60; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (precachedImages.toSet().length >= 2) return;
          }
        });
        await _pumpUntil(tester, () => precachedImages.toSet().length >= 2);

        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        expect(controller.page, controller.initialPage.toDouble());
        expect(precachedImages.toSet(), hasLength(greaterThanOrEqualTo(2)));
        expect(precachedImages, everyElement(isA<FileImage>()));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'EPUB horizontal turns warm the next pagination window before a chapter boundary',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
        ReaderSettingsStore.txtChapterTitlePageKey: false,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-transition-',
      );
      final epub = File('${directory.path}/transition.epub');
      epub.writeAsBytesSync(_epubFixture());
      final paginationMisses = <int>[];

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              book: Book(
                title: 'EPUB transition fixture',
                filePath: epub.path,
                format: 'epub',
                fileModifiedTime: epub
                    .lastModifiedSync()
                    .millisecondsSinceEpoch,
              ),
              onPaginationCacheMiss: paginationMisses.add,
            ),
          ),
        );
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 60; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (find.byType(PageView).evaluate().isNotEmpty) return;
          }
        });
        await _pumpUntil(
          tester,
          () => find.byType(PageView).evaluate().isNotEmpty,
        );
        await tester.idle();
        await tester.pump();
        await _pumpUntil(tester, () => paginationMisses.contains(2));

        final pageView = find.byType(PageView);
        final pageViewWidget = tester.widget<PageView>(pageView);
        final firstChapterPages = _nearbyPageIndexes(
          tester,
          pageView,
          'Chapter 1',
        );
        expect(firstChapterPages, isNotEmpty);

        final controller = pageViewWidget.controller!;
        controller.jumpToPage(firstChapterPages.last);
        await tester.pump();
        await tester.idle();
        await tester.pump();
        await _pumpUntil(tester, () => paginationMisses.contains(3));
        paginationMisses.clear();
        final settledChildCount = tester
            .widget<PageView>(pageView)
            .childrenDelegate
            .estimatedChildCount!;

        final boundaryLeaf = find.byWidgetPredicate(
          (widget) =>
              widget is ReaderPaperPageLeaf &&
              widget.metadata.chapterTitle == 'Chapter 1' &&
              widget.metadata.pageNumber == firstChapterPages.length,
        );
        expect(boundaryLeaf, findsOneWidget);
        final boundaryElement = tester.element(boundaryLeaf);
        final rect = tester.getRect(pageView);
        final gesture = await tester.startGesture(
          Offset(rect.right - 8, rect.center.dy),
        );
        await gesture.moveBy(const Offset(-150, 0));
        await tester.pump();
        final pageDuringTurn = controller.page!;
        expect(pageDuringTurn, isNot(pageDuringTurn.roundToDouble()));
        final incomingLeaf = find.byWidgetPredicate(
          (widget) =>
              widget is ReaderPaperPageLeaf &&
              widget.metadata.chapterTitle == 'Chapter 2' &&
              widget.metadata.pageNumber == 1,
        );
        expect(incomingLeaf, findsOneWidget);
        final incomingElement = tester.element(incomingLeaf);
        expect(
          tester
              .widget<PageView>(pageView)
              .childrenDelegate
              .estimatedChildCount,
          settledChildCount,
        );

        // Cross PageView's onPageChanged threshold without releasing the
        // pointer. Chapter-window maintenance must not alter the live page
        // list or controller while the drag is still active.
        await gesture.moveBy(Offset(-rect.width * 0.35, 0));
        await tester.pump();
        final heldPage = controller.page!;
        expect(heldPage, isNot(heldPage.roundToDouble()));
        expect(tester.widget<PageView>(pageView).controller, same(controller));
        expect(
          tester
              .widget<PageView>(pageView)
              .childrenDelegate
              .estimatedChildCount,
          settledChildCount,
        );
        expect(tester.element(boundaryLeaf), same(boundaryElement));
        expect(tester.element(incomingLeaf), same(incomingElement));

        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PageView>(pageView)
              .childrenDelegate
              .estimatedChildCount,
          greaterThan(settledChildCount),
        );

        final turn = controller.nextPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
        await tester.pumpAndSettle();
        await turn;

        expect(paginationMisses, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('EPUB horizontal paging continues past image-only front matter', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.binding.setSurfaceSize(const Size(480, 800));
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
      ReaderSettingsStore.txtChapterTitlePageKey: false,
    });
    final directory = Directory.systemTemp.createTempSync(
      'open-reading-epub-front-matter-',
    );
    final epub = File('${directory.path}/front-matter.epub');
    epub.writeAsBytesSync(
      _epubFixture(chapterCount: 14, imageOnlyChapterCount: 8),
    );

    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NativeReaderPage(
            book: Book(
              title: 'EPUB image front matter fixture',
              filePath: epub.path,
              format: 'epub',
              fileModifiedTime: epub.lastModifiedSync().millisecondsSinceEpoch,
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 60; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          if (find.byType(PageView).evaluate().isNotEmpty) return;
        }
      });
      await _pumpUntil(
        tester,
        () => find.byType(PageView).evaluate().isNotEmpty,
      );
      final stableController = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;

      var reachedBody = false;
      for (var turn = 0; turn < 24 && !reachedBody; turn++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pump(const Duration(milliseconds: 50));
        final pageView = tester.widget<PageView>(find.byType(PageView));
        final controller = pageView.controller!;
        final delegate =
            pageView.childrenDelegate as SliverChildBuilderDelegate;
        final currentPage = controller.page?.round() ?? 0;
        final currentLeaf =
            delegate.builder(
                  tester.element(find.byType(PageView)),
                  currentPage,
                )!
                as ReaderPaperPageLeaf;
        if (currentLeaf.metadata.chapterTitle == 'Chapter 9') {
          reachedBody = true;
          break;
        }
        if (delegate.estimatedChildCount! <= currentPage + 1) {
          await _pumpUntil(tester, () {
            final latest = tester.widget<PageView>(find.byType(PageView));
            final latestPage = latest.controller!.page?.round() ?? 0;
            final latestDelegate =
                latest.childrenDelegate as SliverChildBuilderDelegate;
            return latestDelegate.estimatedChildCount! > latestPage + 1;
          });
        }
        final latest = tester.widget<PageView>(find.byType(PageView));
        final latestPage = latest.controller!.page?.round() ?? 0;
        latest.controller!.jumpToPage(latestPage + 1);
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(reachedBody, isTrue);
      expect(
        tester.widget<PageView>(find.byType(PageView)).controller,
        same(stableController),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
      debugDefaultTargetPlatformOverride = null;
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'EPUB horizontal paging does not bounce when turning again at a warming tail',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
        ReaderSettingsStore.txtChapterTitlePageKey: false,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-warming-tail-',
      );
      final epub = File('${directory.path}/warming-tail.epub');
      epub.writeAsBytesSync(
        _epubFixture(chapterCount: 14, imageOnlyChapterCount: 8),
      );

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              book: Book(
                title: 'EPUB warming tail fixture',
                filePath: epub.path,
                format: 'epub',
                fileModifiedTime: epub
                    .lastModifiedSync()
                    .millisecondsSinceEpoch,
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 60; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (find.byType(PageView).evaluate().isNotEmpty) return;
          }
        });
        await _pumpUntil(
          tester,
          () => find.byType(PageView).evaluate().isNotEmpty,
        );

        final pageView = find.byType(PageView);
        final initialPageView = tester.widget<PageView>(pageView);
        final controller = initialPageView.controller!;
        final publishedTail = _lastPublishedContentPageIndex(tester, pageView);
        final tailLeaf = _pageLeafAt(tester, pageView, publishedTail);
        final tailChapterNumber = int.parse(
          tailLeaf.metadata.chapterTitle.split(' ').last,
        );
        controller.jumpToPage(publishedTail);
        expect(controller.page, publishedTail.toDouble());

        final rect = tester.getRect(pageView);
        final gesture = await tester.startGesture(
          Offset(rect.right - 8, rect.center.dy),
        );
        await gesture.moveBy(Offset(-rect.width * 0.8, 0));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pumpAndSettle();

        final settledPage = controller.page!.round();
        final settledLeaf = _pageLeafAt(tester, pageView, settledPage);
        expect(tester.widget<PageView>(pageView).controller, same(controller));
        expect(settledPage, publishedTail + 1);
        expect(
          settledLeaf.metadata.chapterTitle,
          'Chapter ${tailChapterNumber + 1}',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('EPUB backward turns keep one horizontal controller', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({
      ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
    });
    await tester.binding.setSurfaceSize(const Size(400, 800));
    final directory = Directory.systemTemp.createTempSync(
      'open_reading_epub_backward_window_',
    );
    final epub = File('${directory.path}/backward-window.epub');
    epub.writeAsBytesSync(_epubFixture(chapterCount: 6));

    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NativeReaderPage(
            book: Book(
              title: 'EPUB backward window fixture',
              filePath: epub.path,
              format: 'epub',
              currentPage: 3,
              fileModifiedTime: epub.lastModifiedSync().millisecondsSinceEpoch,
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        for (var attempt = 0; attempt < 60; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          if (find.byType(PageView).evaluate().isNotEmpty) return;
        }
      });
      await _pumpUntil(
        tester,
        () => find.byType(PageView).evaluate().isNotEmpty,
      );

      final pageView = find.byType(PageView);
      final initialWidget = tester.widget<PageView>(pageView);
      final chapterFourPages = _nearbyPageIndexes(
        tester,
        pageView,
        'Chapter 4',
      );
      expect(chapterFourPages, isNotEmpty);

      final initialController = initialWidget.controller!;
      initialController.jumpToPage(chapterFourPages.first);
      await tester.pumpAndSettle();
      final firstChildCount = tester
          .widget<PageView>(pageView)
          .childrenDelegate
          .estimatedChildCount!;
      final rect = tester.getRect(pageView);
      final firstGesture = await tester.startGesture(
        Offset(rect.left + 8, rect.center.dy),
      );
      await firstGesture.moveBy(Offset(rect.width * 0.65, 0));
      await tester.pump();
      final firstHeldPage = initialController.page!;
      expect(firstHeldPage, isNot(firstHeldPage.roundToDouble()));
      expect(
        tester.widget<PageView>(pageView).controller,
        same(initialController),
      );
      expect(
        tester.widget<PageView>(pageView).childrenDelegate.estimatedChildCount,
        firstChildCount,
      );

      await firstGesture.up();
      await tester.pumpAndSettle();
      await _pumpUntil(
        tester,
        () => identical(
          tester.widget<PageView>(pageView).controller,
          initialController,
        ),
      );

      final middleWidget = tester.widget<PageView>(pageView);
      final chapterThreePages = _nearbyPageIndexes(
        tester,
        pageView,
        'Chapter 3',
      );
      expect(chapterThreePages, isNotEmpty);

      final middleController = middleWidget.controller!;
      middleController.jumpToPage(chapterThreePages.first);
      await tester.pumpAndSettle();
      final secondChildCount = tester
          .widget<PageView>(pageView)
          .childrenDelegate
          .estimatedChildCount!;
      final secondGesture = await tester.startGesture(
        Offset(rect.left + 8, rect.center.dy),
      );
      await secondGesture.moveBy(Offset(rect.width * 0.65, 0));
      await tester.pump();
      final secondHeldPage = middleController.page!;
      expect(secondHeldPage, isNot(secondHeldPage.roundToDouble()));
      expect(
        tester.widget<PageView>(pageView).controller,
        same(middleController),
      );
      expect(
        tester.widget<PageView>(pageView).childrenDelegate.estimatedChildCount,
        secondChildCount,
      );

      await secondGesture.up();
      await tester.pumpAndSettle();
      await _pumpUntil(
        tester,
        () => identical(
          tester.widget<PageView>(pageView).controller,
          middleController,
        ),
      );

      final settledWidget = tester.widget<PageView>(pageView);
      final settledDelegate =
          settledWidget.childrenDelegate as SliverChildBuilderDelegate;
      final settledChapterTitles = {
        for (final index in _nearbyPageIndexes(tester, pageView, null))
          (settledDelegate.builder(tester.element(pageView), index)!
                  as ReaderPaperPageLeaf)
              .metadata
              .chapterTitle,
      };
      expect(
        settledChapterTitles,
        containsAll(<String>[
          'Chapter 1',
          'Chapter 2',
          'Chapter 3',
          'Chapter 4',
        ]),
      );
      expect(settledChapterTitles, isNot(contains('Chapter 5')));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.binding.setSurfaceSize(null);
      debugDefaultTargetPlatformOverride = null;
      directory.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'EPUB page curl returns from a chapter first page to the previous last page',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.pageCurl.name,
        ReaderSettingsStore.txtChapterTitlePageKey: false,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-curl-boundary-',
      );
      final epub = File('${directory.path}/curl-boundary.epub');
      epub.writeAsBytesSync(_epubFixture(chapterCount: 3));

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              book: Book(
                title: 'EPUB curl boundary fixture',
                filePath: epub.path,
                format: 'epub',
                fileModifiedTime: epub
                    .lastModifiedSync()
                    .millisecondsSinceEpoch,
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 60; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (find.byType(ReaderShaderPageCurl).evaluate().isNotEmpty) return;
          }
        });
        await _pumpUntil(
          tester,
          () => find.byType(ReaderShaderPageCurl).evaluate().isNotEmpty,
        );

        ReaderShaderPageCurl curl() => tester.widget<ReaderShaderPageCurl>(
          find.byType(ReaderShaderPageCurl),
        );
        for (var turn = 0; turn < 40; turn++) {
          final current = curl();
          if (current.currentPage.key.pageIdentity.contains(
            ':chapter2.xhtml:0:',
          )) {
            break;
          }
          if (current.forwardPage == null) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 100));
            });
            await tester.pump();
            continue;
          }
          final future = current.controller!.turnForward();
          await tester.pumpAndSettle();
          await future;
        }

        final chapterTwoFirst = curl();
        expect(
          chapterTwoFirst.currentPage.key.pageIdentity,
          contains(':chapter2.xhtml:0:'),
        );
        expect(chapterTwoFirst.backwardPage, isNotNull);
        final previousIdentity = chapterTwoFirst.backwardPage!.key.pageIdentity;

        final curlRect = tester.getRect(find.byType(ReaderShaderPageCurl));
        final backwardGesture = await tester.startGesture(
          Offset(curlRect.left + 2, curlRect.center.dy),
        );
        await backwardGesture.moveBy(const Offset(40, 0));
        await tester.pump();
        await backwardGesture.moveBy(Offset(curlRect.width * 0.7, -24));
        await tester.pump();
        await backwardGesture.up();
        await tester.pumpAndSettle();

        expect(curl().currentPage.key.pageIdentity, previousIdentity);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
  }
  fail('Timed out waiting for EPUB reader state.');
}

List<int> _nearbyPageIndexes(
  WidgetTester tester,
  Finder pageView,
  String? chapterTitle,
) {
  final widget = tester.widget<PageView>(pageView);
  final delegate = widget.childrenDelegate as SliverChildBuilderDelegate;
  final element = tester.element(pageView);
  final current = widget.controller?.page?.round() ?? 0;
  final first = math.max(0, current - 160);
  final last = math.min(delegate.estimatedChildCount! - 1, current + 160);
  final indexes = <int>[];
  for (var index = first; index <= last; index++) {
    final child = delegate.builder(element, index);
    if (child is! ReaderPaperPageLeaf) continue;
    if (chapterTitle == null || child.metadata.chapterTitle == chapterTitle) {
      indexes.add(index);
    }
  }
  return indexes;
}

ReaderPaperPageLeaf _pageLeafAt(
  WidgetTester tester,
  Finder pageView,
  int controllerPage,
) {
  final widget = tester.widget<PageView>(pageView);
  final delegate = widget.childrenDelegate as SliverChildBuilderDelegate;
  return delegate.builder(tester.element(pageView), controllerPage)!
      as ReaderPaperPageLeaf;
}

int _lastPublishedContentPageIndex(WidgetTester tester, Finder pageView) {
  final widget = tester.widget<PageView>(pageView);
  final delegate = widget.childrenDelegate as SliverChildBuilderDelegate;
  final element = tester.element(pageView);
  for (var index = delegate.estimatedChildCount! - 1; index >= 0; index--) {
    final child = delegate.builder(element, index);
    if (child is ReaderPaperPageLeaf &&
        child.metadata.chapterTitle.isNotEmpty) {
      return index;
    }
  }
  fail('No published EPUB content page was available.');
}

List<int> _epubFixture({
  int chapterCount = 4,
  int imageOnlyChapterCount = 0,
  bool uniqueImagePerChapter = false,
}) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  void addBytes(String name, List<int> bytes) {
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
    <dc:identifier id="book-id">transition-fixture</dc:identifier>
    <dc:title>Transition fixture</dc:title><dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    ${uniqueImagePerChapter ? List.generate(chapterCount, (index) => '<item id="stripe${index + 1}" href="stripe${index + 1}.png" media-type="image/png"/>').join() : '<item id="stripe" href="stripe.png" media-type="image/png"/>'}
    ${List.generate(chapterCount, (index) => '<item id="c${index + 1}" href="chapter${index + 1}.xhtml" media-type="application/xhtml+xml"/>').join()}
  </manifest>
  <spine toc="ncx">${List.generate(chapterCount, (index) => '<itemref idref="c${index + 1}"/>').join()}</spine>
</package>''');
  add('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="transition-fixture"/></head>
  <docTitle><text>Transition fixture</text></docTitle>
  <navMap>${List.generate(chapterCount, (index) => '<navPoint id="nav${index + 1}" playOrder="${index + 1}"><navLabel><text>Chapter ${index + 1}</text></navLabel><content src="chapter${index + 1}.xhtml"/></navPoint>').join()}</navMap>
</ncx>''');
  final imageBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  if (uniqueImagePerChapter) {
    for (var chapter = 1; chapter <= chapterCount; chapter++) {
      addBytes('OEBPS/stripe$chapter.png', imageBytes);
    }
  } else {
    addBytes('OEBPS/stripe.png', imageBytes);
  }
  for (var chapter = 1; chapter <= chapterCount; chapter++) {
    add('OEBPS/chapter$chapter.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $chapter</title></head><body>
${chapter <= imageOnlyChapterCount ? '<img src="${uniqueImagePerChapter ? 'stripe$chapter.png' : 'stripe.png'}" alt=""/>' : '<h1>Chapter $chapter</h1>${List.generate(40, (index) => '<p>Chapter $chapter paragraph $index contains enough text to create several deterministic reader pages for transition testing.</p>').join()}'}
</body></html>''');
  }
  return ZipEncoder().encode(archive)!;
}
