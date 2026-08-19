import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/pages/export/reading_data_export_dialog.dart';
import 'package:xxread/services/export/reading_data_export.dart';

void main() {
  testWidgets(
    'preview explains whole-book scope and exports prepared document',
    (tester) async {
      final backend = _Backend();
      final service = ReadingDataExportService(
        repository: _Repository([
          _annotation('highlight', '高亮原文'),
          _annotation('underline', '下划线原文'),
          _annotation('note', '', readerNote: '私人笔记'),
        ]),
        backend: backend,
        clock: () => DateTime.utc(2026, 8, 17),
      );
      late BuildContext pageContext;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) {
              pageContext = context;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      );

      final future = showReadingDataExportDialog(
        pageContext,
        book: Book(
          id: 9,
          title: '示例书',
          author: '作者',
          filePath: '/book.epub',
          format: 'epub',
        ),
        serviceFactory: () => service,
      );
      await tester.pumpAndSettle();

      expect(find.text('整本书'), findsOneWidget);
      expect(find.textContaining('1 条高亮 · 1 条下划线 · 1 条笔记'), findsOneWidget);
      expect(find.textContaining('不包含书籍全文或书籍文件'), findsOneWidget);
      expect(find.textContaining('账户或设备信息'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('reading-data-export-confirm-button')),
      );
      await tester.pumpAndSettle();
      await future;

      expect(backend.calls, 1);
      expect(backend.request?.suggestedName, '示例书.md');
      expect(backend.request?.mimeType, 'text/markdown');
    },
  );

  testWidgets('empty annotations shows an empty-state toast without backend', (
    tester,
  ) async {
    final backend = _Backend();
    final service = ReadingDataExportService(
      repository: _Repository(const []),
      backend: backend,
    );
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );

    await showReadingDataExportDialog(
      pageContext,
      book: Book(id: 9, title: '空书', filePath: '/book.epub', format: 'epub'),
      serviceFactory: () => service,
    );
    await tester.pump();

    expect(find.textContaining('还没有可导出'), findsOneWidget);
    expect(backend.calls, 0);
  });
}

BookNote _annotation(String type, String content, {String? readerNote}) =>
    BookNote(
      annotationId: '$type-id',
      bookId: 9,
      content: content,
      cfi: '$type-cfi',
      chapter: '第一章',
      type: type,
      color: 'FFEB3B',
      readerNote: readerNote,
      pageNumber: 1,
      updateTime: DateTime.utc(2026, 8, 17),
    );

class _Repository implements ReadingDataExportRepository {
  _Repository(this.annotations);

  final List<BookNote> annotations;

  @override
  Future<List<BookNote>> annotationsForBook(int bookId) async => annotations;
}

class _Backend implements ReadingDataExportBackend {
  int calls = 0;
  ReadingDataExportRequest? request;

  @override
  Future<ReadingDataExportBackendResult> export(
    ReadingDataExportRequest request,
  ) async {
    calls++;
    this.request = request;
    return const ReadingDataExportBackendResult.success(
      displayName: '示例书.md',
      location: 'Download/开元阅读/示例书.md',
    );
  }
}
