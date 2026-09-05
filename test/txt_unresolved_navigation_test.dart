import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/models/bookmark.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_navigation_sheet.dart';

void main() {
  testWidgets('unresolved TXT references stay visible but cannot navigate', (
    tester,
  ) async {
    var bookmarkSelections = 0;
    var annotationSelections = 0;
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final bookmark = Bookmark(
      id: 1,
      bookId: 7,
      pageNumber: 2,
      chapterTitle: '旧章节',
      excerpt: '仍然保留的书签摘录',
    );
    final annotation = BookNote(
      id: 2,
      annotationId: 'note-2',
      bookId: 7,
      content: '仍然保留的笔记摘录',
      cfi: '',
      chapter: '旧章节',
      type: 'highlight',
      color: 'FFD54F',
      payloadJson: '{"txt_locator_status":"unresolved"}',
      createTime: DateTime(2026, 9, 5),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ReaderNavigationSheet(
            palette: ReaderThemes.day,
            chapters: const [ReaderNavigationChapter(title: '当前章节', index: 0)],
            currentChapterIndex: 0,
            bookmarks: [bookmark],
            annotations: [annotation],
            onChapterSelected: (_) {},
            onBookmarkSelected: (_) => bookmarkSelections++,
            onBookmarkDeleted: (_) {},
            onAnnotationSelected: (_) => annotationSelections++,
            onAnnotationDeleted: (_) {},
            isBookmarkNavigable: (_) => false,
            isAnnotationNavigable: (_) => false,
            unavailableLocationLabel: '原位置已失效',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('书签'));
    await tester.pumpAndSettle();
    expect(find.text('仍然保留的书签摘录'), findsOneWidget);
    expect(find.textContaining('原位置已失效'), findsOneWidget);
    await tester.tap(find.text('仍然保留的书签摘录'));
    expect(bookmarkSelections, 0);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copiedText, '仍然保留的书签摘录');

    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    expect(find.text('仍然保留的笔记摘录'), findsOneWidget);
    expect(find.textContaining('原位置已失效'), findsOneWidget);
    await tester.tap(find.text('仍然保留的笔记摘录'));
    expect(annotationSelections, 0);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copiedText, '仍然保留的笔记摘录');
  });
}
