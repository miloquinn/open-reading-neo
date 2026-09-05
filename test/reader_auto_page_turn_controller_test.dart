import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test(
    'persists only the clamped interval and loads it for a new session',
    () async {
      final controller = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      await controller.setInterval(200);

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getInt(ReaderAutoPageTurnController.intervalPreferenceKey),
        ReaderAutoPageTurnController.maxIntervalSeconds,
      );
      expect(controller.isActive, isFalse);

      final restored = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );
      await restored.loadInterval();
      expect(restored.intervalSeconds, 120);
      expect(restored.isActive, isFalse);
      expect(restored.isRunning, isFalse);

      controller.dispose();
      restored.dispose();
    },
  );

  test('does not persist interval changes after disposal', () async {
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    controller.dispose();

    await controller.setInterval(30);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getInt(ReaderAutoPageTurnController.intervalPreferenceKey),
      isNull,
    );
  });

  test('defaults include the approved 10 second sweep duration', () {
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );

    expect(controller.modeFor(false), ReaderAutoPageTurnMode.timed);
    expect(controller.modeFor(true), ReaderAutoPageTurnMode.continuous);
    expect(controller.secondsFor(ReaderAutoPageTurnMode.timed), 15);
    expect(controller.secondsFor(ReaderAutoPageTurnMode.sweep), 10);
    expect(controller.secondsFor(ReaderAutoPageTurnMode.continuous), 30);
    expect(controller.secondsFor(ReaderAutoPageTurnMode.interval), 15);
    expect(controller.shortcutVisible, isTrue);
    controller.dispose();
  });

  test('persists shortcut visibility without changing reading state', () async {
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    controller.start();
    await controller.setShortcutVisible(false);

    expect(controller.shortcutVisible, isFalse);
    expect(controller.isActive, isTrue);
    expect(controller.isRunning, isTrue);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getBool(
        ReaderAutoPageTurnController.shortcutVisiblePreferenceKey,
      ),
      isFalse,
    );

    final restored = ReaderAutoPageTurnController(onAdvance: () async => true);
    await restored.loadInterval();
    expect(restored.shortcutVisible, isFalse);
    expect(restored.isActive, isFalse);
    expect(restored.isRunning, isFalse);
    controller.dispose();
    restored.dispose();
  });

  test(
    'a concurrent shortcut change wins over stale preference loading',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ReaderAutoPageTurnController.shortcutVisiblePreferenceKey: false,
      });
      final controller = ReaderAutoPageTurnController(
        onAdvance: () async => true,
      );

      final loading = controller.loadInterval();
      await controller.setShortcutVisible(true);
      await loading;

      expect(controller.shortcutVisible, isTrue);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getBool(
          ReaderAutoPageTurnController.shortcutVisiblePreferenceKey,
        ),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('persists independent choices and parameters for both groups', () async {
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    await controller.applySelection(
      const ReaderAutoPageTurnSelection(
        mode: ReaderAutoPageTurnMode.sweep,
        seconds: 20,
      ),
    );
    await controller.applySelection(
      const ReaderAutoPageTurnSelection(
        mode: ReaderAutoPageTurnMode.interval,
        seconds: 35,
      ),
    );

    final restored = ReaderAutoPageTurnController(onAdvance: () async => true);
    await restored.loadInterval();
    expect(restored.modeFor(false), ReaderAutoPageTurnMode.sweep);
    expect(restored.modeFor(true), ReaderAutoPageTurnMode.interval);
    expect(restored.secondsFor(ReaderAutoPageTurnMode.sweep), 20);
    expect(restored.secondsFor(ReaderAutoPageTurnMode.interval), 35);
    expect(restored.secondsFor(ReaderAutoPageTurnMode.timed), 15);
    expect(restored.secondsFor(ReaderAutoPageTurnMode.continuous), 30);

    controller.dispose();
    restored.dispose();
  });

  test('migrates the legacy interval into both interval modes', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ReaderAutoPageTurnController.intervalPreferenceKey: 25,
    });
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    await controller.loadInterval();

    expect(controller.secondsFor(ReaderAutoPageTurnMode.timed), 25);
    expect(controller.secondsFor(ReaderAutoPageTurnMode.interval), 25);
    expect(controller.secondsFor(ReaderAutoPageTurnMode.sweep), 10);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getDouble(
        ReaderAutoPageTurnController.timedSecondsPreferenceKey,
      ),
      25,
    );
    expect(
      preferences.getDouble(
        ReaderAutoPageTurnController.intervalSecondsPreferenceKey,
      ),
      25,
    );
    controller.dispose();
  });

  testWidgets('continuous and sweep modes do not schedule timer advances', (
    tester,
  ) async {
    var advances = 0;
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async {
        advances++;
        return true;
      },
    );
    await controller.applySelection(
      const ReaderAutoPageTurnSelection(
        mode: ReaderAutoPageTurnMode.sweep,
        seconds: 5,
      ),
    );
    controller.start();
    await tester.pump(const Duration(seconds: 20));
    expect(advances, 0);

    controller.stop();
    controller.setVertical(true);
    controller.start();
    await tester.pump(const Duration(seconds: 40));
    expect(advances, 0);
    controller.dispose();
  });

  testWidgets('pause and dispose cancel pending page turns', (tester) async {
    var advances = 0;
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async {
        advances++;
        return true;
      },
    );

    controller.start();
    controller.pause();
    await tester.pump(const Duration(seconds: 30));
    expect(advances, 0);
    expect(controller.isActive, isTrue);
    expect(controller.isRunning, isFalse);

    controller.start();
    controller.dispose();
    await tester.pump(const Duration(seconds: 30));
    expect(advances, 0);
  });

  testWidgets('end of content stops and callback errors pause safely', (
    tester,
  ) async {
    final ended = ReaderAutoPageTurnController(onAdvance: () async => false);
    ended.start();
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(ended.isActive, isFalse);
    expect(ended.isRunning, isFalse);

    final failed = ReaderAutoPageTurnController(
      onAdvance: () async => throw StateError('page unavailable'),
    );
    failed.start();
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(failed.isActive, isTrue);
    expect(failed.isRunning, isFalse);

    ended.dispose();
    failed.dispose();
  });

  testWidgets('waits for an async page turn before scheduling another', (
    tester,
  ) async {
    final firstAdvance = Completer<bool>();
    var advances = 0;
    final controller = ReaderAutoPageTurnController(
      onAdvance: () {
        advances++;
        return advances == 1 ? firstAdvance.future : Future<bool>.value(true);
      },
    );

    controller.start();
    await tester.pump(const Duration(seconds: 15));
    expect(advances, 1);
    await tester.pump(const Duration(seconds: 60));
    expect(advances, 1);

    firstAdvance.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(advances, 2);

    controller.stop();
    controller.dispose();
  });

  testWidgets('restart while an old page turn is pending never overlaps', (
    tester,
  ) async {
    final firstAdvance = Completer<bool>();
    var advances = 0;
    final controller = ReaderAutoPageTurnController(
      onAdvance: () {
        advances++;
        return advances == 1 ? firstAdvance.future : Future<bool>.value(true);
      },
    );

    controller.start();
    await tester.pump(const Duration(seconds: 15));
    controller.pause();
    controller.start();
    await tester.pump(const Duration(seconds: 45));
    expect(advances, 1);

    firstAdvance.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(advances, 2);

    controller.stop();
    controller.dispose();
  });

  testWidgets('interval changes wait for an in-flight page turn', (
    tester,
  ) async {
    final firstAdvance = Completer<bool>();
    var advances = 0;
    final controller = ReaderAutoPageTurnController(
      onAdvance: () {
        advances++;
        return advances == 1 ? firstAdvance.future : Future<bool>.value(true);
      },
    );

    controller.start();
    await tester.pump(const Duration(seconds: 15));
    await controller.setInterval(5);
    await tester.pump(const Duration(seconds: 20));
    expect(advances, 1);

    firstAdvance.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(advances, 2);

    controller.stop();
    controller.dispose();
  });
  testWidgets(
    'soft pause cancels scheduled turns and a hard pause cancels settling',
    (tester) async {
      var turns = 0;
      final controller = ReaderAutoPageTurnController(
        onAdvance: () async {
          turns++;
          return true;
        },
      );
      addTearDown(controller.dispose);
      controller.start();
      controller.pause(smooth: true);
      expect(controller.isRunning, isFalse);
      expect(controller.smoothPauseRequested, isTrue);
      await tester.pump(const Duration(seconds: 30));
      expect(turns, 0);
      var changes = 0;
      controller.addListener(() => changes++);
      controller.pause();
      expect(controller.smoothPauseRequested, isFalse);
      expect(changes, 1);
      controller.start();
      expect(controller.smoothPauseRequested, isFalse);
      controller.stop();
    },
  );
}
