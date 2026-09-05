import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_auto_page_turn_controller.dart';
import 'package:xxread/widgets/reader_paper_page_leaf.dart';
import 'package:xxread/widgets/reader_shader_page_curl.dart';
import 'package:xxread/widgets/reader_sweep_page_turn.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('sweep pauses in place, resumes, and commits only once', (
    tester,
  ) async {
    var turns = 0;
    final controller = await _sweepController(seconds: 5);
    addTearDown(controller.dispose);
    controller.start();

    await tester.pumpWidget(
      _sweepApp(
        controller: controller,
        current: _snapshot('current'),
        next: _snapshot('next'),
        onTurnForward: () async => turns++,
      ),
    );
    await _pumpSeconds(tester, 4.6);
    final halfway = _revealedBounds(tester);
    expect(halfway.height, greaterThan(0));
    expect(halfway.height, lessThan(600));

    controller.pause();
    await tester.pump();
    await _pumpSeconds(tester, 3);
    expect(_revealedBounds(tester), halfway);
    expect(turns, 0);

    controller.start();
    await tester.pump();
    await _pumpSeconds(tester, 3);
    expect(turns, 1);
    await _pumpSeconds(tester, 8);
    expect(turns, 1);
  });

  testWidgets('sweep waits for a real next page and requests it once', (
    tester,
  ) async {
    var requests = 0;
    var turns = 0;
    final controller = await _sweepController(seconds: 5);
    addTearDown(controller.dispose);
    controller.start();
    final current = _snapshot('current');

    await tester.pumpWidget(
      _sweepApp(
        controller: controller,
        current: current,
        next: null,
        onNeedNextPage: () => requests++,
        onTurnForward: () async => turns++,
      ),
    );
    await tester.pump();
    await _pumpSeconds(tester, 8);
    expect(requests, 1);
    expect(turns, 0);
    expect(find.byKey(const ValueKey('reader-sweep-next-page')), findsNothing);
    // A failed preparation pauses; resuming must request the target again.
    controller.pause();
    controller.start();
    await tester.pump();
    expect(requests, 2);

    await tester.pumpWidget(
      _sweepApp(
        controller: controller,
        current: current,
        next: _snapshot('loaded-next'),
        onNeedNextPage: () => requests++,
        onTurnForward: () async => turns++,
      ),
    );
    await _pumpSeconds(tester, 7.2);
    expect(turns, 1);
    expect(requests, 2);
  });

  testWidgets('two-page sweep reveals the left then right page sequentially', (
    tester,
  ) async {
    final controller = await _sweepController(seconds: 5);
    addTearDown(controller.dispose);
    controller.start();

    await tester.pumpWidget(
      _sweepApp(
        controller: controller,
        current: _snapshot('current-spread'),
        next: _snapshot('next-spread'),
        twoPage: true,
        onTurnForward: () async {},
      ),
    );
    await _pumpSeconds(tester, 6.6);
    final leftOnly = _revealedBounds(tester);
    expect(leftOnly.right, lessThan(200));
    expect(leftOnly.height, greaterThan(500));

    await _pumpSeconds(tester, 1);
    final rightStarted = _revealedBounds(tester);
    expect(rightStarted.right, greaterThan(212));
    expect(rightStarted.left, 0);
  });

  testWidgets(
    'soft pause slows sweep without committing and resumes from its resting line',
    (tester) async {
      var turns = 0;
      final controller = await _sweepController(seconds: 5);
      addTearDown(controller.dispose);
      controller.start();
      await tester.pumpWidget(
        _sweepApp(
          controller: controller,
          current: _snapshot('current'),
          next: _snapshot('next'),
          onTurnForward: () async => turns++,
        ),
      );
      await _pumpSeconds(tester, 4);
      final before = _revealedBounds(tester).height;
      controller.pause(smooth: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final first = _revealedBounds(tester).height;
      await tester.pump(const Duration(milliseconds: 80));
      final second = _revealedBounds(tester).height;
      expect(first, greaterThan(before));
      expect(second - first, lessThan(first - before));
      await tester.pump(const Duration(milliseconds: 200));
      final settled = _revealedBounds(tester);
      await _pumpSeconds(tester, 10);
      expect(_revealedBounds(tester), settled);
      expect(turns, 0);
      controller.start();
      await tester.pump();
      await _pumpSeconds(tester, 5);
      expect(turns, 1);
    },
  );

  test('controller retains the approved ten-second sweep default', () {
    final controller = ReaderAutoPageTurnController(
      onAdvance: () async => true,
    );
    expect(controller.secondsFor(ReaderAutoPageTurnMode.sweep), 10);
    controller.dispose();
  });
}

Future<ReaderAutoPageTurnController> _sweepController({
  required double seconds,
}) async {
  final controller = ReaderAutoPageTurnController(onAdvance: () async => true);
  await controller.applySelection(
    ReaderAutoPageTurnSelection(
      mode: ReaderAutoPageTurnMode.sweep,
      seconds: seconds,
    ),
  );
  return controller;
}

Widget _sweepApp({
  required ReaderAutoPageTurnController controller,
  required ReaderPageSnapshot current,
  required ReaderPageSnapshot? next,
  required Future<void> Function() onTurnForward,
  bool twoPage = false,
  VoidCallback? onNeedNextPage,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 400,
      height: 600,
      child: ReaderSweepPageTurn(
        controller: controller,
        currentPage: current,
        nextPage: next,
        hasNext: true,
        twoPage: twoPage,
        onNeedNextPage: onNeedNextPage,
        onTurnForward: onTurnForward,
      ),
    ),
  ),
);

ReaderPageSnapshot _snapshot(String id) => ReaderPageSnapshot(
  key: ReaderPageSnapshotKey(
    pageIdentity: id,
    layoutFingerprint: 'layout',
    themeId: 'day',
  ),
  contentRevision: 0,
  child: ColoredBox(color: id.hashCode.isEven ? Colors.blue : Colors.amber),
);

Rect _revealedBounds(WidgetTester tester) {
  final clip = tester.widget<ClipPath>(
    find.byKey(const ValueKey('reader-sweep-next-page')),
  );
  final size = tester.getSize(
    find.byKey(const ValueKey('reader-sweep-next-page')),
  );
  return clip.clipper!.getClip(size).getBounds();
}

Future<void> _pumpSeconds(WidgetTester tester, double seconds) async {
  final steps = (seconds * 10).round();
  for (var index = 0; index < steps; index++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
