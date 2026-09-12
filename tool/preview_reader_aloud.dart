// flutter test tool/preview_reader_aloud.dart
// macOS preview: theme text loads a CJK font; CustomPaint covers retain the
// test engine default font, so their glyphs are not a typography reference.
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
  testWidgets('capture responsive audiobook player', (tester) async {
    await tester.runAsync(() async {
      final bytes = await File(
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      ).readAsBytes();
      await (FontLoader(
        'AloudPreview',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      final root = Platform.resolvedExecutable.split('/bin/cache').first;
      final icons = await File(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    });
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tts = _PanelTtsService();
    final aloud = ReaderAloudService(
      systemEngine: tts,
      settingsStore: _PanelSettingsStore(),
      cloudClient: _PanelCloudClient(),
      bytesPlayer: _PanelBytesPlayer(),
    );
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
          title: '自序 策略红利',
          text: '这个问题的答案一直在变化。',
        ),
        revealPosition: (_) async {},
        persistPosition: (_) async {},
      ),
    );
    addTearDown(() {
      controller.dispose();
      aloud.dispose();
      tts.dispose();
    });
    for (final scenario in [
      (
        name: 'small-landscape',
        size: const Size(568, 320),
        scale: 1.0,
        dark: false,
      ),
      (name: 'phone', size: const Size(390, 844), scale: 1.0, dark: false),
      (
        name: 'small-phone',
        size: const Size(320, 568),
        scale: 1.0,
        dark: false,
      ),
      (
        name: 'tablet-portrait',
        size: const Size(768, 1024),
        scale: 1.0,
        dark: false,
      ),
      (
        name: 'tablet-landscape',
        size: const Size(1194, 834),
        scale: 1.0,
        dark: false,
      ),
      (
        name: 'phone-landscape',
        size: const Size(844, 390),
        scale: 1.0,
        dark: false,
      ),
      (
        name: 'large-text-dark',
        size: const Size(390, 844),
        scale: 1.4,
        dark: true,
      ),
    ]) {
      tester.view.physicalSize = scenario.size;
      final padding = FakeViewPadding(
        top: scenario.size.width > scenario.size.height ? 0 : 24,
        bottom: 20,
      );
      tester.view.padding = padding;
      tester.view.viewPadding = padding;
      final palette = scenario.dark ? ReaderThemes.night : ReaderThemes.day;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: palette.toThemeData().copyWith(
            textTheme: ThemeData().textTheme.apply(fontFamily: 'AloudPreview'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
            child: RepaintBoundary(
              key: const Key('aloudPreview'),
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
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('aloudPreview')),
      );
      await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 2);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        final file = File('.omx/aloud-player-previews/${scenario.name}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
    debugDisableShadows = true;
  });
}

class _PanelTtsService extends TtsService {
  @override
  Future<void> initialize({bool force = false}) async {}

  @override
  Future<void> ensureVoicesLoaded({bool force = false}) async {}

  @override
  bool get isPlaying => false;

  @override
  bool get isPaused => false;

  @override
  int get currentPosition => 0;

  @override
  Future<void> pause() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

class _PanelSettingsStore implements ReaderAloudCloudSettingsStore {
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

class _PanelCloudClient implements ReaderAloudCloudClient {
  @override
  Future<Uint8List> synthesize({
    required ReaderAloudCloudSettings settings,
    required String apiKey,
    required String text,
    required double speed,
  }) async => Uint8List.fromList([1]);
}

class _PanelBytesPlayer extends ChangeNotifier
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
