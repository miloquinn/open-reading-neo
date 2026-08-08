import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_concurrency_limiter.dart';

void main() {
  group('SourceConcurrencyLimiter', () {
    test('does not wait when concurrentRate is unlimited or blank', () async {
      final limiter = SourceConcurrencyLimiter();
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        await limiter.acquire('source', '');
        await limiter.acquire('source', '0');
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test('allows N requests per window immediately, then throttles', () async {
      final limiter = SourceConcurrencyLimiter();
      const rate = '2/200';
      final stopwatch = Stopwatch()..start();
      await limiter.acquire('source', rate);
      await limiter.acquire('source', rate);
      // Third request in the same window must wait for it to roll over.
      await limiter.acquire('source', rate);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(180));
    });

    test('a bare interval means one request per interval', () async {
      final limiter = SourceConcurrencyLimiter();
      final stopwatch = Stopwatch()..start();
      await limiter.acquire('source', '150');
      await limiter.acquire('source', '150');
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(130));
    });

    test('different keys are throttled independently', () async {
      final limiter = SourceConcurrencyLimiter();
      const rate = '1/500';
      await limiter.acquire('a', rate);
      final stopwatch = Stopwatch()..start();
      await limiter.acquire('b', rate);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test('an invalid rate string is treated as unlimited', () async {
      final limiter = SourceConcurrencyLimiter();
      final stopwatch = Stopwatch()..start();
      await limiter.acquire('source', 'not-a-rate');
      await limiter.acquire('source', 'not-a-rate');
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });

    test('cancellation aborts a pending wait', () async {
      final limiter = SourceConcurrencyLimiter();
      const rate = '1/2000';
      await limiter.acquire('source', rate);
      final cancellation = BookDownloadCancellation();
      final future = limiter.acquire(
        'source',
        rate,
        cancellation: cancellation,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cancellation.cancel();
      await expectLater(
        future,
        throwsA(isA<BookDownloadCancelledException>()),
      );
    });

    test('reset clears throttling state', () async {
      final limiter = SourceConcurrencyLimiter();
      const rate = '1/2000';
      await limiter.acquire('source', rate);
      limiter.reset('source');
      final stopwatch = Stopwatch()..start();
      await limiter.acquire('source', rate);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });
  });
}
