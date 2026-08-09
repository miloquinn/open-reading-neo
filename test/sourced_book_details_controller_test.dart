import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_widgets.dart';
import 'package:xxread/services/library/download_task_controller.dart';

void main() {
  test(
    'detail loading ignores stale completions and disposed controllers',
    () async {
      final gateway = _DetailGateway();
      final controller = _controller(gateway: gateway);

      final first = controller.loadDetails();
      final second = controller.loadDetails();
      gateway.requests[1].complete(_book('book', title: 'Newest details'));
      await second;
      gateway.requests[0].complete(_book('book', title: 'Stale details'));
      await first;

      expect(controller.state.result.book.title, 'Newest details');

      final disposedLoad = controller.loadDetails();
      controller.dispose();
      gateway.requests[2].complete(_book('book', title: 'After dispose'));
      await disposedLoad;
      expect(controller.state.result.book.title, 'Newest details');
    },
  );

  test('online add guards duplicate submits and supports retry', () async {
    final shelf = _ShelfPort();
    final controller = _controller(shelf: shelf);

    shelf.findCompleter = Completer<Book?>();
    final first = controller.addOnline();
    final duplicate = controller.addOnline();
    expect(await duplicate, isFalse);
    shelf.findCompleter!.complete(null);
    expect(await first, isTrue);
    expect(shelf.addCalls, 1);
    expect(controller.state.step, SourcedBookDetailsStep.added);

    shelf.error = StateError('save failed');
    controller.showShelfOptions();
    expect(await controller.addOnline(), isFalse);
    expect(controller.state.step, SourcedBookDetailsStep.addFailed);
    expect('${controller.state.addError}', contains('save failed'));

    shelf.error = null;
    expect(await controller.retryAddOnline(), isTrue);
    expect(controller.state.step, SourcedBookDetailsStep.added);
    controller.dispose();
  });

  test('existing shelf books are not inserted again', () async {
    final shelf = _ShelfPort(existing: _localBook());
    final controller = _controller(shelf: shelf);

    expect(await controller.addOnline(), isTrue);
    expect(shelf.addCalls, 0);
    expect(controller.state.step, SourcedBookDetailsStep.alreadyAdded);
    controller.dispose();
  });

  test(
    'download state, cancellation, retry, and listener cleanup are owned',
    () {
      final downloads = _DownloadPort();
      final controller = _controller(downloads: downloads);

      controller.startDownload();
      expect(downloads.addListenerCalls, 1);
      expect(controller.state.step, SourcedBookDetailsStep.downloading);
      expect(controller.state.downloadTask?.state, DownloadTaskState.queued);

      downloads.update(DownloadTaskState.downloading, completed: 2, total: 5);
      expect(controller.state.downloadTask?.progress, 0.4);

      controller.cancelDownload();
      expect(downloads.cancelCalls, 1);
      expect(controller.state.downloadTask?.state, DownloadTaskState.cancelled);

      controller.startDownload();
      downloads.update(DownloadTaskState.failed, error: StateError('offline'));
      expect(controller.state.downloadTask?.state, DownloadTaskState.failed);
      expect('${controller.state.downloadTask?.error}', contains('offline'));

      controller.dispose();
      expect(downloads.removeListenerCalls, 1);
      downloads.update(DownloadTaskState.completed);
    },
  );
}

SourcedBookDetailsController _controller({
  _DetailGateway? gateway,
  _ShelfPort? shelf,
  _DownloadPort? downloads,
}) => SourcedBookDetailsController(
  initialResult: SourcedBook(source: _source(), book: _book('book')),
  gateway: gateway ?? _DetailGateway(),
  shelf: shelf ?? _ShelfPort(),
  downloads: downloads ?? _DownloadPort(),
);

class _DetailGateway extends BookSourceClient {
  final List<Completer<BookSourceBook>> requests = [];

  @override
  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) {
    final completer = Completer<BookSourceBook>();
    requests.add(completer);
    return completer.future;
  }
}

class _ShelfPort implements SourcedBookShelfPort {
  _ShelfPort({this.existing});

  Book? existing;
  Object? error;
  Completer<Book?>? findCompleter;
  int addCalls = 0;

  @override
  Future<Book?> findShelfBook({
    required String sourceId,
    required String sourceBookId,
  }) async => findCompleter?.future ?? existing;

  @override
  Future<Book> addOnline({
    required RegisteredBookSource source,
    required BookSourceBook book,
  }) async {
    addCalls += 1;
    if (error case final value?) throw value;
    return _localBook();
  }
}

class _DownloadPort extends ChangeNotifier implements SourcedBookDownloadPort {
  int addListenerCalls = 0;
  int removeListenerCalls = 0;
  int cancelCalls = 0;
  int _sequence = 0;
  BookDownloadTask? task;

  @override
  void addListener(VoidCallback listener) {
    addListenerCalls += 1;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    removeListenerCalls += 1;
    super.removeListener(listener);
  }

  @override
  String enqueue({
    required RegisteredBookSource source,
    required BookSourceBook book,
  }) {
    final id = 'task-${++_sequence}';
    task = BookDownloadTask(
      id: id,
      source: source,
      book: book,
      state: DownloadTaskState.queued,
    );
    return id;
  }

  @override
  BookDownloadTask? taskById(String id) => task?.id == id ? task : null;

  @override
  bool cancelTask(String id) {
    cancelCalls += 1;
    if (task?.id != id) return false;
    task = task!.copyWith(state: DownloadTaskState.cancelled);
    notifyListeners();
    return true;
  }

  void update(
    DownloadTaskState state, {
    int completed = 0,
    int total = 0,
    Object? error,
  }) {
    task = task!.copyWith(
      state: state,
      completed: completed,
      total: total,
      error: error,
    );
    notifyListeners();
  }
}

RegisteredBookSource _source() => RegisteredBookSource(
  id: 'source',
  name: 'Source',
  description: '',
  manifestUrl: Uri.parse('https://example.org/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);

BookSourceBook _book(String id, {String title = 'Book'}) => BookSourceBook(
  id: id,
  title: title,
  author: 'Author',
  description: 'Description',
  categories: const [],
);

Book _localBook() => Book(
  id: 1,
  title: 'Book',
  author: 'Author',
  filePath: '',
  format: 'source',
);
