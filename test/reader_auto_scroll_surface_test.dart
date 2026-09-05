import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/widgets/reader_auto_scroll_surface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('continuous mode scrolls at viewport-relative speed and pauses', (
    tester,
  ) async {
    final scrollController = ScrollController();
    final controller = await _continuousController(seconds: 10);
    addTearDown(scrollController.dispose);
    addTearDown(controller.dispose);
    controller.start();

    await tester.pumpWidget(
      _scrollApp(
        controller: controller,
        scrollController: scrollController,
        onBoundary: () async => false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _pumpScrollSeconds(tester, 1);
    expect(scrollController.offset, closeTo(20, 0.5));

    controller.pause();
    await tester.pump();
    final pausedOffset = scrollController.offset;
    await tester.pump(const Duration(seconds: 3));
    expect(scrollController.offset, pausedOffset);

    controller.start();
    await tester.pump();
    await _pumpScrollSeconds(tester, 1);
    expect(scrollController.offset, closeTo(pausedOffset + 20, 0.5));
  });

  testWidgets('ready false holds position until content is ready', (
    tester,
  ) async {
    final scrollController = ScrollController();
    final controller = await _continuousController(seconds: 10);
    addTearDown(scrollController.dispose);
    addTearDown(controller.dispose);
    controller.start();

    await tester.pumpWidget(
      _scrollApp(
        controller: controller,
        scrollController: scrollController,
        ready: false,
        onBoundary: () async => false,
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(scrollController.offset, 0);

    await tester.pumpWidget(
      _scrollApp(
        controller: controller,
        scrollController: scrollController,
        ready: true,
        onBoundary: () async => false,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await _pumpScrollSeconds(tester, 1);
    expect(scrollController.offset, closeTo(20, 0.5));
  });

  testWidgets(
    'reaching the end invokes boundary and stops when no more exists',
    (tester) async {
      final scrollController = ScrollController();
      final controller = await _continuousController(seconds: 10);
      addTearDown(scrollController.dispose);
      addTearDown(controller.dispose);
      var boundaryCalls = 0;
      controller.start();

      await tester.pumpWidget(
        _scrollApp(
          controller: controller,
          scrollController: scrollController,
          itemCount: 2,
          onBoundary: () async {
            boundaryCalls++;
            return false;
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(boundaryCalls, 1);
      expect(controller.isActive, isFalse);
      expect(controller.isRunning, isFalse);
    },
  );
  testWidgets(
    'soft pause decelerates then freezes and hard pause cancels its tail',
    (tester) async {
      final scroll = ScrollController();
      final controller = await _continuousController(seconds: 10);
      addTearDown(scroll.dispose);
      addTearDown(controller.dispose);
      controller.start();
      await tester.pumpWidget(
        _scrollApp(
          controller: controller,
          scrollController: scroll,
          onBoundary: () async => false,
        ),
      );
      await _pumpScrollSeconds(tester, 1);
      final start = scroll.offset;
      controller.pause(smooth: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final first = scroll.offset;
      await tester.pump(const Duration(milliseconds: 80));
      final second = scroll.offset;
      expect(first, greaterThan(start));
      expect(second - first, lessThan(first - start));
      await tester.pump(const Duration(milliseconds: 200));
      final settled = scroll.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(scroll.offset, settled);
      controller.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      controller.pause(smooth: true);
      await tester.pump();
      controller.pause();
      final stopped = scroll.offset;
      await tester.pump(const Duration(milliseconds: 500));
      expect(scroll.offset, stopped);
    },
  );
  testWidgets(
    'muting the route cancels a soft pause instead of replaying it on return',
    (tester) async {
      final scroll = ScrollController();
      final controller = await _continuousController(seconds: 10);
      addTearDown(scroll.dispose);
      addTearDown(controller.dispose);
      Widget app(bool enabled) => _scrollApp(
        controller: controller,
        scrollController: scroll,
        onBoundary: () async => false,
        tickerEnabled: enabled,
      );
      controller.start();
      await tester.pumpWidget(app(true));
      await _pumpScrollSeconds(tester, 1);
      controller.pause(smooth: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpWidget(app(false));
      final stopped = scroll.offset;
      await tester.pump(const Duration(seconds: 1));
      expect(controller.smoothPauseRequested, isFalse);
      await tester.pumpWidget(app(true));
      await tester.pump(const Duration(milliseconds: 500));
      expect(scroll.offset, stopped);
    },
  );
}

Future<ReaderAutoPageTurnController> _continuousController({
  required double seconds,
}) async {
  final controller = ReaderAutoPageTurnController(onAdvance: () async => true);
  controller.setVertical(true);
  await controller.applySelection(
    ReaderAutoPageTurnSelection(
      mode: ReaderAutoPageTurnMode.continuous,
      seconds: seconds,
    ),
  );
  return controller;
}

Widget _scrollApp({
  required ReaderAutoPageTurnController controller,
  required ScrollController scrollController,
  required Future<bool> Function() onBoundary,
  bool ready = true,
  bool tickerEnabled = true,
  int itemCount = 20,
}) => MaterialApp(
  home: Scaffold(
    body: TickerMode(
      enabled: tickerEnabled,
      child: SizedBox(
        height: 200,
        child: ReaderAutoScrollSurface(
          key: const ValueKey('auto-scroll-surface'),
          controller: controller,
          ready: ready,
          onBoundary: onBoundary,
          child: ListView.builder(
            controller: scrollController,
            itemCount: itemCount,
            itemExtent: 50,
            itemBuilder: (context, index) => Text('Line $index'),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _pumpScrollSeconds(WidgetTester tester, int seconds) async {
  for (var frame = 0; frame < seconds * 10; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
