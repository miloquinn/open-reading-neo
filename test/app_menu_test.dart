import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/widgets/app_menu.dart';
import 'package:xxread/widgets/glass_control_surface.dart';

void main() {
  Finder morphSurface() => find.byKey(const ValueKey('app-menu-morph-surface'));

  Path currentClip(WidgetTester tester) {
    final clip = tester.widget<ClipPath>(
      find.descendant(of: morphSurface(), matching: find.byType(ClipPath)),
    );
    return clip.clipper!.getClip(tester.getSize(morphSurface()));
  }

  Future<void> pumpMenu(
    WidgetTester tester, {
    List<PopupMenuEntry<String>>? items,
    ValueChanged<String>? onSelected,
    VoidCallback? onCanceled,
    bool enabled = true,
    bool disableAnimations = false,
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 24, bottom: 20),
    double textScale = 1,
    Alignment alignment = Alignment.topRight,
    ThemeMode themeMode = ThemeMode.light,
    String? initialValue,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
      left: padding.left,
    );
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        themeMode: themeMode,
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
            textScaler: TextScaler.linear(textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: alignment,
            child: AppPopupMenuButton<String>(
              key: const ValueKey('menu-anchor'),
              tooltip: 'More',
              enabled: enabled,
              onSelected: onSelected,
              onCanceled: onCanceled,
              initialValue: initialValue,
              itemBuilder: (_) =>
                  items ??
                  const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'row menus use plain dots unless a circular surface is requested',
    (tester) async {
      await pumpMenu(tester);
      final trigger = find.byKey(const ValueKey('menu-anchor'));
      expect(
        find.descendant(
          of: trigger,
          matching: find.byType(GlassControlSurface),
        ),
        findsNothing,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppPopupMenuButton<String>(
              buttonStyle: AppMenuButtonStyle.circular,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(GlassControlSurface), findsOneWidget);
    },
  );

  testWidgets('morphs from the circular anchor into the full menu bounds', (
    tester,
  ) async {
    await pumpMenu(tester);
    final anchor = tester.getRect(find.byKey(const ValueKey('menu-anchor')));

    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pump();
    final start = currentClip(tester).getBounds();
    final menuSize = tester.getSize(morphSurface());

    expect(start.size.width, closeTo(anchor.width, 0.01));
    expect(start.size.height, closeTo(anchor.height, 0.01));

    await tester.pump(const Duration(milliseconds: 180));
    final middle = currentClip(tester).getBounds();
    expect(middle.width, greaterThan(start.width));
    expect(middle.width, lessThan(menuSize.width));
    expect(middle.height, greaterThan(start.height));
    expect(middle.height, lessThan(menuSize.height));

    await tester.pumpAndSettle();
    final end = currentClip(tester).getBounds();
    expect(end, Offset.zero & menuSize);
  });

  testWidgets('reverse morph finishes before selection callbacks run', (
    tester,
  ) async {
    final calls = <String>[];
    await pumpMenu(
      tester,
      items: [
        PopupMenuItem<String>(
          value: 'edit',
          onTap: () => calls.add('item'),
          child: const Text('Edit'),
        ),
      ],
      onSelected: (value) => calls.add('selected:$value'),
    );
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(calls, isEmpty);
    expect(morphSurface(), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 140));
    final middle = currentClip(tester).getBounds();
    expect(middle.width, lessThan(tester.getSize(morphSurface()).width));
    expect(calls, isEmpty);

    await tester.pumpAndSettle();
    expect(calls, ['item', 'selected:edit']);
    expect(morphSurface(), findsNothing);
  });

  testWidgets('tapping outside cancels after the reverse morph finishes', (
    tester,
  ) async {
    var cancellations = 0;
    await pumpMenu(tester, onCanceled: () => cancellations++);
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(20, 400));
    await tester.pump();
    expect(cancellations, 0);
    expect(morphSurface(), findsOneWidget);

    await tester.pumpAndSettle();
    expect(cancellations, 1);
    expect(morphSurface(), findsNothing);
  });

  testWidgets('disabled trigger does not open a menu', (tester) async {
    await pumpMenu(tester, enabled: false);
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pump();

    expect(morphSurface(), findsNothing);
    expect(find.text('Edit'), findsNothing);
  });

  testWidgets('disabled menu item cannot be selected', (tester) async {
    String? selected;
    await pumpMenu(
      tester,
      items: const [
        PopupMenuItem(value: 'disabled', enabled: false, child: Text('Locked')),
        PopupMenuItem(value: 'enabled', child: Text('Available')),
      ],
      onSelected: (value) => selected = value,
    );
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Locked'));
    await tester.pump();
    expect(selected, isNull);
    expect(morphSurface(), findsOneWidget);

    await tester.tap(find.text('Available'));
    await tester.pumpAndSettle();
    expect(selected, 'enabled');
  });

  testWidgets('long menu scrolls inside the bottom safe area', (tester) async {
    await pumpMenu(
      tester,
      alignment: Alignment.bottomRight,
      padding: const EdgeInsets.only(top: 24, bottom: 34),
      items: [
        for (var index = 0; index < 20; index++)
          PopupMenuItem(value: '$index', child: Text('Action $index')),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    final menu = tester.getRect(morphSurface());
    expect(menu.bottom, lessThanOrEqualTo(844 - 34 - 12));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Action 19').hitTestable(), findsNothing);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.text('Action 19').hitTestable(), findsOneWidget);
  });

  testWidgets('narrow screen and large text keep menu within safe bounds', (
    tester,
  ) async {
    await pumpMenu(
      tester,
      size: const Size(320, 568),
      textScale: 1.6,
      themeMode: ThemeMode.dark,
      padding: const EdgeInsets.only(top: 28, bottom: 24),
      items: const [
        PopupMenuItem(
          value: 'details',
          child: Text('A deliberately long menu action label'),
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    final menu = tester.getRect(morphSurface());
    expect(menu.left, greaterThanOrEqualTo(12));
    expect(menu.right, lessThanOrEqualTo(308));
    expect(menu.top, greaterThanOrEqualTo(40));
    expect(menu.bottom, lessThanOrEqualTo(532));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion opens and closes without intermediate frames', (
    tester,
  ) async {
    String? selected;
    await pumpMenu(
      tester,
      disableAnimations: true,
      onSelected: (value) => selected = value,
    );
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pump();

    expect(
      currentClip(tester).getBounds(),
      Offset.zero & tester.getSize(morphSurface()),
    );

    await tester.tap(find.text('Edit'));
    await tester.pump();
    expect(selected, 'edit');
    expect(morphSurface(), findsNothing);
  });

  testWidgets('escape key dismisses the menu as a cancellation', (
    tester,
  ) async {
    var cancellations = 0;
    await pumpMenu(tester, onCanceled: () => cancellations++);
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(morphSurface(), findsNothing);
    expect(cancellations, 1);
  });

  testWidgets('arrow down and enter select the next enabled item', (
    tester,
  ) async {
    String? selected;
    await pumpMenu(tester, onSelected: (value) => selected = value);
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, 'remove');
  });

  testWidgets('initial value marks its menu item as selected', (tester) async {
    await pumpMenu(tester, initialValue: 'remove');
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    final selectedSemantics = tester
        .widgetList<Semantics>(
          find.ancestor(
            of: find.text('Remove'),
            matching: find.byType(Semantics),
          ),
        )
        .where((widget) => widget.properties.selected == true);
    expect(selectedSemantics, isNotEmpty);
  });

  testWidgets('dismissal restores focus to the menu trigger', (tester) async {
    await pumpMenu(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(morphSurface(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final focusedContext = FocusManager.instance.primaryFocus?.context;
    expect(focusedContext, isNotNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('menu-anchor')),
        matching: find.byWidget(focusedContext!.widget),
      ),
      findsOneWidget,
    );
  });

  testWidgets('partial opening reverses continuously and can reopen', (
    tester,
  ) async {
    await pumpMenu(tester);
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final beforeDismiss = currentClip(tester).getBounds();

    await tester.tapAt(const Offset(20, 400));
    await tester.pump();
    final reverseStart = currentClip(tester).getBounds();
    expect(reverseStart, beforeDismiss);
    await tester.pump(const Duration(milliseconds: 40));
    final reversing = currentClip(tester).getBounds();
    expect(reversing.width, lessThan(beforeDismiss.width));
    expect(reversing.width, lessThan(tester.getSize(morphSurface()).width));

    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-anchor')));
    await tester.pumpAndSettle();
    expect(morphSurface(), findsOneWidget);
  });
}
