import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/mutable_txt_sync_service.dart';
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
    final transfer = Completer<MutableTxtReconcileResult>();
    files.transfer = transfer.future;
    final config = _Config();
    final store = _Store();
    final engine = _Engine(config, store);
    final controller = WebDavSyncController(
      configStore: config,
      changeStore: store,
      engine: engine,
      mutableTxtService: files,
    );
    await controller.initialize();
    final fullSync = controller.syncNow();
    await tester.pump();
    expect(files.calls, 1);
    expect(controller.syncingText, isTrue);
    await controller.checkProgressBeforeOpen();
    expect(engine.calls, 2);
    expect(controller.syncingText, isTrue);
    transfer.complete(_success);
    await fullSync;
    expect(controller.syncingText, isFalse);
    controller.dispose();
  });

  testWidgets(
    'follows a bound v3 TXT descriptor before reconcile without blocking progress',
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
              'remote_path': 'v3:books/$bookUid/manifest.json',
              'file_name': 'large.txt',
            },
            hlc: '1-0-device',
            deleted: false,
            dirty: false,
          ),
        ],
      );
      final transfer = Completer<MutableTxtReconcileResult>();
      final files = _Files(
        states: const <MutableTxtBookState>[
          MutableTxtBookState(
            bookUid: bookUid,
            localBookId: 7,
            localPath: '/books/large.txt',
            remotePath: 'v2:books/book-uid.txt',
            status: MutableTxtSyncStatus.synced,
          ),
        ],
      )..transfer = transfer.future;
      final config = _Config();
      final engine = _Engine(config, store);
      final controller = WebDavSyncController(
        configStore: config,
        changeStore: store,
        engine: engine,
        mutableTxtService: files,
      );
      await controller.initialize();

      final fullSync = controller.syncNow();
      await tester.pump();

      expect(files.events, <String>['follow:$bookUid', 'reconcile']);
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
      const MutableTxtReconcileResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        failed: 1,
      ),
    );
    final controller = WebDavSyncController(
      configStore: config,
      changeStore: store,
      engine: _Engine(config, store),
      mutableTxtService: files,
    );
    await controller.initialize();
    await controller.syncNow();
    expect(controller.status, WebDavSyncStatus.partialFailure);
    expect(controller.lastProgressSyncAt, isNotNull);
    controller.dispose();
  });

  testWidgets(
    'disabling file scope stops new file work but keeps progress sync',
    (tester) async {
      final config = _Config();
      final store = _Store();
      final files = _Files();
      final engine = _Engine(config, store);
      final controller = WebDavSyncController(
        configStore: config,
        changeStore: store,
        engine: engine,
        mutableTxtService: files,
      );
      await controller.initialize();
      await controller.setScope(controller.scope.copyWith(bookFiles: false));
      await controller.syncNow();
      expect(files.calls, 0);
      expect(engine.calls, 1);
      controller.dispose();
    },
  );
}

const _success = MutableTxtReconcileResult(
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
    : super(configStore: config, changeStore: store);
  int calls = 0;
  @override
  Future<WebDavSyncRunResult> run({
    void Function(WebDavSyncPhase phase)? onPhase,
  }) async {
    calls++;
    return WebDavSyncRunResult(
      uploaded: 0,
      downloaded: 0,
      skipped: 0,
      conflictsResolved: 0,
      completedAt: DateTime.now(),
    );
  }
}

class _Files extends MutableTxtSyncService {
  _Files({this.states = const <MutableTxtBookState>[]});

  final List<MutableTxtBookState> states;
  final List<String> events = <String>[];
  int calls = 0;
  Future<MutableTxtReconcileResult> transfer = Future.value(_success);
  @override
  Future<void> recoverLocalState() async {}
  @override
  Future<List<MutableTxtBookState>> listStates() async => states;
  @override
  Future<bool> followRemoteStorage({
    required String bookUid,
    required String remotePath,
    required String contentHash,
    required int fileSize,
  }) async {
    events.add('follow:$bookUid');
    return true;
  }

  @override
  Future<MutableTxtReconcileResult> reconcile({
    bool allowNetwork = true,
    String? bookUid,
    bool Function()? shouldContinue,
  }) {
    calls++;
    events.add('reconcile');
    return transfer;
  }
}
