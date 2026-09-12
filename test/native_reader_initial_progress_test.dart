import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/core/reader/reader_layout.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/bookmark.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/reading/reading_resume_service.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/widgets/reader_annotated_text_page.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';
import 'package:xxread/widgets/reader_settings_controls.dart';
import 'package:xxread/widgets/reader_navigation_sheet.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

import 'support/reader_cache_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory databaseDirectory;
  late ReplaceRuleService replaceRuleService;

  setUp(() {
    replaceRuleService = ReplaceRuleService();
  });

  tearDown(() async {
    await replaceRuleService.close();
  });

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databaseDirectory = await Directory.systemTemp.createTemp(
      'open-reading-reader-progress-db-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => databaseDirectory.path,
        );
  });

  testWidgets(
    'EPUB horizontal reader paints the restored page on its first frame',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-initial-progress-',
      );
      final epub = File('${directory.path}/initial-progress.epub')
        ..writeAsBytesSync(_epubFixture());
      final locator = CanonicalLocator.fromComponents(
        format: BookFormat.epub,
        chapterId: 'chapter2.xhtml',
        offset: 2400,
        excerpt: 'Chapter 2 restored position',
      );

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              replaceRuleService: replaceRuleService,
              book: Book(
                title: 'EPUB initial progress fixture',
                filePath: epub.path,
                format: 'epub',
                currentPage: 0,
                lastCanonicalLocator: LocatorCodec.encodeCanonicalLocator(
                  locator,
                ),
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

        final pageView = tester.widget<PageView>(find.byType(PageView));
        final controller = pageView.controller!;
        final delegate =
            pageView.childrenDelegate as SliverChildBuilderDelegate;
        final initialLeaf =
            delegate.builder(
                  tester.element(find.byType(PageView)),
                  controller.initialPage,
                )!
                as ReaderPaperPageLeaf;

        expect(controller.initialPage, greaterThan(0));
        expect(initialLeaf.metadata.chapterTitle, 'Chapter 2');
        expect(initialLeaf.metadata.pageNumber, greaterThan(1));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await drainReaderCache(tester);
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'EPUB full-text search loads a later chapter and opens the matching page',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
        ReplaceRuleService.preferenceKey: '''[
          {
            "id":"epub-search-cleanup",
            "name":"epub-search-cleanup",
            "pattern":"Chapter 10 paragraph 47",
            "replacement":"cleaned search target",
            "enabled":true,
            "isRegex":false,
            "scopeTitle":false,
            "scopeContent":true,
            "order":0
          }
        ]''',
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-search-navigation-',
      );
      final epub = File('${directory.path}/search-navigation.epub')
        ..writeAsBytesSync(_epubFixture(chapterCount: 10));
      const searchTarget = 'cleaned search target';

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              replaceRuleService: replaceRuleService,
              book: Book(
                title: 'EPUB search navigation fixture',
                filePath: epub.path,
                format: 'epub',
                currentPage: 0,
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

        await tester.tapAt(const Offset(240, 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          find.byKey(const ValueKey('native-reader-bottom-controls')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('全文搜索'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('reader-full-text-search-field')),
          searchTarget,
        );
        await tester.pump(const Duration(milliseconds: 251));
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            final result = find.descendant(
              of: find.byType(ListTile),
              matching: find.textContaining(searchTarget),
            );
            if (result.evaluate().isNotEmpty) return;
          }
        });
        final resultTile = find.byType(ListTile);
        expect(
          find.descendant(
            of: resultTile,
            matching: find.textContaining(searchTarget),
          ),
          findsOneWidget,
        );
        await _pumpUntil(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.tap(resultTile);

        final matchingBody = find.descendant(
          of: find.byType(ReaderAnnotatedTextPage),
          matching: find.textContaining(searchTarget, findRichText: true),
        );
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (matchingBody.evaluate().isNotEmpty) return;
          }
        });
        await _pumpUntil(tester, () => matchingBody.evaluate().isNotEmpty);

        final pageView = tester.widget<PageView>(find.byType(PageView));
        final matchedLeaf = _pageLeafForControllerPage(tester, pageView);
        expect(matchedLeaf.metadata.chapterTitle, 'Chapter 10');
        expect(matchedLeaf.metadata.pageNumber, greaterThan(1));
        expect(matchingBody, findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await drainReaderCache(tester);
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'EPUB full-text search opens a later page in the current chapter',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-search-same-chapter-',
      );
      final epub = File('${directory.path}/search-same-chapter.epub')
        ..writeAsBytesSync(_epubFixture());
      const searchTarget = 'Chapter 1 paragraph 47';

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              replaceRuleService: replaceRuleService,
              book: Book(
                title: 'EPUB same-chapter search fixture',
                filePath: epub.path,
                format: 'epub',
                currentPage: 0,
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

        expect(
          find.textContaining(searchTarget, findRichText: true),
          findsNothing,
        );

        await tester.tapAt(const Offset(240, 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          find.byKey(const ValueKey('native-reader-bottom-controls')),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('全文搜索'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('reader-full-text-search-field')),
          searchTarget,
        );
        await tester.pump(const Duration(milliseconds: 251));
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            final result = find.descendant(
              of: find.byType(ListTile),
              matching: find.textContaining(searchTarget),
            );
            if (result.evaluate().isNotEmpty) return;
          }
        });
        final resultTile = find.byType(ListTile);
        expect(
          find.descendant(
            of: resultTile,
            matching: find.textContaining(searchTarget),
          ),
          findsOneWidget,
        );
        await tester.tap(resultTile);

        final matchingBody = find.descendant(
          of: find.byType(ReaderAnnotatedTextPage),
          matching: find.textContaining(searchTarget, findRichText: true),
        );
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (matchingBody.evaluate().isNotEmpty) return;
          }
        });
        await _pumpUntil(tester, () => matchingBody.evaluate().isNotEmpty);
        expect(
          find.byKey(const ValueKey('native-reader-positioning-placeholder')),
          findsNothing,
        );

        final pageView = tester.widget<PageView>(find.byType(PageView));
        final matchedLeaf = _pageLeafForControllerPage(tester, pageView);
        expect(matchedLeaf.metadata.chapterTitle, 'Chapter 1');
        expect(matchedLeaf.metadata.pageNumber, greaterThan(1));
        expect(matchingBody, findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await drainReaderCache(tester);
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  testWidgets(
    'EPUB continuous scroll hides the chapter opening until restore completes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.verticalScroll.name,
        ReaderSettingsStore.scrollByChapterKey: false,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-continuous-progress-',
      );
      final epub = File('${directory.path}/continuous-progress.epub')
        ..writeAsBytesSync(_epubFixture());
      final locator = CanonicalLocator.fromComponents(
        format: BookFormat.epub,
        chapterId: 'chapter2.xhtml',
        offset: 2400,
        excerpt: 'Chapter 2 restored position',
      );

      try {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: NativeReaderPage(
              replaceRuleService: replaceRuleService,
              book: Book(
                title: 'EPUB continuous progress fixture',
                filePath: epub.path,
                format: 'epub',
                currentPage: 0,
                lastCanonicalLocator: LocatorCodec.encodeCanonicalLocator(
                  locator,
                ),
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
            if (find.byType(ScrollablePositionedList).evaluate().isNotEmpty) {
              return;
            }
          }
        });
        await _pumpUntil(
          tester,
          () => find.byType(ScrollablePositionedList).evaluate().isNotEmpty,
        );

        expect(
          find.byKey(const ValueKey('native-reader-positioning-placeholder')),
          findsOneWidget,
        );

        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('native-reader-positioning-placeholder'))
              .evaluate()
              .isEmpty,
        );
        final status = tester.widget<Text>(
          find.byKey(const ValueKey('native-reader-status')),
        );
        final pageMatches = RegExp(r'(\d+)/(\d+)').allMatches(status.data!);
        expect(int.parse(pageMatches.last.group(1)!), greaterThan(1));
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ScrollablePositionedList),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scrollable.position.pixels, greaterThan(0));
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await drainReaderCache(tester);
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );

  for (final scrollByChapter in [false, true]) {
    for (final initialOffset in [0, 2400, 1000000]) {
      testWidgets(
        'EPUB scroll preserves its exact offset on background and exit '
        '(scrollByChapter=$scrollByChapter, initialOffset=$initialOffset)',
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          await tester.binding.setSurfaceSize(const Size(480, 800));
          SharedPreferences.setMockInitialValues({
            ReaderSettingsStore.pageModeKey: ReaderPageMode.verticalScroll.name,
            ReaderSettingsStore.scrollByChapterKey: scrollByChapter,
            ReadingResumeService.enabledPreferenceKey: true,
          });
          final directory = Directory.systemTemp.createTempSync(
            'open-reading-epub-scroll-exit-',
          );
          final epub = File('${directory.path}/scroll-exit.epub')
            ..writeAsBytesSync(_epubFixture());
          final bookId = (await tester.runAsync(
            () => BookDao().insertBook(
              Book(
                title: 'EPUB scroll exit fixture',
                filePath: epub.path,
                format: 'epub',
                currentPage: initialOffset > 0 ? 1 : 0,
                lastCanonicalLocator: initialOffset > 0
                    ? LocatorCodec.encodeCanonicalLocator(
                        CanonicalLocator.fromComponents(
                          format: BookFormat.epub,
                          chapterId: 'chapter2.xhtml',
                          offset: initialOffset,
                        ),
                      )
                    : null,
                fileModifiedTime: epub
                    .lastModifiedSync()
                    .millisecondsSinceEpoch,
              ),
            ),
          ))!;
          final navigatorKey = GlobalKey<NavigatorState>();

          Future<Book> savedBook() async =>
              (await tester.runAsync(() => BookDao().getBookById(bookId)))!;

          Future<void> settleWrites() async {
            await tester.runAsync(() async {
              for (var i = 0; i < 10; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 50));
                await tester.pump();
              }
            });
          }

          Future<void> openReader(Book book) async {
            navigatorKey.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => NativeReaderPage(
                  book: book,
                  replaceRuleService: replaceRuleService,
                ),
              ),
            );
            await tester.pump();
            await tester.runAsync(() async {
              for (var i = 0; i < 60; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 50));
                await tester.pump();
                if (find
                    .byType(ScrollablePositionedList)
                    .evaluate()
                    .isNotEmpty) {
                  return;
                }
              }
            });
            if (book.toCanonicalLocator() != null) {
              expect(
                find.byKey(
                  const ValueKey('native-reader-positioning-placeholder'),
                ),
                findsOneWidget,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await tester.runAsync(() async {
                await Future<void>.delayed(const Duration(milliseconds: 100));
              });
              expect(
                (await savedBook()).lastCanonicalLocator,
                book.lastCanonicalLocator,
                reason:
                    'Backgrounding mid-restore must not save provisional pixels.',
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
            }
            await _pumpUntil(
              tester,
              () =>
                  find.byType(ScrollablePositionedList).evaluate().isNotEmpty &&
                  find
                      .byKey(
                        const ValueKey('native-reader-positioning-placeholder'),
                      )
                      .evaluate()
                      .isEmpty,
            );
            await tester.pumpAndSettle();
          }

          Future<void> changeMode(ReaderPageMode mode) async {
            tester
                .widget<ReaderChromeOverlay>(find.byType(ReaderChromeOverlay))
                .onSettings();
            await tester.pumpAndSettle();
            tester
                .widget<ReaderSettingsSheet>(find.byType(ReaderSettingsSheet))
                .onPageModeTap();
            await tester.pumpAndSettle();
            tester
                .widget<ReaderPageModeSheet>(find.byType(ReaderPageModeSheet))
                .onSelected(mode);
            await tester.pumpAndSettle();
            await settleWrites();
            await tester.pumpAndSettle();
          }

          try {
            await tester.pumpWidget(
              MaterialApp(
                navigatorKey: navigatorKey,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const SizedBox.shrink(),
              ),
            );
            await openReader(await savedBook());
            await settleWrites();
            if (initialOffset > 0) {
              final chapterLength = tester
                  .widgetList<ReaderAnnotatedTextPage>(
                    find.byType(ReaderAnnotatedTextPage),
                  )
                  .firstWhere((page) => page.chapterId == 'chapter2.xhtml')
                  .sourceText
                  .length;
              final expected = initialOffset.clamp(0, chapterLength);
              expect(
                (await savedBook())
                    .toCanonicalLocator()!
                    .textAnchor!
                    .startOffsetUtf16,
                expected,
                reason:
                    'Restoration preserves valid offsets and bounds outdated offsets to the chapter.',
              );
              if (initialOffset > chapterLength) {
                tester.binding.handleAppLifecycleStateChanged(
                  AppLifecycleState.inactive,
                );
                await settleWrites();
                await tester.binding.handlePopRoute();
                await settleWrites();
                await _pumpUntil(
                  tester,
                  () => find.byType(NativeReaderPage).evaluate().isEmpty,
                );
                expect(
                  (await savedBook())
                      .toCanonicalLocator()!
                      .textAnchor!
                      .startOffsetUtf16,
                  expected,
                );
                expect(find.byType(NativeReaderPage), findsNothing);
                return;
              }
            }
            await tester.drag(
              find.byKey(const ValueKey('native-vertical-reading-window')),
              const Offset(0, -537),
            );
            await tester.pumpAndSettle();
            await settleWrites();
            final before = (await savedBook()).toCanonicalLocator()!;
            final offset = before.textAnchor!.startOffsetUtf16!;
            expect(offset, greaterThan(0));

            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            await settleWrites();
            expect(
              (await savedBook())
                  .toCanonicalLocator()!
                  .textAnchor!
                  .startOffsetUtf16,
              offset,
              reason: 'Backgrounding must keep the visible text anchor.',
            );
            final resume = await tester.runAsync(
              ReadingResumeService.takePendingResume,
            );
            expect(
              LocatorCodec.decodeCanonicalLocator(
                resume!.canonicalLocator!,
              )!.textAnchor!.startOffsetUtf16,
              offset,
            );
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.binding.handlePopRoute();
            await settleWrites();
            await _pumpUntil(
              tester,
              () => find.byType(NativeReaderPage).evaluate().isEmpty,
            );
            final after = (await savedBook()).toCanonicalLocator()!;
            expect(after.chapterId, before.chapterId);
            expect(
              after.textAnchor!.startOffsetUtf16,
              offset,
              reason:
                  'Exiting must not replace the anchor with the part opening.',
            );
            for (var reopen = 0; reopen < 3; reopen++) {
              await openReader(await savedBook());
              final scrollable = tester.state<ScrollableState>(
                find
                    .descendant(
                      of: find.byType(ScrollablePositionedList),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
              expect(
                scrollable.position.pixels,
                greaterThan(0),
                reason: 'Reopening must scroll inside the saved text part.',
              );
              await settleWrites();
              expect(
                (await savedBook())
                    .toCanonicalLocator()!
                    .textAnchor!
                    .startOffsetUtf16,
                offset,
                reason:
                    'Restoring without reading must not advance the saved anchor.',
              );
              final viewportCenter =
                  MediaQuery.sizeOf(
                    tester.element(find.byType(NativeReaderPage)),
                  ).height /
                  2;
              final anchorPageFinder = find.byWidgetPredicate(
                (widget) =>
                    widget is ReaderAnnotatedTextPage &&
                    widget.chapterId == before.chapterId &&
                    widget.page.startOffset <= offset &&
                    widget.page.endOffset > offset,
              );
              expect(anchorPageFinder, findsOneWidget);
              final anchorPage = tester.widget<ReaderAnnotatedTextPage>(
                anchorPageFinder,
              );
              final paragraph = tester.renderObject<RenderParagraph>(
                find
                    .descendant(
                      of: anchorPageFinder,
                      matching: find.byType(RichText),
                    )
                    .first,
              );
              final caret = paragraph.getOffsetForCaret(
                TextPosition(
                  offset: anchorPage.page.textOffsetForSourceOffset(offset),
                ),
                Rect.zero,
              );
              expect(
                paragraph.localToGlobal(caret).dy,
                closeTo(viewportCenter, 1),
                reason:
                    'The saved text must be painted at the same viewport reference.',
              );

              await tester.binding.handlePopRoute();
              await settleWrites();
              await _pumpUntil(
                tester,
                () => find.byType(NativeReaderPage).evaluate().isEmpty,
              );
              expect(
                (await savedBook())
                    .toCanonicalLocator()!
                    .textAnchor!
                    .startOffsetUtf16,
                offset,
                reason: 'Repeated reopening/closing must not drift.',
              );
            }

            await openReader(await savedBook());
            await tester.drag(
              find.byKey(const ValueKey('native-vertical-reading-window')),
              const Offset(0, 250),
            );
            await tester.pumpAndSettle();
            await settleWrites();
            final backward = (await savedBook()).toCanonicalLocator()!;
            expect(backward.chapterId, before.chapterId);
            expect(
              backward.textAnchor!.startOffsetUtf16,
              lessThan(offset),
              reason: 'An actual backward scroll must still update progress.',
            );
            if (initialOffset > 0) {
              await changeMode(ReaderPageMode.horizontalSlide);
              final paged = (await savedBook()).toCanonicalLocator()!;
              await changeMode(ReaderPageMode.verticalScroll);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await settleWrites();
              expect(
                (await savedBook())
                    .toCanonicalLocator()!
                    .textAnchor!
                    .startOffsetUtf16,
                paged.textAnchor!.startOffsetUtf16,
                reason:
                    'Mode changes must not revive an earlier vertical anchor.',
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );

              tester
                  .widget<ReaderChromeOverlay>(find.byType(ReaderChromeOverlay))
                  .onTableOfContents!();
              await tester.pumpAndSettle();
              final target = LocatorCodec.encodeCanonicalLocator(
                CanonicalLocator.fromComponents(
                  format: BookFormat.epub,
                  chapterId: 'chapter3.xhtml',
                  offset: 4500,
                ),
              );
              tester
                  .widget<ReaderNavigationSheet>(
                    find.byType(ReaderNavigationSheet),
                  )
                  .onBookmarkSelected(
                    Bookmark(
                      bookId: bookId,
                      pageNumber: 2,
                      chapterIndex: 2,
                      canonicalLocator: target,
                    ),
                  );
              await settleWrites();
              await tester.pumpAndSettle();
              await settleWrites();
              final jumped = (await savedBook()).toCanonicalLocator()!;
              expect(jumped.chapterId, 'chapter3.xhtml');
              expect(
                jumped.textAnchor!.startOffsetUtf16,
                4500,
                reason:
                    'Bookmark restoration must persist its exact target, not an intermediate scroll.',
              );
              tester
                  .widget<ReaderChromeOverlay>(find.byType(ReaderChromeOverlay))
                  .onTableOfContents!();
              await tester.pumpAndSettle();
              tester
                  .widget<ReaderNavigationSheet>(
                    find.byType(ReaderNavigationSheet),
                  )
                  .onChapterSelected(0);
              await settleWrites();
              await tester.pumpAndSettle();
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await settleWrites();
              final chapterOpening = (await savedBook()).toCanonicalLocator()!;
              expect(chapterOpening.chapterId, 'chapter1.xhtml');
              expect(
                chapterOpening.textAnchor!.startOffsetUtf16,
                0,
                reason:
                    'A chapter jump must not reuse the preceding chapter anchor.',
              );
            }
          } finally {
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            await drainReaderCache(tester);
            await tester.binding.setSurfaceSize(null);
            debugDefaultTargetPlatformOverride = null;
            directory.deleteSync(recursive: true);
          }
        },
      );
    }
  }

  testWidgets(
    'EPUB system back persists the pending horizontal page before reopening',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(480, 800));
      SharedPreferences.setMockInitialValues({
        ReaderSettingsStore.pageModeKey: ReaderPageMode.horizontalSlide.name,
      });
      final directory = Directory.systemTemp.createTempSync(
        'open-reading-epub-resume-progress-',
      );
      final epub = File('${directory.path}/resume-progress.epub')
        ..writeAsBytesSync(_epubFixture());
      final bookId = (await tester.runAsync<int>(
        () => BookDao().insertBook(
          Book(
            title: 'EPUB resume progress fixture',
            filePath: epub.path,
            format: 'epub',
            fileModifiedTime: epub.lastModifiedSync().millisecondsSinceEpoch,
          ),
        ),
      ))!;
      final navigatorKey = GlobalKey<NavigatorState>();

      Future<PageController> openReader(Book book) async {
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => NativeReaderPage(
              book: book,
              replaceRuleService: replaceRuleService,
            ),
          ),
        );
        await tester.pump();
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
        return tester.widget<PageView>(find.byType(PageView)).controller!;
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SizedBox.shrink(),
          ),
        );
        final firstBook = (await tester.runAsync(
          () => BookDao().getBookById(bookId),
        ))!;
        final controller = await openReader(firstBook);
        final targetControllerPage = controller.initialPage + 5;
        unawaited(
          controller.animateToPage(
            targetControllerPage,
            duration: const Duration(seconds: 1),
            curve: Curves.linear,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 650));

        final pageView = tester.widget<PageView>(find.byType(PageView));
        final activeControllerPage = pageView.controller!.page!.round();
        expect(activeControllerPage, greaterThan(controller.initialPage));
        final activeLeaf = _pageLeafForControllerPage(tester, pageView);
        expect(activeLeaf.metadata.pageNumber, greaterThan(1));

        await tester.binding.handlePopRoute();
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 60; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
            if (find.byType(NativeReaderPage).evaluate().isEmpty) return;
          }
        });
        await _pumpUntil(
          tester,
          () => find.byType(NativeReaderPage).evaluate().isEmpty,
        );

        final savedBook = (await tester.runAsync(
          () => BookDao().getBookById(bookId),
        ))!;
        final savedLocator = savedBook.toCanonicalLocator();
        expect(savedLocator?.textAnchor?.startOffsetUtf16, greaterThan(0));

        final restoredController = await openReader(savedBook);
        final restoredPageView = tester.widget<PageView>(find.byType(PageView));
        expect(restoredController.initialPage, greaterThan(0));
        final restoredLeaf = _pageLeafForControllerPage(
          tester,
          restoredPageView,
        );
        expect(
          restoredLeaf.metadata.chapterTitle,
          activeLeaf.metadata.chapterTitle,
        );
        expect(
          restoredLeaf.metadata.pageNumber,
          activeLeaf.metadata.pageNumber,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await drainReaderCache(tester);
        await tester.binding.setSurfaceSize(null);
        debugDefaultTargetPlatformOverride = null;
        directory.deleteSync(recursive: true);
      }
    },
  );
}

ReaderPaperPageLeaf _pageLeafForControllerPage(
  WidgetTester tester,
  PageView pageView,
) {
  final delegate = pageView.childrenDelegate as SliverChildBuilderDelegate;
  return delegate.builder(
        tester.element(find.byType(PageView)),
        pageView.controller!.page!.round(),
      )!
      as ReaderPaperPageLeaf;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
  }
  fail('Timed out waiting for EPUB reader state.');
}

List<int> _epubFixture({int chapterCount = 3}) {
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
    <dc:identifier id="book-id">initial-progress-fixture</dc:identifier>
    <dc:title>Initial progress fixture</dc:title><dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    ${List.generate(chapterCount, (index) => '<item id="c${index + 1}" href="chapter${index + 1}.xhtml" media-type="application/xhtml+xml"/>').join()}
  </manifest>
  <spine toc="ncx">${List.generate(chapterCount, (index) => '<itemref idref="c${index + 1}"/>').join()}</spine>
</package>''');
  add('OEBPS/toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="initial-progress-fixture"/></head>
  <docTitle><text>Initial progress fixture</text></docTitle>
  <navMap>${List.generate(chapterCount, (index) => '<navPoint id="nav${index + 1}" playOrder="${index + 1}"><navLabel><text>Chapter ${index + 1}</text></navLabel><content src="chapter${index + 1}.xhtml"/></navPoint>').join()}</navMap>
</ncx>''');
  for (var chapter = 1; chapter <= chapterCount; chapter++) {
    add('OEBPS/chapter$chapter.xhtml', '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $chapter</title></head><body>
<h1>Chapter $chapter</h1>
${List.generate(80, (index) => '<p>Chapter $chapter paragraph $index contains enough text to create deterministic reader pages and restore a saved position without flashing the chapter opening.</p>').join()}
</body></html>''');
  }
  return ZipEncoder().encode(archive)!;
}
