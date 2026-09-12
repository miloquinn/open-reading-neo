import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
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

  test(
    'a failed upload does not block later books and remains visible',
    () async {
      final controller = _FakeWebDavSyncController(failFirst: true);
      final failed = _book(1, '失败书', '/tmp/fail.epub');
      final later = _book(2, '稍后上传', '/tmp/later.epub');
      final fresh = _book(3, '触发重试', '/tmp/fresh.epub');

      expect(controller.enqueueNewBookUploads([failed, later]), 2);
      controller.releaseFirstUpload();
      await controller.firstFailureHandled;
      await _waitUntil(() => controller.uploaded.length == 1);
      expect(controller.uploaded, [later]);
      expect(controller.status, WebDavSyncStatus.partialFailure);
      expect(controller.lastFailureIsFile, isTrue);
      expect(controller.lastErrorMessage, contains('失败书'));

      expect(controller.enqueueNewBookUploads([fresh]), 1);
      await _waitUntil(() => controller.uploaded.length == 3);

      expect(controller.attempted, [failed, later, failed, fresh]);
      expect(controller.uploaded, [later, failed, fresh]);
      expect(controller.lastFailure, isNull);
    },
  );

  test(
    'configure discovers and uploads books already in the library',
    () async {
      final config = _DiscoveryConfig();
      final existing = _book(7, '已经存在', '/library/existing.epub');
      var loads = 0;
      final controller = _DiscoveryController(
        config: config,
        booksLoader: () async {
          loads++;
          return [existing];
        },
      );

      await controller.configure(
        const WebDavSyncConfigDraft(
          serverUrl: 'https://dav.example.test',
          username: 'reader',
          password: 'app-password',
        ),
      );
      await _waitUntil(() => controller.uploaded.length == 1);

      expect(loads, 1);
      expect(controller.uploaded, [existing]);
      expect(controller.scope.bookFiles, isTrue);
      expect(controller.scope.notes, isTrue);
      expect(controller.scope.replaceRules, isTrue);
      controller.dispose();
    },
  );

  test('configure preserves a saved disabled book-file scope', () async {
    final config = _DiscoveryConfig(
      scope: const WebDavSyncScope(bookFiles: false),
    );
    var loads = 0;
    final controller = _DiscoveryController(
      config: config,
      booksLoader: () async {
        loads++;
        return [_book(8, '不要上传', '/library/disabled.epub')];
      },
    );

    await controller.configure(
      const WebDavSyncConfigDraft(
        serverUrl: 'https://dav.example.test',
        username: 'reader',
        password: 'app-password',
      ),
    );

    expect(controller.scope.bookFiles, isFalse);
    expect(loads, 0);
    expect(controller.uploaded, isEmpty);
    await controller.setScope(controller.scope.copyWith(bookFiles: true));
    await _waitUntil(() => controller.uploaded.length == 1);
    expect(loads, 1);
    expect(controller.uploaded.single.id, 8);
    await controller.setScope(controller.scope.copyWith(bookFiles: true));
    expect(loads, 1);
    controller.dispose();
  });

  test(
    'initialize discovers existing books without changing paused TXT state',
    () async {
      final existing = _book(9, '重启前已有', '/library/restart.txt');
      final active = _book(10, '正常备份', '/library/active.epub');
      final files = _DiscoveryFiles();
      final controller = _DiscoveryController(
        config: _DiscoveryConfig(
          configuration: const WebDavSyncConfiguration(
            serverUrl: 'https://dav.example.test',
            username: 'reader',
          ),
        ),
        files: files,
        booksLoader: () async => [existing, active],
      );

      await controller.initialize();
      await _waitUntil(() => controller.uploaded.length == 1);

      expect(controller.uploaded, [active]);
      expect(controller.textStates.single.status, BookContentSyncStatus.paused);
      expect(files.enableCalls, 0);
      controller.dispose();
    },
  );
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

class _DiscoveryController extends WebDavSyncController {
  _DiscoveryController({
    required _DiscoveryConfig config,
    required Future<List<Book>> Function() booksLoader,
    _DiscoveryFiles? files,
  }) : super(
         configStore: config,
         changeStore: _DiscoveryStore(),
         contentSyncService: files ?? _DiscoveryFiles(),
         localBooksLoader: booksLoader,
       );

  final List<Book> uploaded = <Book>[];

  @override
  void requestAutomaticSync({bool immediate = false}) {}

  @override
  Future<RemoteBookDescriptor> uploadBookFile(
    Book book, {
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    uploaded.add(book);
    return RemoteBookDescriptor(
      bookUid: 'book-${book.id}',
      title: book.title,
      author: book.author,
      format: book.format,
      fileAvailable: true,
    );
  }
}

class _DiscoveryConfig extends SecureSyncConfigStore {
  _DiscoveryConfig({
    this.configuration,
    this.scope = const WebDavSyncScope(
      notes: true,
      replaceRules: true,
      bookFiles: true,
    ),
  });

  WebDavSyncConfiguration? configuration;
  WebDavSyncScope scope;

  @override
  Future<WebDavSyncConfiguration?> readConfiguration() async => configuration;

  @override
  Future<WebDavSyncScope> readScope() async => scope;

  @override
  Future<void> save(WebDavSyncConfiguration next, String password) async {
    configuration = next;
  }

  @override
  Future<void> saveScope(WebDavSyncScope next) async {
    scope = next;
  }

  @override
  Future<bool> readAutoResume() async => true;

  @override
  Future<WebDavNewBookUploadPolicy> readNewBookUploadPolicy() async =>
      WebDavNewBookUploadPolicy.askEveryTime;
}

class _DiscoveryStore extends SyncChangeStore {
  @override
  Future<void> resetRemoteMirrorForNewSpace() async {}

  @override
  Future<int> pendingCount({Set<String>? datasets}) async => 0;

  @override
  Future<String?> getState(String key) async => null;

  @override
  Future<List<SyncRecord>> recordsForDataset(String dataset) async => const [];
}

class _DiscoveryFiles extends BookContentSyncService {
  int enableCalls = 0;

  @override
  Future<void> recoverLocalState() async {}

  @override
  Future<List<BookContentState>> listStates() async => const [
    BookContentState(
      bookUid: 'paused-book',
      localBookId: 9,
      localPath: '/library/restart.txt',
      remotePath: 'books/paused-book/current.txt',
      status: BookContentSyncStatus.paused,
      enabled: false,
    ),
  ];

  @override
  Future<void> setEnabled(String bookUid, bool enabled) async {
    enableCalls++;
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
