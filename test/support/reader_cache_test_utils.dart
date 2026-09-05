import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/reader/native/native_reader_page.dart';
import 'package:xxread/services/books/native_reader_cache_store.dart';

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
