import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/widgets/reader_desktop_input.dart';

void main() {
  testWidgets('reader keyboard shortcuts turn pages in both directions', (
    tester,
  ) async {
    var nextCount = 0;
    var previousCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderDesktopInput(
          onNext: () => nextCount++,
          onPrevious: () => previousCount++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    for (final key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.pageDown,
    ]) {
      await tester.sendKeyEvent(key);
    }
    for (final key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.pageUp,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(nextCount, 4);
    expect(previousCount, 4);
  });

  testWidgets('reader leaves modified navigation keys to focused content', (
    tester,
  ) async {
    var nextCount = 0;
    var previousCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderDesktopInput(
          onNext: () => nextCount++,
          onPrevious: () => previousCount++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(nextCount, 0);
    expect(previousCount, 0);
  });

  testWidgets('reader pointer scroll turns one page per wheel gesture', (
    tester,
  ) async {
    var nextCount = 0;
    var previousCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderDesktopInput(
          onNext: () => nextCount++,
          onPrevious: () => previousCount++,
          child: const SizedBox.expand(),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    expect(nextCount, 1);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(-80, 0),
        kind: PointerDeviceKind.trackpad,
      ),
    );
    await tester.pump();

    expect(previousCount, 1);
  });

  testWidgets('one continuous trackpad stream turns only one page', (
    tester,
  ) async {
    var nextCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderDesktopInput(
          onNext: () => nextCount++,
          onPrevious: () {},
          child: const SizedBox.expand(),
        ),
      ),
    );

    for (var index = 0; index < 6; index++) {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(100, 100),
          scrollDelta: Offset(0, 30),
          kind: PointerDeviceKind.trackpad,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(nextCount, 1);

    await tester.pump(const Duration(milliseconds: 181));
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 30),
        kind: PointerDeviceKind.trackpad,
      ),
    );
    await tester.pump();
    expect(nextCount, 2);
  });

  testWidgets('vertical reader can leave pointer scrolling to its child', (
    tester,
  ) async {
    var nextCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderDesktopInput(
          turnPageOnPointerScroll: false,
          onNext: () => nextCount++,
          onPrevious: () {},
          child: const SizedBox.expand(),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(100, 100),
        scrollDelta: Offset(0, 80),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await tester.pump();
    expect(nextCount, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(nextCount, 1);
  });
}
