import 'dart:async';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_change_store.dart';
import 'package:xxread/services/sync/sync_engine.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';

void main() {
  testWidgets('opening checks progress while a TXT upload is still running', (
    tester,
  ) async {
    final files = _Files();
    final transfer = Completer<BookContentReconcileResult>();
    files.transfer = transfer.future;
    final config = _Config();
    final store = _Store();
    final engine = _Engine(config, store);
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: engine,
      contentSyncService: files,
    );
    await controller.initialize();
    var notifiedWhileSyncingText = false;
    controller.addListener(() {
      notifiedWhileSyncingText |= controller.syncingText;
    });
    final fullSync = controller.syncNow();
    await tester.pump();
    expect(files.calls, 1);
    expect(controller.syncingText, isTrue);
    expect(notifiedWhileSyncingText, isTrue);
    await controller.checkProgressBeforeOpen();
    expect(engine.calls, 2);
    expect(controller.syncingText, isTrue);
    transfer.complete(_success);
    await fullSync;
    expect(controller.syncingText, isFalse);
    controller.dispose();
  });

  testWidgets(
    'reconciles readable files without blocking independent progress checks',
    (tester) async {
      const bookUid = 'book-uid';
      final store = _Store(
        records: <SyncRecord>[
          SyncRecord(
            dataset: 'books',
            recordId: 'book-record',
            entityKey: bookUid,
            payload: <String, dynamic>{
              'title': 'Large TXT',
              'author': 'Reader',
              'format': 'TXT',
              'file_available': true,
              'file_size': 1024,
              'blob_sha256':
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              'remote_path': 'books/$bookUid/large.txt',
              'file_name': 'large.txt',
            },
            hlc: '1-0-device',
            deleted: false,
            dirty: false,
          ),
        ],
      );
      final transfer = Completer<BookContentReconcileResult>();
      final files = _Files(
        states: const <BookContentState>[
          BookContentState(
            bookUid: bookUid,
            localBookId: 7,
            localPath: '/books/large.txt',
            remotePath: 'books/book-uid.txt',
            status: BookContentSyncStatus.synced,
          ),
        ],
      )..transfer = transfer.future;
      final config = _Config();
      final engine = _Engine(config, store);
      final controller = WebDavSyncController(
        localBooksLoader: () async => [],
        configStore: config,
        changeStore: store,
        engine: engine,
        contentSyncService: files,
      );
      await controller.initialize();

      final fullSync = controller.syncNow();
      await tester.pump();

      expect(files.events, <String>['reconcile']);
      expect(controller.syncingText, isTrue);
      await controller.checkProgressBeforeOpen();
      expect(engine.calls, 2);
      expect(controller.syncingText, isTrue);

      transfer.complete(_success);
      await fullSync;
      controller.dispose();
    },
  );

  testWidgets('metadata completion does not hide a failed file transfer', (
    tester,
  ) async {
    final config = _Config();
    final store = _Store();
    final files = _Files();
    files.transfer = Future.value(
      const BookContentReconcileResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        failed: 1,
      ),
    );
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: _Engine(config, store),
      contentSyncService: files,
    );
    await controller.initialize();
    await controller.syncNow();
    expect(controller.status, WebDavSyncStatus.partialFailure);
    expect(controller.lastFailure, isNotNull);
    expect(controller.lastFailure!.message, contains('One book file'));
    expect(controller.lastProgressSyncAt, isNotNull);
    controller.dispose();
  });

  testWidgets(
    'typed file failure survives metadata success until a successful file retry',
    (tester) async {
      const failure = WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'Conditional upload is not supported by this server.',
        statusCode: 405,
        requestMethod: 'MOVE',
        resourcePath: '/OpenReading/books/example.txt',
      );
      final config = _Config();
      final store = _Store();
      final files = _Files();
      var shouldFail = true;
      files.onTransfer = () async {
        if (shouldFail) throw failure;
        return _success;
      };
      final engine = _Engine(config, store);
      final controller = WebDavSyncController(
        localBooksLoader: () async => [],
        configStore: config,
        changeStore: store,
        engine: engine,
        contentSyncService: files,
      );
      await controller.initialize();

      await expectLater(controller.syncNow(), throwsA(same(failure)));
      expect(controller.lastFailure, same(failure));
      expect(controller.lastFailureIsFile, isTrue);
      expect(controller.lastError, WebDavSyncErrorCode.serverIncompatible);
      expect(controller.status, WebDavSyncStatus.partialFailure);

      await controller.checkProgressBeforeOpen();
      expect(engine.calls, 2);
      expect(controller.lastFailure, same(failure));
      expect(controller.status, WebDavSyncStatus.partialFailure);

      shouldFail = false;
      await controller.synchronizeTextFiles();
      expect(controller.lastFailure, isNull);
      expect(controller.lastFailureIsFile, isFalse);
      expect(controller.status, WebDavSyncStatus.success);
      controller.dispose();
    },
  );

  testWidgets('unknown file exception is retained as a typed failure', (
    tester,
  ) async {
    final config = _Config();
    final store = _Store();
    final files = _Files()
      ..onTransfer = () async => throw StateError('transport exploded');
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: _Engine(config, store),
      contentSyncService: files,
    );
    await controller.initialize();

    await expectLater(
      controller.syncNow(),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (failure) => failure.code,
          'code',
          WebDavSyncErrorCode.unknown,
        ),
      ),
    );
    expect(controller.lastFailure?.code, WebDavSyncErrorCode.unknown);
    expect(
      controller.lastFailure?.message,
      'Book-file sync could not be completed.',
    );
    expect(controller.status, WebDavSyncStatus.partialFailure);
    controller.dispose();
  });

  testWidgets('metadata failure remains independent of a successful file run', (
    tester,
  ) async {
    const failure = WebDavSyncFailure(
      WebDavSyncErrorCode.authentication,
      'The app password was rejected.',
      statusCode: 401,
    );
    final config = _Config();
    final store = _Store();
    final engine = _Engine(config, store)..error = failure;
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: engine,
      contentSyncService: _Files(),
    );
    await controller.initialize();

    await expectLater(controller.syncNow(), throwsA(same(failure)));
    expect(controller.lastFailure, same(failure));
    expect(controller.lastFailureIsFile, isFalse);
    expect(controller.status, WebDavSyncStatus.failed);

    await controller.synchronizeTextFiles();
    expect(controller.lastFailure, same(failure));
    expect(controller.status, WebDavSyncStatus.failed);
    controller.dispose();
  });

  testWidgets('persisted failed TXT state survives metadata-only success', (
    tester,
  ) async {
    final config = _Config();
    final store = _Store();
    final engine = _Engine(config, store);
    final files = _Files(
      states: const <BookContentState>[
        BookContentState(
          bookUid: 'failed-book',
          localBookId: 9,
          localPath: '/books/failed.txt',
          remotePath: 'books/failed/current.txt',
          status: BookContentSyncStatus.failed,
          error: 'PUT /OpenReading/v2/books/failed/current.txt: HTTP 503',
        ),
      ],
    );
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: engine,
      contentSyncService: files,
    );
    await controller.initialize();

    expect(controller.status, WebDavSyncStatus.partialFailure);
    expect(controller.lastFailureIsFile, isTrue);
    expect(controller.lastFailure?.message, contains('HTTP 503'));

    await controller.checkProgressBeforeOpen();
    expect(engine.calls, 1);
    expect(controller.status, WebDavSyncStatus.partialFailure);
    expect(controller.lastFailureIsFile, isTrue);
    controller.dispose();
  });

  testWidgets('metadata publish failure is not duplicated onto the file lane', (
    tester,
  ) async {
    const failure = WebDavSyncFailure(
      WebDavSyncErrorCode.serverError,
      'Metadata publish failed.',
      statusCode: 503,
    );
    final config = _Config();
    final store = _Store();
    final engine = _Engine(config, store)
      ..error = failure
      ..failOnCall = 2;
    final files = _Files()
      ..transfer = Future.value(
        const BookContentReconcileResult(
          uploaded: 1,
          downloaded: 0,
          conflicts: 0,
          failed: 0,
        ),
      );
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: engine,
      contentSyncService: files,
    );
    await controller.initialize();

    await expectLater(controller.syncNow(), throwsA(same(failure)));
    expect(engine.calls, 2);
    expect(controller.lastFailure, same(failure));
    expect(controller.lastFailureIsFile, isFalse);
    expect(controller.status, WebDavSyncStatus.failed);

    engine.error = null;
    await controller.checkProgressBeforeOpen();
    expect(controller.lastFailure, isNull);
    expect(controller.status, WebDavSyncStatus.success);
    controller.dispose();
  });

  testWidgets(
    'the newest active lane failure is exposed without losing either',
    (tester) async {
      const fileFailure = WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'The file precondition was rejected.',
      );
      const metadataFailure = WebDavSyncFailure(
        WebDavSyncErrorCode.authentication,
        'The metadata request was rejected.',
      );
      final config = _Config();
      final store = _Store();
      final engine = _Engine(config, store);
      final files = _Files()..onTransfer = () async => throw fileFailure;
      final controller = WebDavSyncController(
        localBooksLoader: () async => [],
        configStore: config,
        changeStore: store,
        engine: engine,
        contentSyncService: files,
      );
      await controller.initialize();

      await expectLater(controller.syncNow(), throwsA(same(fileFailure)));
      expect(controller.lastFailure, same(fileFailure));

      engine.error = metadataFailure;
      await expectLater(
        controller.checkProgressBeforeOpen(),
        throwsA(same(metadataFailure)),
      );
      expect(controller.lastFailure, same(metadataFailure));
      expect(controller.status, WebDavSyncStatus.failed);

      engine.error = null;
      await controller.checkProgressBeforeOpen();
      expect(controller.lastFailure, same(fileFailure));
      expect(controller.status, WebDavSyncStatus.partialFailure);
      controller.dispose();
    },
  );

  testWidgets(
    'disabling file scope stops new file work but keeps progress sync',
    (tester) async {
      final config = _Config();
      final store = _Store();
      final files = _Files();
      final engine = _Engine(config, store);
      final controller = WebDavSyncController(
        localBooksLoader: () async => [],
        configStore: config,
        changeStore: store,
        engine: engine,
        contentSyncService: files,
      );
      await controller.initialize();
      await controller.setScope(controller.scope.copyWith(bookFiles: false));
      await controller.syncNow();
      expect(files.calls, 0);
      expect(engine.calls, 1);
      controller.dispose();
    },
  );

  testWidgets('disabling file scope clears a retained file failure', (
    tester,
  ) async {
    const failure = WebDavSyncFailure(
      WebDavSyncErrorCode.timeout,
      'The book-file upload timed out.',
    );
    final config = _Config();
    final store = _Store();
    final files = _Files()..onTransfer = () async => throw failure;
    final controller = WebDavSyncController(
      localBooksLoader: () async => [],
      configStore: config,
      changeStore: store,
      engine: _Engine(config, store),
      contentSyncService: files,
    );
    await controller.initialize();
    await expectLater(controller.syncNow(), throwsA(same(failure)));
    expect(controller.lastFailure, same(failure));

    await controller.setScope(controller.scope.copyWith(bookFiles: false));
    expect(controller.lastFailure, isNull);
    expect(controller.status, WebDavSyncStatus.success);
    controller.dispose();
  });
}

const _success = BookContentReconcileResult(
  uploaded: 0,
  downloaded: 0,
  conflicts: 0,
  failed: 0,
);

class _Config extends SecureSyncConfigStore {
  WebDavSyncScope scope = const WebDavSyncScope(bookFiles: true);
  @override
  Future<WebDavSyncConfiguration?> readConfiguration() async =>
      const WebDavSyncConfiguration(
        serverUrl: 'https://example.test/dav',
        username: 'reader',
        autoSync: true,
      );
  @override
  Future<WebDavSyncScope> readScope() async => scope;
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

class _Store extends SyncChangeStore {
  _Store({this.records = const <SyncRecord>[]});

  final List<SyncRecord> records;
  final values = <String, String>{};
  @override
  Future<String?> getState(String key) async => values[key];
  @override
  Future<void> setState(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<int> pendingCount({Set<String>? datasets}) async => 0;
  @override
  Future<List<SyncRecord>> recordsForDataset(String dataset) async =>
      dataset == 'books' ? records : const <SyncRecord>[];
}

class _Engine extends SyncEngine {
  _Engine(SecureSyncConfigStore config, SyncChangeStore store)
    : super(
        storage: MemorySyncStorage(),
        scope: const WebDavSyncScope(),
        changeStore: store,
      );
  int calls = 0;
  Object? error;
  int? failOnCall;
  @override
  Future<WebDavSyncRunResult> run({
    void Function(WebDavSyncPhase phase)? onPhase,
  }) async {
    calls++;
    final currentError = error;
    if (currentError != null && (failOnCall == null || failOnCall == calls)) {
      throw currentError;
    }
    return WebDavSyncRunResult(
      uploaded: 0,
      downloaded: 0,
      skipped: 0,
      conflictsResolved: 0,
      completedAt: DateTime.now(),
    );
  }
}

class _Files extends BookContentSyncService {
  _Files({this.states = const <BookContentState>[]});

  final List<BookContentState> states;
  final List<String> events = <String>[];
  int calls = 0;
  Future<BookContentReconcileResult> transfer = Future.value(_success);
  Future<BookContentReconcileResult> Function()? onTransfer;
  @override
  Future<void> recoverLocalState() async {}
  @override
  Future<List<BookContentState>> listStates() async => states;
  @override
  Future<BookContentReconcileResult> reconcile({
    bool allowNetwork = true,
    String? bookUid,
    bool Function()? shouldContinue,
  }) {
    calls++;
    events.add('reconcile');
    return onTransfer?.call() ?? transfer;
  }
}
