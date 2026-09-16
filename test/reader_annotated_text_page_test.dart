import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/core/reader/native_text_paginator.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/core/reader/reader_annotation.dart';
import 'package:xxread/core/reader/reader_text_pagination.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_annotated_text_page.dart';
import 'package:xxread/widgets/reader_chapter_title_page.dart';
import 'package:xxread/widgets/reader_tap_observer.dart';

void main() {
  testWidgets('moving spoken highlight preserves every character position', (
    tester,
  ) async {
    const source = '翻页后正文保持原来的字重。正在朗读的句子只改变背景色。Next sentence stays in place.';
    const bodyStyle = TextStyle(
      fontSize: 20,
      height: 1.6,
      fontWeight: FontWeight.w400,
    );
    Future<List<Rect>> render(ReaderAloudHighlight? highlight) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 500,
              child: ReaderAnnotatedTextPage(
                page: const ReaderTextPage(text: source),
                sourceText: source,
                chapterId: 'chapter-1',
                chapterTitle: '第一章',
                chapterIndex: 0,
                pageIndex: 0,
                bookId: 1,
                format: BookFormat.txt,
                renderer: ReaderRendererType.flutterNative,
                palette: ReaderThemes.day,
                bodyStyle: bodyStyle,
                flowStyle: const NativeTextFlowStyle(
                  textDirection: TextDirection.ltr,
                  textScaler: TextScaler.noScaling,
                  locale: Locale('zh'),
                  strutStyle: null,
                  textHeightBehavior: readerTextHeightBehavior,
                ),
                annotations: const [],
                spokenHighlight: highlight,
                onSaveTextAnnotation: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(ReaderAnnotatedTextPage),
          matching: find.byType(RichText),
        ),
      );
      return [
        for (var i = 0; i < source.length; i++)
          for (final box in paragraph.getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
          ))
            box.toRect().shift(paragraph.localToGlobal(Offset.zero)),
      ];
    }

    final original = await render(null);
    expect(original, isNotEmpty);
    for (final range in [(0, 14), (14, 31), (31, source.length)]) {
      expect(
        await render(
          ReaderAloudHighlight(
            chapterIndex: 0,
            chapterId: 'chapter-1',
            startOffset: range.$1,
            endOffset: range.$2,
          ),
        ),
        original,
      );
    }
    expect(await render(null), original);
  });

  testWidgets('inline chapter title is outside selectable body coordinates', (
    tester,
  ) async {
    const bodyStyle = TextStyle(fontSize: 20, height: 1.6);
    const flowStyle = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: Locale('zh'),
      strutStyle: null,
      textHeightBehavior: readerTextHeightBehavior,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 260,
            child: ReaderAnnotatedTextPage(
              page: const ReaderTextPage(
                text: '正文',
                showsInlineChapterTitle: true,
              ),
              sourceText: '正文',
              chapterId: 'chapter-1',
              chapterTitle: '第一章',
              chapterIndex: 0,
              pageIndex: 0,
              bookId: 1,
              format: BookFormat.txt,
              renderer: ReaderRendererType.flutterNative,
              palette: ReaderThemes.green,
              bodyStyle: bodyStyle,
              flowStyle: flowStyle,
              annotations: const [],
              onSaveTextAnnotation: (_, _) async {},
            ),
          ),
        ),
      ),
    );

    final title = find.byType(ReaderInlineChapterTitle);
    final body = find.descendant(
      of: find.byType(SelectionArea),
      matching: find.byType(RichText),
    );
    expect(title, findsOneWidget);
    expect(
      find.ancestor(of: title, matching: find.byType(SelectionArea)),
      findsNothing,
    );
    expect(
      find.ancestor(of: body, matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: body, matching: find.byType(Expanded)),
      findsOneWidget,
    );
    expect(tester.getTopLeft(title).dy, lessThan(tester.getTopLeft(body).dy));
  });

  testWidgets('inline chapter title uses natural height in scrolling layout', (
    tester,
  ) async {
    const bodyStyle = TextStyle(fontSize: 20, height: 1.6);
    const flowStyle = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: Locale('zh'),
      strutStyle: null,
      textHeightBehavior: readerTextHeightBehavior,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderAnnotatedTextPage(
            page: const ReaderTextPage(
              text: '正文',
              showsInlineChapterTitle: true,
            ),
            sourceText: '正文',
            chapterId: 'chapter-1',
            chapterTitle: '第一章',
            chapterIndex: 0,
            pageIndex: 0,
            bookId: 1,
            format: BookFormat.txt,
            renderer: ReaderRendererType.flutterNative,
            palette: ReaderThemes.green,
            bodyStyle: bodyStyle,
            flowStyle: flowStyle,
            annotations: const [],
            onSaveTextAnnotation: (_, _) async {},
            fillAvailableSpace: false,
          ),
        ),
      ),
    );

    final body = find.descendant(
      of: find.byType(SelectionArea),
      matching: find.byType(RichText),
    );
    expect(find.byType(ReaderInlineChapterTitle), findsOneWidget);
    expect(
      find.ancestor(of: body, matching: find.byType(Expanded)),
      findsNothing,
    );
  });

  testWidgets(
    'selection toolbar follows the reader palette and saves highlight',
    (tester) async {
      ReaderSelectionSnapshot? savedSelection;
      ReaderAnnotationEditorResult? savedAnnotation;
      var readerTaps = 0;
      const bodyStyle = TextStyle(fontSize: 20, height: 1.6);
      final flowStyle = NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: const Locale('zh'),
        strutStyle: readerStrutStyle(bodyStyle),
        textHeightBehavior: readerTextHeightBehavior,
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 260,
                child: ReaderTapObserver(
                  onTap: (_) => readerTaps++,
                  child: ReaderAnnotatedTextPage(
                    page: const ReaderTextPage(text: '选择这段文字进行高亮和批注。'),
                    sourceText: '选择这段文字进行高亮和批注。',
                    chapterId: 'chapter-1',
                    chapterTitle: '第一章',
                    chapterIndex: 0,
                    pageIndex: 0,
                    bookId: 1,
                    format: BookFormat.txt,
                    renderer: ReaderRendererType.flutterNative,
                    palette: ReaderThemes.green,
                    bodyStyle: bodyStyle,
                    flowStyle: flowStyle,
                    annotations: const [],
                    onSaveTextAnnotation: (selection, annotation) async {
                      savedSelection = selection;
                      savedAnnotation = annotation;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final richText = find.descendant(
        of: find.byType(ReaderAnnotatedTextPage),
        matching: find.byType(RichText),
      );
      final paragraph = tester.renderObject<RenderParagraph>(richText);
      final characterBox = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 5, extentOffset: 6),
          )
          .single
          .toRect();
      final gesture = await tester.startGesture(
        paragraph.localToGlobal(characterBox.center),
      );
      addTearDown(gesture.removePointer);
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();

      final toolbar = tester.widget<Material>(
        find.byKey(const ValueKey('reader-selection-toolbar')),
      );
      expect(toolbar.color, Colors.transparent);
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('reader-selection-toolbar')),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      expect(find.text('高亮'), findsOneWidget);
      expect(find.text('批注'), findsNothing);
      expect(find.text('笔记'), findsOneWidget);
      expect(find.text('画笔记'), findsNothing);
      expect(readerTaps, 0);

      await tester.tap(find.text('高亮'));
      await tester.pumpAndSettle();
      expect(find.text('荧光笔颜色'), findsOneWidget);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(savedSelection?.selectedText, isNotEmpty);
      expect(savedAnnotation?.type, readerAnnotationTypeHighlight);
    },
  );

  testWidgets('ask AI action hands the selection to the reader', (
    tester,
  ) async {
    ReaderSelectionSnapshot? askedSelection;
    final interactionChanges = <bool>[];
    const bodyStyle = TextStyle(fontSize: 20, height: 1.6);
    final flowStyle = NativeTextFlowStyle(
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      locale: const Locale('zh'),
      strutStyle: readerStrutStyle(bodyStyle),
      textHeightBehavior: readerTextHeightBehavior,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 260,
              child: ReaderAnnotatedTextPage(
                page: const ReaderTextPage(text: '选择这段文字去问问AI助手。'),
                sourceText: '选择这段文字去问问AI助手。',
                chapterId: 'chapter-1',
                chapterTitle: '第一章',
                chapterIndex: 0,
                pageIndex: 0,
                bookId: 1,
                format: BookFormat.txt,
                renderer: ReaderRendererType.flutterNative,
                palette: ReaderThemes.green,
                bodyStyle: bodyStyle,
                flowStyle: flowStyle,
                annotations: const [],
                onSaveTextAnnotation: (_, _) async {},
                onAskAiSelection: (selection) async {
                  askedSelection = selection;
                },
                onInteractionChanged: interactionChanges.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final richText = find.descendant(
      of: find.byType(ReaderAnnotatedTextPage),
      matching: find.byType(RichText),
    );
    final paragraph = tester.renderObject<RenderParagraph>(richText);
    final characterBox = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 5, extentOffset: 6),
        )
        .single
        .toRect();
    final gesture = await tester.startGesture(
      paragraph.localToGlobal(characterBox.center),
    );
    addTearDown(gesture.removePointer);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('问AI'), findsOneWidget);
    await tester.tap(find.text('问AI'));
    await tester.pumpAndSettle();

    expect(askedSelection?.selectedText, isNotEmpty);
    expect(interactionChanges, [true, false]);
  });

  testWidgets(
    'tapping an underlined note opens its details without turning the page',
    (tester) async {
      var readerTaps = 0;
      final interactionChanges = <bool>[];
      const sourceText = '点击笔记文字查看内容';
      const bodyStyle = TextStyle(fontSize: 20, height: 1.6);
      final flowStyle = NativeTextFlowStyle(
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
        locale: const Locale('zh'),
        strutStyle: readerStrutStyle(bodyStyle),
        textHeightBehavior: readerTextHeightBehavior,
      );
      final note = BookNote(
        bookId: 1,
        content: '点击笔记',
        cfi: 'or-annotation:note:chapter-1:0:4',
        chapter: '第一章',
        type: readerAnnotationTypeNote,
        color: '7DD3FC',
        readerNote: '这是保存的笔记内容。',
        startOffset: 0,
        endOffset: 4,
        createTime: DateTime(2026, 7, 26),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 260,
                child: ReaderTapObserver(
                  onTap: (_) => readerTaps++,
                  child: ReaderAnnotatedTextPage(
                    page: const ReaderTextPage(text: sourceText),
                    sourceText: sourceText,
                    chapterId: 'chapter-1',
                    chapterTitle: '第一章',
                    chapterIndex: 0,
                    pageIndex: 0,
                    bookId: 1,
                    format: BookFormat.txt,
                    renderer: ReaderRendererType.flutterNative,
                    palette: ReaderThemes.night,
                    bodyStyle: bodyStyle,
                    flowStyle: flowStyle,
                    annotations: [note],
                    onSaveTextAnnotation: (_, _) async {},
                    onInteractionChanged: interactionChanges.add,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final richText = find.descendant(
        of: find.byType(ReaderAnnotatedTextPage),
        matching: find.byType(RichText),
      );
      final paragraph = tester.renderObject<RenderParagraph>(richText);
      final noteBox = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 4),
          )
          .first
          .toRect();

      await tester.tapAt(paragraph.localToGlobal(noteBox.center));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('reader-annotation-detail-sheet')),
        findsOneWidget,
      );
      expect(find.text('点击笔记'), findsOneWidget);
      expect(find.text('这是保存的笔记内容。'), findsOneWidget);
      expect(readerTaps, 0);
      expect(interactionChanges, [true]);

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(interactionChanges, [true, false]);
    },
  );
}
