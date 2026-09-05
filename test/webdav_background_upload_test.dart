import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';

void main() {
  test(
    'automatic uploads return immediately and dedupe the same book',
    () async {
      final controller = _FakeWebDavSyncController();
      final first = _book(1, '同一本书', '/tmp/first.epub');
      final duplicateIdentity = _book(1, '改过标题', '/tmp/moved.epub');

      expect(controller.enqueueNewBookUploads([first, duplicateIdentity]), 1);
      expect(controller.uploaded, isEmpty);

      controller.releaseFirstUpload();
      await _waitUntil(() => controller.uploaded.length == 1);
      expect(controller.uploaded, [first]);
      expect(controller.enqueueNewBookUploads([duplicateIdentity]), 0);
    },
  );

  test('different books with the same title are both uploaded', () async {
    final controller = _FakeWebDavSyncController();
    final first = _book(1, '同名书', '/tmp/first.epub');
    final second = _book(2, '同名书', '/tmp/second.epub');

    expect(controller.enqueueNewBookUploads([first, second]), 2);
    controller.releaseFirstUpload();
    await _waitUntil(() => controller.uploaded.length == 2);

    expect(controller.uploaded, [first, second]);
  });

  test('automatic uploads reject new queue work when auto sync is off', () {
    final controller = _FakeWebDavSyncController(autoSyncEnabled: false);

    expect(
      controller.enqueueNewBookUploads([
        _book(1, '不会上传', '/tmp/disabled.epub'),
      ]),
      0,
    );
    expect(controller.attempted, isEmpty);
  });

  test('a failed job is retained and retried before later jobs', () async {
    final controller = _FakeWebDavSyncController(failFirst: true);
    final failed = _book(1, '失败书', '/tmp/fail.epub');
    final later = _book(2, '稍后上传', '/tmp/later.epub');
    final fresh = _book(3, '触发重试', '/tmp/fresh.epub');

    expect(controller.enqueueNewBookUploads([failed, later]), 2);
    controller.releaseFirstUpload();
    await controller.firstFailureHandled;
    expect(controller.uploaded, isEmpty);

    expect(controller.enqueueNewBookUploads([fresh]), 1);
    await _waitUntil(() => controller.uploaded.length == 3);

    expect(controller.attempted, [failed, failed, later, fresh]);
    expect(controller.uploaded, [failed, later, fresh]);
  });
}

Book _book(int id, String title, String filePath) =>
    Book(id: id, title: title, filePath: filePath, format: 'epub');

class _FakeWebDavSyncController extends WebDavSyncController {
  _FakeWebDavSyncController({
    this.failFirst = false,
    this.autoSyncEnabled = true,
  });

  @override
  bool get isConfigured => true;

  @override
  WebDavSyncScope get scope => const WebDavSyncScope(bookFiles: true);

  @override
  bool get autoSync => autoSyncEnabled;

  final bool failFirst;
  final bool autoSyncEnabled;
  final List<Book> attempted = <Book>[];
  final List<Book> uploaded = <Book>[];
  final Completer<void> _firstUpload = Completer<void>();
  final Completer<void> _firstFailureHandled = Completer<void>();
  int _attempts = 0;

  Future<void> get firstFailureHandled => _firstFailureHandled.future;

  void releaseFirstUpload() {
    if (!_firstUpload.isCompleted) _firstUpload.complete();
  }

  @override
  Future<RemoteBookDescriptor> uploadBookFile(
    Book book, {
    bool incrementalTxt = false,
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    final attempt = _attempts++;
    attempted.add(book);
    if (attempt == 0) {
      await _firstUpload.future;
      if (failFirst) {
        Timer.run(() => _firstFailureHandled.complete());
        throw StateError('expected background failure');
      }
    }
    uploaded.add(book);
    return RemoteBookDescriptor(
      bookUid: 'local-${book.title}',
      title: book.title,
      author: book.author,
      format: book.format,
      fileAvailable: true,
    );
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached before $timeout');
    }
    await Future<void>.delayed(Duration.zero);
  }
}
