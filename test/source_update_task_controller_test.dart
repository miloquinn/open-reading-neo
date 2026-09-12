import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/library/download_task_controller.dart';

void main() {
  test(
    'source update keeps its mode, stable UID, and original shelf book',
    () async {
      final service = _RecordingUpdateService();
      final controller = DownloadTaskController();
      final shelfBook = _shelfBook();

      final taskId = controller.enqueueSourceUpdate(
        shelfBook: shelfBook,
        mode: SourceUpdateMode.refreshDownloadedChapters,
        shelfService: service,
        bookUid: 'stable-book-uid',
      );

      final queuedTask = controller.taskById(taskId);
      expect(queuedTask?.shelfBook, same(shelfBook));
      expect(
        queuedTask?.updateMode,
        SourceUpdateMode.refreshDownloadedChapters,
      );
      expect(queuedTask?.bookUid, 'stable-book-uid');

      await _waitFor(() => service.calls.isNotEmpty);
      final call = service.calls.single;
      expect(call.shelfBook, same(shelfBook));
      expect(call.mode, SourceUpdateMode.refreshDownloadedChapters);
      expect(call.bookUid, 'stable-book-uid');

      service.complete(
        _result(
          shelfBook,
          status: SourceUpdateStatus.updated,
          added: 2,
          refreshed: 3,
          conflicts: 1,
        ),
      );
      await _waitFor(
        () => controller.taskById(taskId)?.state == DownloadTaskState.completed,
      );
    },
  );

  test('completed task retains update status and chapter counts', () async {
    final service = _RecordingUpdateService();
    final controller = DownloadTaskController();
    final shelfBook = _shelfBook();
    final expected = _result(
      shelfBook,
      status: SourceUpdateStatus.conflicts,
      added: 4,
      refreshed: 5,
      conflicts: 2,
    );

    final taskId = controller.enqueueSourceUpdate(
      shelfBook: shelfBook,
      mode: SourceUpdateMode.appendNewChapters,
      shelfService: service,
      bookUid: 'book-uid',
    );
    await _waitFor(() => service.calls.isNotEmpty);
    service.complete(expected);
    await _waitFor(
      () => controller.taskById(taskId)?.state == DownloadTaskState.completed,
    );

    final completed = controller.taskById(taskId)!;
    expect(completed.sourceUpdateResult, same(expected));
    expect(completed.sourceUpdateResult?.status, SourceUpdateStatus.conflicts);
    expect(completed.sourceUpdateResult?.addedChapterCount, 4);
    expect(completed.sourceUpdateResult?.refreshedChapterCount, 5);
    expect(completed.sourceUpdateResult?.conflictCount, 2);
    expect(completed.downloadedBook, same(shelfBook));
  });

  test('controller closes an owned update service after completion', () async {
    final service = _RecordingUpdateService();
    final controller = DownloadTaskController();
    final shelfBook = _shelfBook();

    final taskId = controller.enqueueSourceUpdate(
      shelfBook: shelfBook,
      mode: SourceUpdateMode.appendNewChapters,
      shelfService: service,
      bookUid: 'book-uid',
      closeServiceWhenDone: true,
    );
    await _waitFor(() => service.calls.isNotEmpty);
    service.complete(_result(shelfBook));
    await _waitFor(() => service.closeCalls == 1);

    expect(controller.taskById(taskId)?.state, DownloadTaskState.completed);
    expect(controller.hasActiveTasks, isFalse);
  });

  test(
    'cancelling an active update closes and releases its owned service',
    () async {
      final firstService = _RecordingUpdateService();
      final controller = DownloadTaskController(maxConcurrentDownloads: 1);
      final shelfBook = _shelfBook();
      final firstTaskId = controller.enqueueSourceUpdate(
        shelfBook: shelfBook,
        mode: SourceUpdateMode.appendNewChapters,
        shelfService: firstService,
        bookUid: 'book-uid',
        closeServiceWhenDone: true,
      );
      await _waitFor(() => firstService.calls.isNotEmpty);

      expect(controller.cancelTask(firstTaskId), isTrue);
      await _waitFor(() => firstService.closeCalls == 1);
      expect(
        controller.taskById(firstTaskId)?.state,
        DownloadTaskState.cancelled,
      );
      expect(controller.hasActiveTasks, isFalse);

      final replacementService = _RecordingUpdateService();
      final replacementTaskId = controller.enqueueSourceUpdate(
        shelfBook: shelfBook,
        mode: SourceUpdateMode.appendNewChapters,
        shelfService: replacementService,
        bookUid: 'book-uid',
      );
      await _waitFor(() => replacementService.calls.isNotEmpty);
      replacementService.complete(_result(shelfBook));
      await _waitFor(
        () =>
            controller.taskById(replacementTaskId)?.state ==
            DownloadTaskState.completed,
      );
    },
  );
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the source update task.');
}

Book _shelfBook() => Book(
  id: 41,
  title: 'Serial Novel',
  author: 'Author',
  filePath: '/tmp/serial-novel.txt',
  format: 'txt',
  sourceId: _source.id,
  sourceBookId: _sourceBook.id,
  sourceJson: '{}',
  sourceBookJson: '{}',
);

SourceUpdateResult _result(
  Book book, {
  SourceUpdateStatus status = SourceUpdateStatus.noChanges,
  int added = 0,
  int refreshed = 0,
  int conflicts = 0,
}) => SourceUpdateResult(
  book: book,
  status: status,
  addedChapterCount: added,
  refreshedChapterCount: refreshed,
  conflictCount: conflicts,
  materializedContentHash: 'content-hash',
  revisionOrigin: SourceRevisionOrigin.sourceRefresh,
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

class _RecordingUpdateService extends BookSourceShelfService {
  final List<_UpdateCall> calls = [];
  final Completer<SourceUpdateResult> _completion = Completer();
  int closeCalls = 0;

  @override
  RegisteredBookSource sourceFrom(Book book) => _source;

  @override
  BookSourceBook sourceBookFrom(Book book) => _sourceBook;

  @override
  Future<SourceUpdateResult> updateDownloadedBook({
    required Book shelfBook,
    required SourceUpdateMode mode,
    String? bookUid,
    void Function(int completed, int total)? onProgress,
    BookDownloadCancellation? cancellation,
  }) async {
    calls.add(_UpdateCall(shelfBook: shelfBook, mode: mode, bookUid: bookUid));
    onProgress?.call(1, 2);
    await Future.any<void>([
      _completion.future.then<void>((_) {}),
      if (cancellation != null) cancellation.whenCancelled,
    ]);
    cancellation?.throwIfCancelled();
    onProgress?.call(2, 2);
    return _completion.future;
  }

  void complete(SourceUpdateResult result) {
    if (!_completion.isCompleted) _completion.complete(result);
  }

  @override
  void close() {
    closeCalls++;
  }
}
