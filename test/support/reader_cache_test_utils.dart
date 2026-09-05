import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/services/books/pagination_cache_dao.dart';
import 'package:xxread/services/books/native_reader_cache_store.dart';

/// Fast, process-local pagination storage for widget tests that exercise UI
/// behavior rather than SQLite persistence.
class MemoryPaginationCacheDao extends PaginationCacheDao {
  final Map<String, Map<String, Uint8List>> _layouts = {};

  @override
  Future<Map<String, Uint8List>> loadForIdentity(
    String identity,
    String bookRevision,
  ) async => Map.of(_layouts['$identity:$bookRevision'] ?? {});

  @override
  Future<void> upsertForIdentity({
    required String identity,
    int? localBookId,
    required String bookRevision,
    required String layoutFingerprint,
    required int chapterIndex,
    required Uint8List payload,
    int? expectedEpoch,
    int? expectedRevisionEpoch,
  }) async {
    if (expectedEpoch != null && expectedEpoch != PaginationCacheDao.epoch) {
      return;
    }
    _layouts.putIfAbsent(
      '$identity:$bookRevision',
      () => {},
    )[layoutFingerprint] = Uint8List.fromList(
      payload,
    );
  }
}

/// Drain disk work while the widget test's fake zone can still make progress.
Future<void> drainReaderCache(WidgetTester tester) async {
  await tester.runAsync(() async {
    clearNativeReaderMemoryCaches();
    var drained = false;
    final completion = NativeReaderCacheStore.instance
        .flushPendingOperations()
        .then((_) => drained = true);
    for (var attempt = 0; attempt < 200; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
      if (drained && !NativeReaderCacheStore.instance.hasRetainedResources) {
        break;
      }
    }
    expect(
      drained,
      isTrue,
      reason: 'cache disposal must finish before leaving fakeAsync',
    );
    await completion;
    expect(
      NativeReaderCacheStore.instance.hasRetainedResources,
      isFalse,
      reason: 'closed readers must release parsed resource leases',
    );
  });
}
