import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';

void main() {
  testWidgets('renders secondary navigation without a standard app bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => FloatingSubpageScaffold(
                      title: 'Cache management',
                      actions: [
                        FloatingSubpageAction(
                          icon: Icons.refresh_rounded,
                          tooltip: 'Refresh',
                          onPressed: () {},
                        ),
                      ],
                      tools: const Text('Page tools'),
                      body: const Text('Page body'),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(
      find.byKey(const ValueKey('floating-subpage-header')),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.text('Cache management')).style?.fontSize,
      22,
    );
    final glassSurface = tester.widget<Container>(
      find.byKey(const ValueKey('glass-top-bar-surface')),
    );
    expect((glassSurface.decoration! as BoxDecoration).border, isNull);
    expect(find.byKey(const ValueKey('floating-subpage-back')), findsOneWidget);
    expect(find.text('Cache management'), findsOneWidget);
    expect(find.text('Page tools'), findsOneWidget);
    expect(find.text('Page body'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);

    final backRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-back')),
    );
    final titleRect = tester.getRect(find.text('Cache management'));
    final screenCenter =
        tester.getSize(find.byType(FloatingSubpageScaffold)).width / 2;
    expect((titleRect.center.dx - screenCenter).abs(), lessThan(1));
    expect((titleRect.center.dy - backRect.center.dy).abs(), lessThan(1));
    final bodyRect = tester.getRect(find.text('Page body'));
    final headerRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-header')),
    );
    final contentSurfaceRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-content-surface')),
    );
    expect(contentSurfaceRect.top, 0);
    expect(contentSurfaceRect.bottom, greaterThan(headerRect.bottom));
    expect(bodyRect.top, greaterThanOrEqualTo(headerRect.bottom));

    await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
  });

  testWidgets('can scroll page content behind the shared glass header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FloatingSubpageScaffold(
            title: 'Account',
            body: ListView(
              padding: floatingSubpagePadding(
                context,
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
              ),
              children: const [SizedBox(height: 900, child: Text('Content'))],
            ),
          ),
        ),
      ),
    );

    final headerRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-header')),
    );
    expect(tester.getTopLeft(find.text('Content')).dy, headerRect.bottom);

    await tester.drag(find.byType(ListView), const Offset(0, -120));
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('Content')).dy,
      lessThan(headerRect.bottom),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('ellipsizes long titles between the header controls', (
    tester,
  ) async {
    const title = 'Dart QR encoder adaptation with an intentionally long name';
    await tester.pumpWidget(
      const MaterialApp(
        home: FloatingSubpageScaffold(title: title, body: SizedBox.shrink()),
      ),
    );

    final titleFinder = find.text(title);
    final titleWidget = tester.widget<Text>(titleFinder);
    final titleRect = tester.getRect(titleFinder);
    final backRect = tester.getRect(
      find.byKey(const ValueKey('floating-subpage-back')),
    );

    expect(titleWidget.maxLines, 1);
    expect(titleWidget.overflow, TextOverflow.ellipsis);
    expect(titleRect.left, greaterThanOrEqualTo(backRect.right + 8));
  });

  testWidgets('shared menu springs from its anchor and returns selection', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: FloatingSubpageMenuButton<String>(
              key: const ValueKey('test-glass-menu'),
              icon: Icons.more_horiz_rounded,
              tooltip: 'More',
              items: const [
                FloatingSubpageMenuItem(value: 'import', child: Text('Import')),
              ],
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-glass-menu')));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('Import'), findsOneWidget);
    expect(find.byType(ScaleTransition), findsWidgets);

    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    expect(selected, 'import');
  });
}
