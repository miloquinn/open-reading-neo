import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';
import 'package:xxread/pages/book_sources/widgets/sourced_book_details_controller.dart';
import 'package:xxread/services/library/download_task_controller.dart';

void main() {
  for (final description in ['', ' \n ', '<p>&nbsp;<br>\u200b</p>']) {
    test('empty detail metadata preserves the summary: $description', () async {
      final gateway = _DetailGateway();
      final downloads = _DownloadPort();
      final controller = _controller(gateway: gateway, downloads: downloads);
      addTearDown(controller.dispose);

      final loading = controller.loadDetails();
      expect(controller.state.result.book.description, 'Description');
      gateway.requests.single.complete(
        BookSourceBook(
          id: 'book',
          title: 'Detailed title',
          author: ' \n ',
          description: description,
          categories: const [],
          sourceVariables: const {'tocUrl': '/chapters'},
        ),
      );
      await loading;

      final book = controller.state.result.book;
      expect(book.title, 'Detailed title');
      expect(book.author, 'Author');
      expect(book.description, 'Description');
      expect(book.sourceVariables, {'tocUrl': '/chapters'});
      controller.startDownload();
      expect(downloads.task!.book.description, 'Description');
      controller.showDetails();
      expect(controller.beginOpeningReader()!.description, 'Description');
    });
  }

  test('nonempty details replace summary metadata', () async {
    final gateway = _DetailGateway();
    final controller = _controller(gateway: gateway);
    addTearDown(controller.dispose);
    final details = BookSourceBook(
      id: 'book',
      title: 'Detailed title',
      author: 'Detailed author',
      description: '<p>Full description</p>',
      categories: const ['Fantasy'],
      type: 2,
      coverUrl: Uri.parse('https://example.org/cover.jpg'),
      coverHeaders: const {'Referer': 'https://example.org/'},
      status: 'Completed',
      latestChapter: 'Final chapter',
      updatedAt: DateTime.utc(2026, 9, 5),
      sourceVariables: const {'tocUrl': '/chapters'},
    );

    final loading = controller.loadDetails();
    gateway.requests.single.complete(details);
    await loading;

    expect(controller.state.result.book.toJson(), details.toJson());
  });

  test(
    'details preserve summary fields omitted by the detail response',
    () async {
      final gateway = _DetailGateway();
      final summary = _book(
        'book',
        title: 'Summary title',
        coverUrl: Uri.parse('https://example.org/summary.jpg'),
        coverHeaders: const {'Referer': 'summary', 'Shared': 'summary'},
        categories: const ['Summary category'],
        status: 'Ongoing',
        latestChapter: 'Chapter 12',
        updatedAt: DateTime.utc(2026, 9, 1),
        sourceVariables: const {'catalog': '/summary', 'shared': 'summary'},
      );
      final controller = _controller(gateway: gateway, initialBook: summary);
      addTearDown(controller.dispose);

      final loading = controller.loadDetails();
      expect(controller.state.isLoadingDetails, isTrue);
      expect(controller.state.detailError, isNull);
      gateway.requests.single.complete(
        BookSourceBook(
          id: 'book',
          title: ' ',
          author: 'Detailed author',
          description: 'Detailed description',
          categories: const [],
          coverHeaders: const {'Shared': 'detail'},
          sourceVariables: const {'shared': 'detail', 'toc': '/detail'},
        ),
      );
      await loading;

      final book = controller.state.result.book;
      expect(controller.state.isLoadingDetails, isFalse);
      expect(book.title, 'Summary title');
      expect(book.coverUrl, summary.coverUrl);
      expect(book.coverHeaders, {'Referer': 'summary', 'Shared': 'detail'});
      expect(book.categories, ['Summary category']);
      expect(book.status, 'Ongoing');
      expect(book.latestChapter, 'Chapter 12');
      expect(book.updatedAt, DateTime.utc(2026, 9, 1));
      expect(book.sourceVariables, {
        'catalog': '/summary',
        'shared': 'detail',
        'toc': '/detail',
      });
    },
  );

  test('failed details expose an error and retry clears it', () async {
    final gateway = _DetailGateway();
    final controller = _controller(gateway: gateway);
    addTearDown(controller.dispose);
    final summary = controller.state.result;

    final loading = controller.loadDetails();
    expect(controller.state.isLoadingDetails, isTrue);
    gateway.requests.single.completeError(StateError('offline'));
    await loading;

    expect(controller.state.result, same(summary));
    expect(controller.state.isLoadingDetails, isFalse);
    expect('${controller.state.detailError}', contains('offline'));

    final retry = controller.retryLoadDetails();
    expect(controller.state.isLoadingDetails, isTrue);
    expect(controller.state.detailError, isNull);
    gateway.requests[1].complete(_book('book', title: 'Retried details'));
    await retry;
    expect(controller.state.result.book.title, 'Retried details');
    expect(controller.state.isLoadingDetails, isFalse);
    expect(controller.state.detailError, isNull);
  });

  test(
    'shelf status loads independently and failure stays nonblocking',
    () async {
      final shelf = _ShelfPort(existing: _localBook());
      final controller = _controller(shelf: shelf);
      addTearDown(controller.dispose);

      shelf.findCompleter = Completer<Book?>();
      final loading = controller.loadShelfStatus();
      expect(controller.state.checkingShelf, isTrue);
      expect(controller.state.hasShelfBook, isFalse);
      shelf.findCompleter!.complete(_localBook());
      await loading;
      expect(controller.state.checkingShelf, isFalse);
      expect(controller.state.hasShelfBook, isTrue);

      shelf.findCompleter = null;
      shelf.findError = StateError('database unavailable');
      await controller.loadShelfStatus();
      expect(controller.state.checkingShelf, isFalse);
      expect(controller.state.hasShelfBook, isTrue);
      expect(controller.state.step, SourcedBookDetailsStep.details);
    },
  );

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
    expect(controller.state.hasShelfBook, isTrue);

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

      downloads.update(DownloadTaskState.completed);
      expect(controller.state.hasShelfBook, isTrue);

      controller.dispose();
      expect(downloads.removeListenerCalls, 1);
      downloads.update(DownloadTaskState.failed);
    },
  );
}

SourcedBookDetailsController _controller({
  _DetailGateway? gateway,
  _ShelfPort? shelf,
  _DownloadPort? downloads,
  BookSourceBook? initialBook,
}) => SourcedBookDetailsController(
  initialResult: SourcedBook(
    source: _source(),
    book: initialBook ?? _book('book'),
  ),
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
  Object? findError;
  Completer<Book?>? findCompleter;
  int addCalls = 0;

  @override
  Future<Book?> findShelfBook({
    required String sourceId,
    required String sourceBookId,
  }) async {
    if (findError case final value?) throw value;
    return findCompleter?.future ?? existing;
  }

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

BookSourceBook _book(
  String id, {
  String title = 'Book',
  Uri? coverUrl,
  Map<String, String> coverHeaders = const {},
  List<String> categories = const [],
  String? status,
  String? latestChapter,
  DateTime? updatedAt,
  Map<String, String> sourceVariables = const {},
}) => BookSourceBook(
  id: id,
  title: title,
  author: 'Author',
  description: 'Description',
  coverUrl: coverUrl,
  coverHeaders: coverHeaders,
  categories: categories,
  status: status,
  latestChapter: latestChapter,
  updatedAt: updatedAt,
  sourceVariables: sourceVariables,
);

Book _localBook() => Book(
  id: 1,
  title: 'Book',
  author: 'Author',
  filePath: '',
  format: 'source',
);
