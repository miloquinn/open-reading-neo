// flutter test --no-pub tool/preview_app_text_size.dart
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/app_text_size_sheet.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/widgets/app_text_scale.dart';

void main() {
  testWidgets('capture interface text size at maximum size', (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({'app_text_scale_level_v1': 4});
    await tester.runAsync(() async {
      final bytes = await File(
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      ).readAsBytes();
      await (FontLoader(
        'SettingsPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      final root = Platform.resolvedExecutable.split('/bin/cache').first;
      final icons = await File(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    });
    final settings = (await tester.runAsync(() async {
      final settings = AppSettingsNotifier();
      final ready = Completer<void>();
      void onReady() {
        if (settings.isInitialized && !ready.isCompleted) ready.complete();
      }

      settings.addListener(onReady);
      onReady();
      await ready.future;
      settings.removeListener(onReady);
      return settings;
    }))!;
    addTearDown(settings.dispose);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scenario in [
      (name: 'phone', size: const Size(320, 568), dark: false),
      (name: 'phone-dark', size: const Size(390, 844), dark: true),
      (name: 'landscape', size: const Size(568, 320), dark: false),
    ]) {
      tester.view.physicalSize = scenario.size;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            key: ValueKey(scenario.name),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              fontFamily: 'SettingsPreview',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF586A51),
                brightness: scenario.dark ? Brightness.dark : Brightness.light,
              ),
            ),
            builder: (context, child) => AppTextScale(
              child: RepaintBoundary(key: const Key('preview'), child: child!),
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      showDragHandle: true,
                      builder: (_) => const AppTextSizeSheet(),
                    ),
                    child: const Text('界面字体大小'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(settings.appTextScaleFactor, 1.3);
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('.omx/app-text-size-previews')
          ..createSync(recursive: true);
        await File(
          '${output.path}/${scenario.name}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
