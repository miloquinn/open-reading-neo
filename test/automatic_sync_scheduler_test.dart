import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/automatic_sync_scheduler.dart';

void main() {
  for (final interval in [
    const Duration(minutes: 15),
    const Duration(hours: 1),
    const Duration(days: 1),
  ]) {
    testWidgets(
      'interval $interval gates events, immediate requests and foreground changes',
      (tester) async {
        var now = DateTime.utc(2026, 9, 15);
        DateTime? last = now;
        var runs = 0;
        final scheduler = AutomaticSyncScheduler(
          run: () async {
            runs++;
            last = now;
          },
          enabled: () => true,
          interval: () => interval,
          lastSuccess: () => last,
          now: () => now,
        );
        scheduler.start();
        scheduler.request(immediate: true);
        scheduler.setForeground(false);
        scheduler.setForeground(true);
        await scheduler.runIfDue();
        await tester.pump(const Duration(seconds: 45));
        expect(runs, 0);
        now = now.add(interval).subtract(const Duration(seconds: 1));
        await scheduler.runIfDue();
        expect(runs, 0);
        now = now.add(const Duration(seconds: 1));
        await scheduler.runIfDue();
        expect(runs, 1);
        scheduler.request(immediate: true);
        expect(runs, 1);
        scheduler.dispose();
        // Restarting the scheduler must still use the persisted completion time.
        final restarted = AutomaticSyncScheduler(
          run: () async {
            runs++;
            last = now;
          },
          enabled: () => true,
          interval: () => interval,
          lastSuccess: () => last,
          now: () => now,
        );
        await restarted.runIfDue();
        expect(runs, 1);
        now = now.add(interval * 2);
        await restarted.runIfDue();
        expect(runs, 2);
        restarted.dispose();
      },
    );
  }

  testWidgets(
    'daily failure retries without advancing its successful schedule',
    (tester) async {
      var now = DateTime.utc(2026, 9, 15);
      DateTime? last;
      var runs = 0;
      final scheduler = AutomaticSyncScheduler(
        run: () async {
          if (++runs == 1) throw StateError('offline');
          last = now;
        },
        enabled: () => true,
        interval: () => const Duration(days: 1),
        lastSuccess: () => last,
        now: () => now,
      );
      await scheduler.runIfDue();
      expect(last, isNull);
      await scheduler.runIfDue();
      expect(runs, 1);
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(runs, 2);
      expect(last, now);
      scheduler.dispose();
    },
  );

  testWidgets('continuous reading cannot postpone the first upload', (
    tester,
  ) async {
    var runs = 0;
    final scheduler = AutomaticSyncScheduler(
      run: () async {
        runs++;
      },
      enabled: () => true,
    );
    addTearDown(scheduler.dispose);
    for (var i = 0; i < 5; i++) {
      scheduler.request();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(runs, 1);
  });

  testWidgets('edits during a running upload schedule another attempt', (
    tester,
  ) async {
    var runs = 0;
    final first = Completer<void>();
    final scheduler = AutomaticSyncScheduler(
      run: () async {
        if (++runs == 1) await first.future;
      },
      enabled: () => true,
    );
    addTearDown(scheduler.dispose);
    scheduler.request(immediate: true);
    scheduler.request();
    scheduler.request();
    expect(runs, 1);
    first.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(runs, 2);
  });

  testWidgets('failed attempts retry and disabling cancels network work', (
    tester,
  ) async {
    var runs = 0;
    var enabled = true;
    final scheduler = AutomaticSyncScheduler(
      run: () async {
        runs++;
        throw StateError('offline');
      },
      enabled: () => enabled,
    );
    addTearDown(scheduler.dispose);
    scheduler.request(immediate: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(runs, 2);
    enabled = false;
    scheduler.cancelPending();
    await tester.pump(const Duration(minutes: 1));
    expect(runs, 2);
  });

  testWidgets('periodic polling cannot bypass retry backoff', (tester) async {
    var runs = 0;
    final scheduler = AutomaticSyncScheduler(
      run: () async {
        runs++;
        throw StateError('offline');
      },
      enabled: () => true,
      pollInterval: const Duration(seconds: 1),
    );
    addTearDown(scheduler.dispose);
    scheduler.start();
    scheduler.request(immediate: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(runs, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(runs, 2);
    scheduler.dispose();
  });

  testWidgets('leaving foreground flushes once and stops polling', (
    tester,
  ) async {
    var runs = 0;
    final scheduler = AutomaticSyncScheduler(
      run: () async {
        runs++;
      },
      enabled: () => true,
    );
    addTearDown(scheduler.dispose);
    scheduler.start();
    scheduler.setForeground(false);
    await tester.pump(const Duration(minutes: 2));
    expect(runs, 1);
    scheduler.setForeground(true);
    await tester.pump();
    expect(runs, 2);
    scheduler.dispose();
  });
}
