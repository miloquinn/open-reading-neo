import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/automatic_sync_scheduler.dart';

void main() {
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
