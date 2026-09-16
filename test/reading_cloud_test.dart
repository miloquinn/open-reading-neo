import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/data/migration/reading_cloud_schema_migration.dart';
import 'package:xxread/services/account/account_api_client.dart';
import 'package:xxread/services/account/account_models.dart';
import 'package:xxread/services/account/account_summary_cache.dart';
import 'package:xxread/services/account/member_account_controller.dart';
import 'package:xxread/services/reading/reading_account_scope.dart';
import 'package:xxread/services/reading/reading_cloud_controller.dart';
import 'package:xxread/services/reading/reading_cloud_recorder.dart';
import 'package:xxread/services/reading/reading_cloud_store.dart';

const a = '00000000-0000-4000-8000-000000000001';
const b = '00000000-0000-4000-8000-000000000002';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late ReadingCloudStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''CREATE TABLE reading_sessions (
      id INTEGER PRIMARY KEY, date TEXT, startTimeMs INTEGER, endTimeMs INTEGER,
      durationInSeconds INTEGER)''');
    await db.execute(
      'CREATE TABLE reading_stats (date TEXT, durationInSeconds INTEGER)',
    );
    store = ReadingCloudStore(database: () async => db);
  });
  tearDown(() => db.close());

  test(
    'offline upgrade adopts last account but explicit logout never resurrects it',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        MemberAccountSummaryCache.storageKey,
        jsonEncode({
          'user_id': a,
          'username': 'reader',
          'effective_name': 'Reader',
          'premium': false,
        }),
      );
      final scope = ReadingAccountScope();
      await scope.restore();
      expect(scope.owner, a);
      await scope.setOwner(null);
      final restored = ReadingAccountScope();
      await restored.restore();
      expect(restored.owner, isNull);
      scope.dispose();
      restored.dispose();
    },
  );

  test(
    'nine historical hours are claimed once and never enter the ranking',
    () async {
      final start = DateTime.utc(2026, 9, 15, 0).millisecondsSinceEpoch;
      await db.insert('reading_sessions', {
        'date': '2026-09-15',
        'startTimeMs': start,
        'endTimeMs': start + 32400000,
        'durationInSeconds': 32400,
      });
      await db.insert('reading_stats', {
        'date': '2026-09-15',
        'durationInSeconds': 32400,
      });
      await ReadingCloudSchemaMigration.migrate(db);
      expect(
        await store.guestSeconds(),
        32400,
      ); // no daily + sessions duplication
      await store.claimGuest(a);
      await store.claimGuest(b);
      expect(await store.guestSeconds(), 0);
      expect(await store.pending(b), isEmpty);
      final records = await store.pending(a);
      expect(records.single['kind'], 'legacy_session');
      // A repeated migration retains IDs and ownership (backup/retry safety).
      await ReadingCloudSchemaMigration.migrate(db);
      expect(await store.guestSeconds(), 0);
      expect(
        (await store.pending(a)).single['event_id'],
        records.single['event_id'],
      );
    },
  );

  test(
    'daily-only legacy history survives without inventing a reading session',
    () async {
      await db.insert('reading_stats', {
        'date': '2026-09-15',
        'durationInSeconds': 32400,
      });
      await ReadingCloudSchemaMigration.migrate(db);
      await store.claimGuest(a);
      final event = (await store.pending(a)).single;
      expect(event['kind'], 'legacy_daily');
      expect(event['seconds'], 32400);
      expect((event['end_ms'] as int) - (event['start_ms'] as int), 86400000);
      expect(store.payload(event).containsKey('owner_id'), isFalse);
    },
  );

  test(
    'acknowledgements cannot mark another account rows as synchronized',
    () async {
      await ReadingCloudSchemaMigration.migrate(db);
      await store.record(
        eventId: 'a-record',
        owner: a,
        startMs: 1789430400000,
        seconds: 60,
      );
      await store.record(
        eventId: 'b-record',
        owner: b,
        startMs: 1789430400000,
        seconds: 60,
      );
      await store.acknowledge(a, {
        'accepted': ['a-record', 'b-record'],
        'rejected': [],
      });
      expect(await store.pending(a), isEmpty);
      expect((await store.pending(b)).single['event_id'], 'b-record');
      await store.acknowledge(b, {
        'accepted': [],
        'rejected': [
          {'event_id': 'b-record', 'reason': 'conflict'},
        ],
      });
      expect((await store.counts(b)).rejected, 1);
      expect(await store.guestSeconds(), 0);
    },
  );

  test(
    'recording splits on account changes and offline owner survives restart',
    () async {
      await ReadingCloudSchemaMigration.migrate(db);
      final scope = ReadingAccountScope();
      var elapsed = 10;
      final recorder = ReadingCloudRecorder(
        store: store,
        scope: scope,
        elapsedSeconds: () => elapsed,
        now: () => DateTime.utc(2026, 9, 16),
      );
      recorder.start();
      await scope.setOwner(a);
      elapsed = 20;
      await scope.setOwner(b);
      elapsed = 30;
      await recorder.stop();
      expect(await store.guestSeconds(), 10);
      expect((await store.pending(a)).single['seconds'], 20);
      expect((await store.pending(b)).single['seconds'], 30);
      final restored = ReadingAccountScope();
      await restored.restore();
      expect(restored.owner, b);
      await restored.setOwner(null);
      final signedOut = ReadingAccountScope();
      await signedOut.restore();
      expect(signedOut.owner, isNull);
      scope.dispose();
      restored.dispose();
      signedOut.dispose();
    },
  );

  test(
    'failed upload retains ownership and later retry uses the same event ID',
    () async {
      await ReadingCloudSchemaMigration.migrate(db);
      await store.record(
        eventId: 'offline',
        owner: null,
        startMs: 1789430400000,
        seconds: 60,
      );
      final scope = ReadingAccountScope();
      await scope.setOwner(a);
      final api = TestReadingApi()..failUploads = true;
      final account = TestReadingAccount(api, a);
      final cloud = ReadingCloudController(
        account: account,
        store: store,
        scope: scope,
        automatic: false,
      );
      await cloud.claimGuest();
      expect(cloud.error, isNotNull);
      expect((await store.pending(a)).single['event_id'], 'offline');
      account.currentId = b;
      await scope.setOwner(b);
      await cloud.initialize();
      await cloud.claimGuest();
      expect(await store.pending(b), isEmpty);
      expect((await store.pending(a)).single['event_id'], 'offline');
      api.failUploads = false;
      account.currentId = a;
      await scope.setOwner(a);
      await cloud.initialize();
      expect(await store.pending(a), isEmpty);
      expect(api.uploadedIds, ['offline', 'offline']);
      cloud.dispose();
      account.dispose();
      scope.dispose();
    },
  );

  test(
    'late account A responses do not overwrite account B UI or cache',
    () async {
      await ReadingCloudSchemaMigration.migrate(db);
      final scope = ReadingAccountScope();
      await scope.setOwner(a);
      final api = TestReadingApi()..holdA = Completer<void>();
      final account = TestReadingAccount(api, a);
      final cloud = ReadingCloudController(
        account: account,
        store: store,
        scope: scope,
        automatic: false,
      );
      final old = cloud.synchronize();
      await api.aRequested.future;
      account.currentId = b;
      await scope.setOwner(b);
      expect(cloud.summary, isNull);
      await cloud.initialize();
      expect(cloud.summary?['user_id'], b);
      api.holdA!.complete();
      await old;
      expect(cloud.owner, b);
      expect(cloud.summary?['user_id'], b);
      expect((await store.cached(b))?['summary']['user_id'], b);
      cloud.dispose();
      account.dispose();
      scope.dispose();
    },
  );

  test('mismatched server response is not displayed or acknowledged', () async {
    await ReadingCloudSchemaMigration.migrate(db);
    final scope = ReadingAccountScope();
    await scope.setOwner(a);
    await store.record(
      eventId: 'pending',
      owner: a,
      startMs: 1789430400000,
      seconds: 60,
    );
    final api = TestReadingApi()..wrongOwner = true;
    final account = TestReadingAccount(api, a);
    final cloud = ReadingCloudController(
      account: account,
      store: store,
      scope: scope,
      automatic: false,
    );
    await cloud.synchronize();
    expect(cloud.error, contains('账号不匹配'));
    expect(cloud.summary, isNull);
    expect(await store.pending(a), hasLength(1));
    cloud.dispose();
    account.dispose();
    scope.dispose();
  });

  test(
    'successful privacy change persists even when board refresh fails',
    () async {
      await ReadingCloudSchemaMigration.migrate(db);
      final scope = ReadingAccountScope();
      await scope.setOwner(a);
      final api = TestReadingApi()..serverPublic = true;
      final account = TestReadingAccount(api, a);
      final cloud = ReadingCloudController(
        account: account,
        store: store,
        scope: scope,
        automatic: false,
      );
      await cloud.initialize();
      expect(cloud.summary?['public'], true);
      api.failReadsAfterPreference = true;
      await cloud.setPublic(false);
      expect(cloud.summary?['public'], false);
      expect((await store.cached(a))?['summary']['public'], false);
      expect(cloud.week?['me'], isNull);
      cloud.dispose();
      account.dispose();
      scope.dispose();
    },
  );
}

class TestReadingApi extends MemberAccountApiClient {
  bool failUploads = false;
  bool wrongOwner = false;
  bool serverPublic = false;
  bool failReadsAfterPreference = false;
  bool failReads = false;
  Completer<void>? holdA;
  final aRequested = Completer<void>();
  final uploadedIds = <String>[];

  @override
  Future<Map<String, dynamic>> readingRequest(
    String method,
    String endpoint,
    String owner, {
    Map<String, Object?>? data,
    String? period,
  }) async {
    if (endpoint == 'preferences') {
      serverPublic = data!['public'] as bool;
      failReads = failReadsAfterPreference;
      return {'user_id': owner, 'public': serverPublic};
    }
    if (method == 'GET' && failReads) {
      throw const MemberAccountException('offline');
    }
    if (endpoint == 'events') {
      final ids = (data!['events'] as List)
          .map((row) => row['event_id'] as String)
          .toList();
      uploadedIds.addAll(ids);
      if (failUploads) throw const MemberAccountException('offline');
      return {
        'user_id': wrongOwner ? b : owner,
        'accepted': ids,
        'rejected': [],
      };
    }
    if (owner == a && holdA != null) {
      if (!aRequested.isCompleted) aRequested.complete();
      await holdA!.future;
    }
    if (endpoint == 'summary') {
      return {
        'user_id': owner,
        'public': serverPublic,
        'total_seconds': 3600,
        'week_seconds': 3600,
        'month_seconds': 3600,
        'days': [],
      };
    }
    return {'user_id': owner, 'items': [], 'me': null};
  }
}

class TestReadingAccount extends MemberAccountController {
  TestReadingAccount(this.api, this.currentId);
  final TestReadingApi api;
  String? currentId;
  @override
  MemberAccountApiClient get readingApi => api;
  @override
  Future<void> synchronize() async {}
  @override
  MemberUser? get user => currentId == null
      ? null
      : MemberUser(
          id: currentId!,
          email: 'reader@example.test',
          emailVerified: true,
          username: 'reader',
          effectiveName: 'Reader',
          authMethods: const [],
          createdAt: DateTime.utc(2026),
        );
}
