import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/book_sources/widgets/book_source_sliver_transition.dart';

void main() {
  Widget frame(
    String identity, {
    bool reduceMotion = false,
    VoidCallback? tap,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: CustomScrollView(
            slivers: [
              BookSourceSliverTransition(
                identity: identity,
                slivers: [
                  SliverToBoxAdapter(
                    child: TextButton(onPressed: tap, child: Text(identity)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets(
    'fades old content out before replacing it with the latest tree',
    (tester) async {
      var oldTaps = 0;
      await tester.pumpWidget(frame('A', tap: () => oldTaps++));
      await tester.pumpWidget(frame('B'));
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsNothing);
      await tester.tap(find.text('A'), warnIfMissed: false);
      expect(oldTaps, 0);
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester
            .widget<SliverFadeTransition>(find.byType(SliverFadeTransition))
            .opacity
            .value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpWidget(frame('C'));
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.text('A'), findsNothing);
      expect(find.text('B'), findsNothing);
      expect(find.text('C'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        tester
            .widget<SliverFadeTransition>(find.byType(SliverFadeTransition))
            .opacity
            .value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    },
  );

  testWidgets('a rapid return to the shown category cancels replacement', (
    tester,
  ) async {
    await tester.pumpWidget(frame('A'));
    await tester.pumpWidget(frame('B'));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(frame('A'));
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsNothing);
    expect(
      tester
          .widget<SliverIgnorePointer>(find.byType(SliverIgnorePointer))
          .ignoring,
      isFalse,
    );
  });

  testWidgets('outgoing content cannot be activated by keyboard', (
    tester,
  ) async {
    var oldTaps = 0;
    await tester.pumpWidget(frame('A', tap: () => oldTaps++));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(oldTaps, 1);
    await tester.pumpWidget(frame('B'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(oldTaps, 1);
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('reduced motion adopts the newest state even during a fade', (
    tester,
  ) async {
    await tester.pumpWidget(frame('A'));
    await tester.pumpWidget(frame('B'));
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pumpWidget(frame('C', reduceMotion: true));
    expect(find.text('A'), findsNothing);
    expect(find.text('C'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(frame('D', reduceMotion: true));
    expect(find.text('D'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('disposing an interrupted transition releases its ticker', (
    tester,
  ) async {
    await tester.pumpWidget(frame('A'));
    await tester.pumpWidget(frame('B'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
