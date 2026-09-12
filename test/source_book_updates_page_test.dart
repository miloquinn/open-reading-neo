import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/library/source_book_updates_page.dart';
import 'package:xxread/services/library/download_task_controller.dart';

void main() {
  testWidgets('boundary requires a chapter and preserves the selected ID', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('source-boundary');
    addTearDown(() => directory.delete(recursive: true));
    final original = _shelfBook('${directory.path}/serial.txt');
    final loaded = original.copyWith(title: 'Reloaded Serial Novel');
    final service = _PageShelfService();
    var loaderCalls = 0;

    await tester.pumpWidget(
      _harness(
        book: original,
        service: service,
        bookUid: 'stable-page-uid',
        bookLoader: (id) async {
          loaderCalls++;
          expect(id, original.id);
          return loaded;
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Reloaded Serial Novel'), findsOneWidget);

    await tester.tap(find.text('确认已下载章节'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final dialog = find.byType(AlertDialog);
    final confirm = find.descendant(
      of: dialog,
      matching: find.widgetWithText(FilledButton, '确定'),
    );
    expect(confirm, findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.text('第二章'));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(service.baselineCalls, hasLength(1));
    final call = service.baselineCalls.single;
    expect(call.shelfBook, same(loaded));
    expect(call.chapterIds, ['chapter-1', 'chapter-2', 'chapter-3']);
    expect(call.lastDownloadedChapterId, 'chapter-2');
    expect(call.mappingConfirmed, isTrue);
    expect(call.bookUid, 'stable-page-uid');
    expect(find.text('已确认追更起点，可以检查新章节了。'), findsOneWidget);
    expect(loaderCalls, greaterThanOrEqualTo(2));
  });

  testWidgets('both source update actions reach their distinct queue modes', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('source-actions');
    addTearDown(() => directory.delete(recursive: true));
    final book = _shelfBook('${directory.path}/serial.txt');
    final service = _PageShelfService();

    await tester.pumpWidget(
      _harness(
        book: book,
        service: service,
        bookUid: 'stable-page-uid',
        bookLoader: (_) async => book,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await _runUpdateAction(tester, '检查新章节');
    await _runUpdateAction(tester, '刷新已下载章节');

    expect(service.updateCalls, hasLength(2));
    expect(service.updateCalls[0].shelfBook, same(book));
    expect(service.updateCalls[0].mode, SourceUpdateMode.appendNewChapters);
    expect(service.updateCalls[0].bookUid, 'stable-page-uid');
    expect(
      service.updateCalls[1].mode,
      SourceUpdateMode.refreshDownloadedChapters,
    );
  });
}

Future<void> _runUpdateAction(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  final close = find.descendant(
    of: dialog,
    matching: find.widgetWithText(TextButton, '确定'),
  );
  expect(close, findsOneWidget);
  await tester.tap(close);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Widget _harness({
  required Book book,
  required _PageShelfService service,
  required Future<Book?> Function(int id) bookLoader,
  required String bookUid,
}) => ChangeNotifierProvider(
  create: (_) => DownloadTaskController(),
  child: MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: SourceBookUpdatesPage(
      book: book,
      shelfService: service,
      bookLoader: bookLoader,
      bookUid: bookUid,
    ),
  ),
);

Book _shelfBook(String filePath) => Book(
  id: 73,
  title: 'Serial Novel',
  author: 'Author',
  filePath: filePath,
  format: 'txt',
  sourceId: _source.id,
  sourceBookId: _sourceBook.id,
  sourceJson: '{}',
  sourceBookJson: '{}',
);

final _source = RegisteredBookSource(
  id: 'source-id',
  name: 'Source',
  description: '',
  manifestUrl: Uri.parse('https://example.com/manifest.json'),
  apiBaseUrl: Uri.parse('https://example.com/api/'),
  protocolVersion: '1.0',
  languages: const ['zh-CN'],
  capabilities: const {'content'},
  enabled: true,
  addedAt: DateTime.utc(2026, 9, 12),
);

const _sourceBook = BookSourceBook(
  id: 'source-book-id',
  title: 'Serial Novel',
  author: 'Author',
  description: '',
  categories: [],
);

const _chapters = [
  BookSourceChapter(id: 'chapter-1', title: '第一章', order: 1),
  BookSourceChapter(id: 'chapter-2', title: '第二章', order: 2),
  BookSourceChapter(id: 'chapter-3', title: '第三章', order: 3),
];

class _BaselineCall {
  const _BaselineCall({
    required this.shelfBook,
    required this.chapterIds,
    required this.lastDownloadedChapterId,
    required this.mappingConfirmed,
    required this.bookUid,
  });

  final Book shelfBook;
  final List<String> chapterIds;
  final String lastDownloadedChapterId;
  final bool mappingConfirmed;
  final String? bookUid;
}

class _UpdateCall {
  const _UpdateCall({
    required this.shelfBook,
    required this.mode,
    required this.bookUid,
  });

  final Book shelfBook;
  final SourceUpdateMode mode;
  final String? bookUid;
}

class _PageShelfService extends BookSourceShelfService {
  final List<_BaselineCall> baselineCalls = [];
  final List<_UpdateCall> updateCalls = [];

  @override
  RegisteredBookSource sourceFrom(Book book) => _source;

  @override
  BookSourceBook sourceBookFrom(Book book) => _sourceBook;

  @override
  Future<List<BookSourceChapter>> sourceChaptersFor(Book book) async =>
      _chapters;

  @override
  Future<SourceChapterState> establishTrackingBaseline({
    required Book shelfBook,
    required List<BookSourceChapter> sourceChapters,
    required String lastDownloadedChapterId,
    required bool mappingConfirmed,
    String? bookUid,
  }) async {
    baselineCalls.add(
      _BaselineCall(
        shelfBook: shelfBook,
        chapterIds: sourceChapters.map((chapter) => chapter.id).toList(),
        lastDownloadedChapterId: lastDownloadedChapterId,
        mappingConfirmed: mappingConfirmed,
        bookUid: bookUid,
      ),
    );
    return SourceChapterState(
      schemaVersion: 1,
      bookUid: bookUid!,
      sourceId: _source.id,
      sourceBookId: _sourceBook.id,
      materializedContentHash: 'content-hash',
      baselineKnown: false,
      chapters: const [],
      catalogChapterIds: sourceChapters
          .takeWhile((chapter) => chapter.id != lastDownloadedChapterId)
          .map((chapter) => chapter.id)
          .followedBy([lastDownloadedChapterId])
          .toList(),
      conflicts: const [],
      revisionOrigin: SourceRevisionOrigin.sourceRebind,
    );
  }

  @override
  Future<SourceUpdateResult> updateDownloadedBook({
    required Book shelfBook,
    required SourceUpdateMode mode,
    String? bookUid,
    void Function(int completed, int total)? onProgress,
    BookDownloadCancellation? cancellation,
  }) async {
    updateCalls.add(
      _UpdateCall(shelfBook: shelfBook, mode: mode, bookUid: bookUid),
    );
    onProgress?.call(1, 1);
    return SourceUpdateResult(
      book: shelfBook,
      status: SourceUpdateStatus.noChanges,
      addedChapterCount: 0,
      refreshedChapterCount: 0,
      conflictCount: 0,
      materializedContentHash: 'content-hash',
      revisionOrigin: SourceRevisionOrigin.sourceRefresh,
    );
  }
}
