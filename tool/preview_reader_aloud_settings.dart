// flutter test tool/preview_reader_aloud_settings.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/services/reader_aloud_service.dart';
import 'package:xxread/services/tts_service.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_aloud_panel.dart';

void main() {
  testWidgets('capture reader aloud settings over the player', (tester) async {
    await tester.runAsync(() async {
      final bytes = await File(
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      ).readAsBytes();
      await (FontLoader(
        'AloudSettingsPreview',
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

    for (final scenario in [
      (
        name: 'system-phone',
        size: const Size(390, 844),
        scale: 1.0,
        dark: false,
        engine: ReaderAloudEngineType.system,
      ),
      (
        name: 'cloud-phone',
        size: const Size(390, 844),
        scale: 1.0,
        dark: false,
        engine: ReaderAloudEngineType.cloud,
      ),
      (
        name: 'system-narrow-dark-large-text',
        size: const Size(320, 568),
        scale: 1.4,
        dark: true,
        engine: ReaderAloudEngineType.system,
      ),
      (
        name: 'cloud-narrow-dark-large-text',
        size: const Size(320, 568),
        scale: 1.4,
        dark: true,
        engine: ReaderAloudEngineType.cloud,
      ),
    ]) {
      tester.view.physicalSize = scenario.size;
      const padding = FakeViewPadding(top: 24, bottom: 20);
      tester.view.padding = padding;
      tester.view.viewPadding = padding;

      final tts = _PreviewTtsService();
      final aloud = ReaderAloudService(
        systemEngine: tts,
        settingsStore: _PreviewSettingsStore(),
        cloudClient: _PreviewCloudClient(),
        bytesPlayer: _PreviewBytesPlayer(),
      );
      await aloud.initialize();
      await aloud.setEngineType(scenario.engine);
      final controller = ReaderAloudController(
        engine: aloud,
        source: CallbackReaderAloudSource(
          bookTitle: '学习的逻辑：中学生高效学习策略体系',
          chapterCount: () => 2,
          currentPosition: () async =>
              const ReaderAloudPosition(chapterIndex: 0, offset: 0),
          loadChapter: (index) async => ReaderAloudChapter(
            index: index,
            id: 'chapter-$index',
            title: '珍藏版序言',
            text: '另外，第1版也有造作之嫌，貌似我们想利用低廉的价格吸引读者。',
          ),
          revealPosition: (_) async {},
          persistPosition: (_) async {},
        ),
      );
      final palette = scenario.dark ? ReaderThemes.night : ReaderThemes.day;
      final theme = palette.toThemeData().copyWith(
        textTheme: palette.toThemeData().textTheme.apply(
          fontFamily: 'AloudSettingsPreview',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
            child: RepaintBoundary(
              key: const Key('aloudSettingsPreview'),
              child: child!,
            ),
          ),
          home: ReaderAloudPlayerPage(
            controller: controller,
            ttsService: tts,
            aloudService: aloud,
            palette: palette,
            author: '叶修',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final playerContext = tester.element(find.byType(ReaderAloudPlayerPage));
      showReaderAloudSettingsSheet(
        context: playerContext,
        controller: controller,
        ttsService: tts,
        aloudService: aloud,
        palette: palette,
        themeData: theme,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('aloudSettingsPreview')),
      );
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('.omx/aloud-settings-previews/${scenario.name}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });

      controller.dispose();
      aloud.dispose();
      tts.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    }
    debugDisableShadows = true;
  });
}

class _PreviewTtsService extends TtsService {
  @override
  List<TtsVoiceOption> get availableVoices => const [
    TtsVoiceOption(name: '普通话女声', locale: 'zh-CN'),
    TtsVoiceOption(name: '普通话男声', locale: 'zh-CN'),
  ];

  @override
  Future<void> initialize({bool force = false}) async {}

  @override
  Future<void> ensureVoicesLoaded({bool force = false}) async {}

  @override
  bool get supportsQueuedText => false;

  @override
  Future<void> pause() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

class _PreviewSettingsStore implements ReaderAloudCloudSettingsStore {
  @override
  Future<void> clearApiKey() async {}

  @override
  Future<ReaderAloudEngineType> loadEngineType() async =>
      ReaderAloudEngineType.system;

  @override
  Future<ReaderAloudCloudSettings> loadSettings() async =>
      const ReaderAloudCloudSettings();

  @override
  Future<String?> readApiKey() async => null;

  @override
  Future<void> saveEngineType(ReaderAloudEngineType type) async {}

  @override
  Future<void> saveSettings(ReaderAloudCloudSettings settings) async {}

  @override
  Future<void> writeApiKey(String apiKey) async {}
}

class _PreviewCloudClient implements ReaderAloudCloudClient {
  @override
  Future<Uint8List> synthesize({
    required ReaderAloudCloudSettings settings,
    required String apiKey,
    required String text,
    required double speed,
  }) async => Uint8List.fromList([1]);
}

class _PreviewBytesPlayer extends ChangeNotifier
    implements ReaderAloudBytesPlayer {
  @override
  Duration get duration => Duration.zero;

  @override
  bool get isPaused => false;

  @override
  bool get isPlaying => false;

  @override
  Duration get position => Duration.zero;

  @override
  Future<void> pause() async {}

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}
}
