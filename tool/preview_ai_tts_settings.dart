// flutter test --no-pub tool/preview_ai_tts_settings.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/ai_settings_page.dart';
import 'package:xxread/pages/settings/cloud_tts_settings_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/reader_aloud_service.dart';
import 'package:xxread/utils/app_themes.dart';

class _Engine extends ChangeNotifier implements ReaderAloudAdjustableEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends ChangeNotifier implements ReaderAloudBytesPlayer {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements ReaderAloudCloudSettingsStore {
  @override
  Future<ReaderAloudEngineType> loadEngineType() async =>
      ReaderAloudEngineType.system;
  @override
  Future<ReaderAloudCloudSettings> loadSettings() async =>
      const ReaderAloudCloudSettings();
  @override
  Future<String?> readApiKey() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AI extends ReaderHttpAIService {
  @override
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]) async =>
      AIProviderSettings.defaults(provider ?? AIProviderType.openai);
}

void main() {
  testWidgets('capture service configuration pages', (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
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
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
    addTearDown(tester.view.reset);
    final engine = _Engine();
    final service = ReaderAloudService(
      systemEngine: engine,
      settingsStore: _Store(),
      bytesPlayer: _Player(),
    );
    addTearDown(service.dispose);
    addTearDown(engine.dispose);
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('.omx/ai-tts-previews')
          ..createSync(recursive: true);
        await File(
          '${output.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final dark in [false, true]) {
      for (final ai in [false, true]) {
        final name = '${ai ? 'ai' : 'tts'}-${dark ? 'dark-large' : 'light'}';
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(name),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(
              useMaterial3: true,
              fontFamily: 'SettingsPreview',
              colorScheme: ColorScheme.fromSeed(
                seedColor: AppThemes.defaultAccentColor,
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(dark ? 1.4 : 1)),
              child: RepaintBoundary(key: const Key('preview'), child: child!),
            ),
            home: ai
                ? AiSettingsPage(aiService: _AI())
                : CloudTtsSettingsPage(service: service),
          ),
        );
        await tester.pumpAndSettle();
        await capture(name);
        if (ai) {
          final add = find.text('添加模型');
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          await capture('$name-editor');
        } else {
          await tester.scrollUntilVisible(
            find.text('更多选项'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('更多选项'));
          await tester.pumpAndSettle();
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -400),
          );
          await tester.pumpAndSettle();
          await capture('$name-options');
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
