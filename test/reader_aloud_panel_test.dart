import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/services/reader_aloud_service.dart';
import 'package:xxread/services/tts_service.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_aloud_panel.dart';

void main() {
  final viewportScenarios = <_ViewportScenario>[
    const _ViewportScenario('compact phone', Size(320, 568), textScale: 1.4),
    const _ViewportScenario(
      'safe-area phone',
      Size(390, 844),
      padding: EdgeInsets.only(top: 24, bottom: 34),
    ),
    const _ViewportScenario(
      'compact landscape phone',
      Size(568, 320),
      padding: EdgeInsets.only(bottom: 20),
      wide: true,
    ),
    const _ViewportScenario(
      'compact safe-area landscape phone',
      Size(667, 375),
      padding: EdgeInsets.only(left: 44, right: 44, bottom: 21),
      wide: true,
    ),
    const _ViewportScenario('portrait tablet', Size(768, 1024), wide: true),
    const _ViewportScenario('landscape tablet', Size(1194, 834), wide: true),
    const _ViewportScenario(
      'landscape phone',
      Size(844, 390),
      padding: EdgeInsets.only(left: 44, right: 44, bottom: 21),
      wide: true,
    ),
  ];

  for (final scenario in viewportScenarios) {
    testWidgets(
      'audiobook player keeps every primary control visible on ${scenario.name}',
      (tester) async {
        final fixture = await _openPlayer(
          tester,
          size: scenario.size,
          padding: scenario.padding,
          textScale: scenario.textScale,
        );
        addTearDown(fixture.dispose);

        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(
          find.byKey(const ValueKey('reader-aloud-cover')),
          findsOneWidget,
        );
        final safeBounds = Rect.fromLTRB(
          scenario.padding.left,
          scenario.padding.top,
          scenario.size.width - scenario.padding.right,
          scenario.size.height - scenario.padding.bottom,
        );
        for (final key in [
          'reader-aloud-play-pause',
          'reader-aloud-chapters',
          'reader-aloud-volume',
          'reader-aloud-engine',
        ]) {
          final control = find.byKey(ValueKey(key));
          expect(control.hitTestable(), findsOneWidget);
          final bounds = tester.getRect(control);
          expect(bounds.left, greaterThanOrEqualTo(safeBounds.left));
          expect(bounds.top, greaterThanOrEqualTo(safeBounds.top));
          expect(bounds.right, lessThanOrEqualTo(safeBounds.right));
          expect(bounds.bottom, lessThanOrEqualTo(safeBounds.bottom));
          expect(bounds.height, greaterThanOrEqualTo(44));
        }
        expect(
          find.byKey(const ValueKey('reader-aloud-wide-layout')),
          scenario.wide ? findsOneWidget : findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('player volume previews locally and commits to system playback', (
    tester,
  ) async {
    final fixture = await _openPlayer(
      tester,
      size: const Size(390, 844),
      holdSystemSpeech: true,
    );
    addTearDown(fixture.dispose);
    expect(fixture.controller.state, ReaderAloudPlaybackState.playing);

    final sliderFinder = find.byKey(const ValueKey('reader-aloud-volume'));
    final slider = tester.widget<Slider>(sliderFinder);
    final stopsBeforeCommit = fixture.tts.stopCalls;
    slider.onChanged?.call(0.35);
    await tester.pump();

    expect(tester.widget<Slider>(sliderFinder).value, 0.35);
    expect(fixture.tts.volumeCalls, isEmpty);

    tester.widget<Slider>(sliderFinder).onChangeEnd?.call(0.35);
    await tester.pump();
    await tester.pump();

    expect(fixture.tts.volumeCalls, [0.35]);
    expect(fixture.tts.speechVolume, 0.35);
    expect(fixture.tts.stopCalls, greaterThan(stopsBeforeCommit));
    expect(fixture.bytesPlayer.volumeCalls, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    await fixture.controller.stop();
  });

  testWidgets('player volume commits to the active cloud bytes player', (
    tester,
  ) async {
    final fixture = await _openPlayer(tester, size: const Size(768, 1024));
    addTearDown(fixture.dispose);
    await fixture.aloud.setEngineType(ReaderAloudEngineType.cloud);
    await tester.pump();

    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('reader-aloud-volume')),
    );
    slider.onChanged?.call(0.62);
    await tester.pump();
    slider.onChangeEnd?.call(0.62);
    await tester.pump();
    await tester.pump();

    expect(fixture.tts.volumeCalls, [0.62]);
    expect(fixture.bytesPlayer.volumeCalls, [0.62]);
  });

  testWidgets(
    'cloud configuration in the player opens the shared settings page',
    (tester) async {
      final fixture = await _openPlayer(tester, size: const Size(390, 844));
      addTearDown(fixture.dispose);

      await tester.tap(find.byKey(const ValueKey('reader-aloud-engine')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('云端 TTS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('gpt-4o-mini-tts · alloy'));
      await tester.pumpAndSettle();

      expect(find.text('云端 TTS'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cloud-tts-save')).hitTestable(),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'settings sheet contains settings without duplicating the player',
    (tester) async {
      final fixture = await _openSettingsFromPlayer(
        tester,
        size: const Size(390, 844),
      );
      addTearDown(fixture.dispose);

      final sheet = find.byType(BottomSheet);
      expect(
        find.descendant(
          of: sheet,
          matching: find.byKey(const ValueKey('reader-aloud-cover')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('第1章')),
        findsNothing,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('这个问题的答案一直在变化。')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.byType(LinearProgressIndicator),
        ),
        findsNothing,
      );
      expect(
        find.descendant(of: sheet, matching: find.byType(Slider)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: sheet, matching: find.text('音量')),
        findsNothing,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('音调')),
        findsOneWidget,
      );

      await tester.tap(
        find.descendant(of: sheet, matching: find.text('云端 TTS')),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: sheet, matching: find.byType(Slider)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('音调')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: sheet,
          matching: find.text('gpt-4o-mini-tts · alloy'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.descendant(of: sheet, matching: find.text('系统语音')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: sheet, matching: find.byType(Slider)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: sheet, matching: find.text('音色')),
        findsOneWidget,
      );
    },
  );

  testWidgets('settings sheet applies rate, pitch, voice, and engine changes', (
    tester,
  ) async {
    final fixture = await _openSettingsFromPlayer(
      tester,
      size: const Size(390, 844),
    );
    addTearDown(fixture.dispose);
    final sheet = find.byType(BottomSheet);
    var sliders = tester.widgetList<Slider>(
      find.descendant(of: sheet, matching: find.byType(Slider)),
    );

    sliders.first.onChanged?.call(0.72);
    sliders.first.onChangeEnd?.call(0.72);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(fixture.tts.speechRate, 0.72);

    sliders = tester.widgetList<Slider>(
      find.descendant(of: sheet, matching: find.byType(Slider)),
    );
    sliders.elementAt(1).onChanged?.call(1.35);
    await tester.pump();
    tester
        .widgetList<Slider>(
          find.descendant(of: sheet, matching: find.byType(Slider)),
        )
        .elementAt(1)
        .onChangeEnd
        ?.call(1.35);
    await tester.pump();
    await tester.pump();
    expect(fixture.tts.speechPitch, 1.35);

    await tester.tap(find.text('系统默认'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通话女声 · zh-CN').last);
    await tester.pumpAndSettle();
    expect(fixture.tts.currentVoice?.name, '普通话女声');

    await tester.tap(find.descendant(of: sheet, matching: find.text('云端 TTS')));
    await tester.pumpAndSettle();
    expect(fixture.aloud.engineType, ReaderAloudEngineType.cloud);
  });

  testWidgets('settings sheet scrolls on a narrow phone with large text', (
    tester,
  ) async {
    final fixture = await _openSettingsFromPlayer(
      tester,
      size: const Size(320, 568),
      textScale: 1.6,
    );
    addTearDown(fixture.dispose);
    final sheet = find.byType(BottomSheet);

    expect(
      find.descendant(of: sheet, matching: find.byType(SingleChildScrollView)),
      findsOneWidget,
    );
    final timer = find.byKey(const ValueKey('reader-aloud-sleep-timer-card'));
    await tester.ensureVisible(timer);
    await tester.pump();
    expect(timer.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final localeScenario in [
    (locale: const Locale('en'), system: 'System', cloud: 'Cloud TTS'),
    (locale: const Locale('ja'), system: 'システム音声', cloud: 'クラウド TTS'),
  ]) {
    testWidgets(
      'narrow large-text settings switch engines in ${localeScenario.locale.languageCode}',
      (tester) async {
        final fixture = await _openSettingsFromPlayer(
          tester,
          size: const Size(320, 568),
          textScale: 1.6,
          locale: localeScenario.locale,
        );
        addTearDown(fixture.dispose);
        final sheet = find.byType(BottomSheet);

        expect(
          find.descendant(
            of: sheet,
            matching: find.text(localeScenario.system),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: sheet, matching: find.text(localeScenario.cloud)),
        );
        await tester.pumpAndSettle();

        expect(fixture.aloud.engineType, ReaderAloudEngineType.cloud);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('audiobook player shows the current sentence and controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tts = _PanelTtsService(holdSpeech: true);
    final aloud = ReaderAloudService(
      systemEngine: tts,
      settingsStore: _PanelSettingsStore(),
      cloudClient: _PanelCloudClient(),
      bytesPlayer: _PanelBytesPlayer(),
    );
    final controller = ReaderAloudController(
      engine: aloud,
      source: CallbackReaderAloudSource(
        bookTitle: '测试书籍',
        chapterCount: () => 2,
        currentPosition: () async =>
            const ReaderAloudPosition(chapterIndex: 0, offset: 0),
        loadChapter: (index) async => ReaderAloudChapter(
          index: index,
          id: 'chapter-$index',
          title: '第${index + 1}章',
          text: index == 0 ? '正在朗读的第一句。第二句。' : '下一章第一句。',
        ),
        revealPosition: (_) async {},
        persistPosition: (_) async {},
      ),
    );
    addTearDown(() async {
      controller.dispose();
      aloud.dispose();
      tts.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showReaderAloudPlayer(
                context: context,
                controller: controller,
                ttsService: tts,
                aloudService: aloud,
                palette: ReaderThemes.day,
                themeData: Theme.of(context),
                author: '测试作者',
              ),
              child: const Text('open player'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open player'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('测试书籍'), findsOneWidget);
    expect(find.text('第1章'), findsOneWidget);
    expect(find.text('正在朗读的第一句。'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-aloud-play-pause')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('reader-aloud-chapters')), findsOneWidget);
    expect(find.text('bgm'), findsNothing);
    expect(find.text('原文'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('reader-aloud-chapters')));
    await tester.pumpAndSettle();
    expect(find.text('第2章'), findsOneWidget);
    await tester.tap(find.text('第2章'));
    await tester.pumpAndSettle();
    expect(find.text('下一章第一句。'), findsOneWidget);
    await controller.stop();
  });

  testWidgets('audiobook sheet is bounded, draggable, and accepts any timer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
        bookTitle: '测试书籍',
        chapterCount: () => 1,
        currentPosition: () async =>
            const ReaderAloudPosition(chapterIndex: 0, offset: 0),
        loadChapter: (_) async => const ReaderAloudChapter(
          index: 0,
          id: 'chapter-1',
          title: '第一章',
          text: '第一句。',
        ),
        revealPosition: (_) async {},
        persistPosition: (_) async {},
      ),
    );
    addTearDown(() async {
      controller.dispose();
      aloud.dispose();
      tts.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showReaderAloudPanelSheet(
                  context: context,
                  controller: controller,
                  ttsService: tts,
                  aloudService: aloud,
                  palette: ReaderThemes.day,
                  themeData: Theme.of(context),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    expect(bottomSheet.enableDrag, isTrue);
    expect(bottomSheet.showDragHandle, isTrue);
    expect(
      tester.getSize(find.byType(BottomSheet)).height,
      lessThanOrEqualTo(576),
    );
    expect(
      find.byKey(const ValueKey('reader-aloud-sleep-timer-card')),
      findsOneWidget,
    );
    expect(find.text('15分钟'), findsNothing);
    expect(find.text('30分钟'), findsNothing);
    expect(find.text('60分钟'), findsNothing);

    final speedSlider = tester.widgetList<Slider>(find.byType(Slider)).first;
    speedSlider.onChanged?.call(0.8);
    await tester.pump();
    expect(find.text('1.60×'), findsOneWidget);
    speedSlider.onChangeEnd?.call(0.8);
    await tester.pumpAndSettle();
    expect(tts.speechRate, 0.8);

    final timerCard = find.byKey(
      const ValueKey('reader-aloud-sleep-timer-card'),
    );
    await tester.ensureVisible(timerCard);
    await tester.pumpAndSettle();
    await tester.tap(timerCard);
    await tester.pumpAndSettle();

    final picker = tester.widget<CupertinoTimerPicker>(
      find.byKey(const ValueKey('reader-aloud-sleep-timer-picker')),
    );
    picker.onTimerDurationChanged(const Duration(hours: 2, minutes: 7));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('reader-aloud-sleep-timer-confirm')),
    );
    await tester.pumpAndSettle();

    expect(controller.sleepDuration, const Duration(hours: 2, minutes: 7));
    expect(find.textContaining('2 小时 7 分钟'), findsOneWidget);
    controller.setSleepTimer(null);

    final sheetRect = tester.getRect(find.byType(BottomSheet));
    await tester.dragFrom(
      Offset(sheetRect.center.dx, sheetRect.top + 12),
      const Offset(0, 520),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });
}

class _PanelTtsService extends TtsService {
  _PanelTtsService({this.holdSpeech = false});

  final bool holdSpeech;
  final List<double> volumeCalls = [];
  int stopCalls = 0;
  double _volume = 1;
  double _rate = 0.5;
  double _pitch = 1;
  TtsVoiceOption? _voice;

  @override
  List<TtsVoiceOption> get availableVoices => const [
    TtsVoiceOption(name: '普通话女声', locale: 'zh-CN'),
    TtsVoiceOption(name: '普通话男声', locale: 'zh-CN'),
  ];

  @override
  TtsVoiceOption? get currentVoice => _voice;

  @override
  double get speechRate => _rate;

  @override
  double get speechPitch => _pitch;

  @override
  double get speechVolume => _volume;

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

  // The lightweight fake does not model the platform queue API. Advertising
  // queue support makes the controller call TtsService's real plugin-backed
  // implementation instead of this fake's speak override.
  @override
  bool get supportsQueuedText => false;

  @override
  Future<void> pause() async {}

  @override
  Future<void> speak(String text) async {
    if (holdSpeech) await Completer<void>().future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    volumeCalls.add(volume);
    notifyListeners();
  }

  @override
  Future<void> setSpeechRate(double rate) async {
    _rate = rate;
    notifyListeners();
  }

  @override
  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    notifyListeners();
  }

  @override
  Future<void> setVoice(TtsVoiceOption voice) async {
    _voice = voice;
    notifyListeners();
  }

  @override
  Future<void> clearSelectedVoice() async {
    _voice = null;
    notifyListeners();
  }
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
  final List<double> volumeCalls = [];

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
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
  }

  @override
  Future<void> stop() async {}
}

class _ViewportScenario {
  const _ViewportScenario(
    this.name,
    this.size, {
    this.padding = EdgeInsets.zero,
    this.textScale = 1,
    this.wide = false,
  });

  final String name;
  final Size size;
  final EdgeInsets padding;
  final double textScale;
  final bool wide;
}

class _PlayerFixture {
  const _PlayerFixture({
    required this.controller,
    required this.aloud,
    required this.tts,
    required this.bytesPlayer,
  });

  final ReaderAloudController controller;
  final ReaderAloudService aloud;
  final _PanelTtsService tts;
  final _PanelBytesPlayer bytesPlayer;

  Future<void> dispose() async {
    controller.dispose();
    aloud.dispose();
    tts.dispose();
  }
}

Future<_PlayerFixture> _openPlayer(
  WidgetTester tester, {
  required Size size,
  EdgeInsets padding = EdgeInsets.zero,
  double textScale = 1,
  bool holdSystemSpeech = false,
  Locale locale = const Locale('zh'),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final tts = _PanelTtsService(holdSpeech: holdSystemSpeech);
  final bytesPlayer = _PanelBytesPlayer();
  final aloud = ReaderAloudService(
    systemEngine: tts,
    settingsStore: _PanelSettingsStore(),
    cloudClient: _PanelCloudClient(),
    bytesPlayer: bytesPlayer,
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
        title: '第${index + 1}章',
        text: index == 0 ? '这个问题的答案一直在变化。第二句。' : '下一章第一句。',
      ),
      revealPosition: (_) async {},
      persistPosition: (_) async {},
    ),
  );

  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: padding,
          viewPadding: padding,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => showReaderAloudPlayer(
              context: context,
              controller: controller,
              ttsService: tts,
              aloudService: aloud,
              palette: ReaderThemes.day,
              themeData: Theme.of(context),
              author: '测试作者',
            ),
            child: const Text('open responsive player'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open responsive player'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  return _PlayerFixture(
    controller: controller,
    aloud: aloud,
    tts: tts,
    bytesPlayer: bytesPlayer,
  );
}

Future<_PlayerFixture> _openSettingsFromPlayer(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
  Locale locale = const Locale('zh'),
}) async {
  final fixture = await _openPlayer(
    tester,
    size: size,
    textScale: textScale,
    locale: locale,
  );
  await tester.tap(find.byKey(const ValueKey('reader-aloud-engine')));
  await tester.pumpAndSettle();
  return fixture;
}
