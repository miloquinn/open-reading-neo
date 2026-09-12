// flutter test tool/preview_app_menu.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/widgets/app_menu.dart';

void main() {
  testWidgets('capture shared app menu morph states', (tester) async {
    await tester.runAsync(() async {
      final bytes = await File(
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      ).readAsBytes();
      await (FontLoader(
        'AppMenuPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      final flutterRoot = Platform.resolvedExecutable.split('/bin/cache').first;
      final icons = await File(
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    });
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final scenarios = [
      const _PreviewScenario(
        name: 'phone-open-060ms',
        size: Size(390, 844),
        alignment: Alignment.topRight,
        frame: Duration(milliseconds: 60),
      ),
      const _PreviewScenario(
        name: 'phone-open-100ms',
        size: Size(390, 844),
        alignment: Alignment.topRight,
        frame: Duration(milliseconds: 100),
      ),
      const _PreviewScenario(
        name: 'phone-middle-frame',
        size: Size(390, 844),
        alignment: Alignment.topRight,
        frame: Duration(milliseconds: 180),
      ),
      const _PreviewScenario(
        name: 'phone-expanded',
        size: Size(390, 844),
        alignment: Alignment.topRight,
      ),
      const _PreviewScenario(
        name: 'narrow-dark-large-text',
        size: Size(320, 568),
        alignment: Alignment.topRight,
        dark: true,
        textScale: 1.45,
      ),
      const _PreviewScenario(
        name: 'bottom-upward',
        size: Size(390, 844),
        alignment: Alignment.bottomRight,
        longMenu: true,
      ),
    ];

    for (final scenario in scenarios) {
      tester.view.physicalSize = scenario.size;
      const padding = FakeViewPadding(top: 24, bottom: 24);
      tester.view.padding = padding;
      tester.view.viewPadding = padding;

      await tester.pumpWidget(_PreviewApp(scenario: scenario));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('preview-menu-anchor')));
      if (scenario.frame case final frame?) {
        await tester.pump();
        await tester.pump(frame);
      } else {
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await _capturePreview(tester, '${scenario.name}.png');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }

    const animationScenario = _PreviewScenario(
      name: 'animation',
      size: Size(390, 844),
      alignment: Alignment.topRight,
    );
    tester.view.physicalSize = animationScenario.size;
    const animationPadding = FakeViewPadding(top: 24, bottom: 24);
    tester.view.padding = animationPadding;
    tester.view.viewPadding = animationPadding;
    await tester.pumpWidget(const _PreviewApp(scenario: animationScenario));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('preview-menu-anchor')));
    await tester.pump();
    for (var frame = 0; frame <= 12; frame++) {
      await _capturePreview(
        tester,
        'animation/frame-${frame.toString().padLeft(2, '0')}.png',
      );
      if (frame < 12) await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑书源'));
    await tester.pump();
    for (var reverseFrame = 0; reverseFrame <= 10; reverseFrame++) {
      final frame = reverseFrame + 13;
      await _capturePreview(
        tester,
        'animation/frame-${frame.toString().padLeft(2, '0')}.png',
      );
      if (reverseFrame < 10) {
        await tester.pump(const Duration(milliseconds: 28));
      }
    }
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      final result = await Process.run('/opt/homebrew/bin/ffmpeg', [
        '-y',
        '-framerate',
        '30',
        '-i',
        'artifacts/app-menu/animation/frame-%02d.png',
        '-vf',
        'crop=780:900:0:0,scale=390:-1:flags=lanczos',
        '-loop',
        '0',
        'artifacts/app-menu/app-menu-morph.gif',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    });
    debugDisableShadows = true;
  });
}

Future<void> _capturePreview(WidgetTester tester, String relativePath) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('appMenuPreview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('artifacts/app-menu/$relativePath');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp({required this.scenario});

  final _PreviewScenario scenario;

  @override
  Widget build(BuildContext context) {
    final theme = (scenario.dark ? ThemeData.dark() : ThemeData.light())
        .copyWith(
          textTheme: (scenario.dark ? ThemeData.dark() : ThemeData.light())
              .textTheme
              .apply(fontFamily: 'AppMenuPreview'),
        );
    return MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scenario.textScale)),
        child: RepaintBoundary(
          key: const ValueKey('appMenuPreview'),
          child: child!,
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('共享菜单预览'),
          actions: scenario.alignment == Alignment.topRight
              ? [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _PreviewMenu(scenario: scenario),
                  ),
                ]
              : null,
        ),
        body: Padding(
          padding: const EdgeInsets.all(18),
          child: Stack(
            children: [
              ListView.separated(
                itemCount: 6,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) => Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${index + 1}')),
                    title: Text('书源 ${index + 1}'),
                    subtitle: const Text('example.org · 已启用'),
                  ),
                ),
              ),
              if (scenario.alignment != Alignment.topRight)
                Align(
                  alignment: scenario.alignment,
                  child: _PreviewMenu(scenario: scenario),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewMenu extends StatelessWidget {
  const _PreviewMenu({required this.scenario});

  final _PreviewScenario scenario;

  @override
  Widget build(BuildContext context) {
    return AppPopupMenuButton<String>(
      buttonStyle: scenario.alignment == Alignment.topRight
          ? AppMenuButtonStyle.circular
          : AppMenuButtonStyle.plain,
      key: const ValueKey('preview-menu-anchor'),
      tooltip: '更多',
      icon: const Icon(Icons.more_horiz_rounded),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit_rounded),
            title: Text('编辑书源'),
          ),
        ),
        const PopupMenuItem(
          value: 'group',
          child: ListTile(
            leading: Icon(Icons.folder_outlined),
            title: Text('编辑分组'),
          ),
        ),
        const PopupMenuItem(
          value: 'debug',
          child: ListTile(
            leading: Icon(Icons.bug_report_outlined),
            title: Text('调试'),
          ),
        ),
        const PopupMenuItem(
          value: 'verify',
          child: ListTile(
            leading: Icon(Icons.verified_user_outlined),
            title: Text('重新校验'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'remove',
          child: ListTile(
            leading: Icon(Icons.delete_outline_rounded),
            title: Text('移除'),
          ),
        ),
        if (scenario.longMenu) ...[
          const PopupMenuDivider(),
          for (var index = 0; index < 8; index++)
            PopupMenuItem(
              value: 'extra-$index',
              child: Text('附加操作 ${index + 1}'),
            ),
        ],
      ],
    );
  }
}

class _PreviewScenario {
  const _PreviewScenario({
    required this.name,
    required this.size,
    required this.alignment,
    this.frame,
    this.dark = false,
    this.textScale = 1,
    this.longMenu = false,
  });

  final String name;
  final Size size;
  final Alignment alignment;
  final Duration? frame;
  final bool dark;
  final double textScale;
  final bool longMenu;
}
