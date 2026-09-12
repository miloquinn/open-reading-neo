import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/reader_aloud_controller.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/cloud_tts_settings_page.dart';
import 'package:xxread/services/reader_aloud_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('blank API key keeps the saved key when settings are saved', (
    tester,
  ) async {
    final fixture = await _openSettings(
      tester,
      store: _MemorySettingsStore(apiKey: 'saved-key'),
    );
    addTearDown(fixture.dispose);

    await _scrollTo(tester, const ValueKey('cloud-tts-voice'));
    await tester.enterText(
      find.byKey(const ValueKey('cloud-tts-voice')),
      'nova',
    );
    await tester.tap(find.byKey(const ValueKey('cloud-tts-save')));
    await tester.pumpAndSettle();

    expect(fixture.store.apiKey, 'saved-key');
    expect(fixture.store.writeApiKeyCalls, 0);
    expect(fixture.store.clearApiKeyCalls, 0);
    expect(fixture.store.settings.voice, 'nova');
    expect(find.text('Open cloud settings'), findsOneWidget);
  });

  testWidgets('removing a saved key is deferred until save', (tester) async {
    final fixture = await _openSettings(
      tester,
      store: _MemorySettingsStore(apiKey: 'saved-key'),
    );
    addTearDown(fixture.dispose);

    final remove = find.text('Remove saved key');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();

    expect(fixture.store.apiKey, 'saved-key');
    expect(fixture.store.clearApiKeyCalls, 0);

    await tester.tap(find.byKey(const ValueKey('cloud-tts-save')));
    await tester.pumpAndSettle();

    expect(fixture.store.apiKey, isNull);
    expect(fixture.store.clearApiKeyCalls, 1);
  });

  testWidgets(
    'cancelling a pending key removal leaves the saved key unchanged',
    (tester) async {
      final fixture = await _openSettings(
        tester,
        store: _MemorySettingsStore(apiKey: 'saved-key'),
      );
      addTearDown(fixture.dispose);

      final remove = find.text('Remove saved key');
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('floating-subpage-back')));
      await tester.pumpAndSettle();

      expect(fixture.store.apiKey, 'saved-key');
      expect(fixture.store.clearApiKeyCalls, 0);
      expect(fixture.store.saveSettingsCalls, 0);
    },
  );

  testWidgets('save failure keeps edits in the form and permits retry', (
    tester,
  ) async {
    final store = _MemorySettingsStore(
      apiKey: 'saved-key',
      settingsFailuresRemaining: 1,
    );
    final fixture = await _openSettings(tester, store: store);
    addTearDown(fixture.dispose);

    await _scrollTo(tester, const ValueKey('cloud-tts-model'));
    await tester.enterText(
      find.byKey(const ValueKey('cloud-tts-model')),
      'voice-model-next',
    );
    await _scrollTo(tester, const ValueKey('cloud-tts-voice'));
    await tester.enterText(
      find.byKey(const ValueKey('cloud-tts-voice')),
      'coral',
    );
    await tester.tap(find.byKey(const ValueKey('cloud-tts-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not finish saving'), findsOneWidget);
    expect(find.text('voice-model-next'), findsOneWidget);
    expect(find.text('coral'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cloud-tts-save')).hitTestable(),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('cloud-tts-save')));
    await tester.pumpAndSettle();

    expect(store.saveSettingsCalls, 2);
    expect(store.settings.model, 'voice-model-next');
    expect(store.settings.voice, 'coral');
    expect(find.text('Open cloud settings'), findsOneWidget);
  });

  testWidgets('invalid service URL shows validation and performs no writes', (
    tester,
  ) async {
    final fixture = await _openSettings(tester);
    addTearDown(fixture.dispose);

    await tester.enterText(
      find.byKey(const ValueKey('cloud-tts-url')),
      'http://tts.example.com/v1',
    );
    await tester.tap(find.byKey(const ValueKey('cloud-tts-save')));
    await tester.pump();

    expect(find.textContaining('Use a valid HTTPS URL'), findsOneWidget);
    expect(fixture.store.saveSettingsCalls, 0);
    expect(fixture.store.writeApiKeyCalls, 0);
    expect(fixture.store.clearApiKeyCalls, 0);
  });

  testWidgets('save stays hit-testable above the keyboard on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    final fixture = await _openSettings(tester, textScale: 1.4);
    addTearDown(fixture.dispose);
    await _scrollTo(tester, const ValueKey('cloud-tts-url'));
    await tester.showKeyboard(find.byKey(const ValueKey('cloud-tts-url')));
    await tester.pumpAndSettle();

    final save = find.byKey(const ValueKey('cloud-tts-save'));
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.getRect(save).bottom, lessThanOrEqualTo(568 - 240));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _scrollTo(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

class _SettingsFixture {
  const _SettingsFixture({
    required this.store,
    required this.service,
    required this.system,
  });

  final _MemorySettingsStore store;
  final ReaderAloudService service;
  final _FakeAdjustableEngine system;

  void dispose() {
    service.dispose();
    system.dispose();
  }
}

Future<_SettingsFixture> _openSettings(
  WidgetTester tester, {
  _MemorySettingsStore? store,
  double textScale = 1,
}) async {
  final actualStore = store ?? _MemorySettingsStore();
  final system = _FakeAdjustableEngine();
  final service = ReaderAloudService(
    systemEngine: system,
    settingsStore: actualStore,
    cloudClient: _FakeCloudClient(),
    bytesPlayer: _FakeBytesPlayer(),
  );

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => CloudTtsSettingsPage(service: service),
                ),
              ),
              child: const Text('Open cloud settings'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open cloud settings'));
  await tester.pumpAndSettle();
  return _SettingsFixture(store: actualStore, service: service, system: system);
}

class _MemorySettingsStore implements ReaderAloudCloudSettingsStore {
  _MemorySettingsStore({this.apiKey, this.settingsFailuresRemaining = 0});

  ReaderAloudEngineType engineType = ReaderAloudEngineType.system;
  ReaderAloudCloudSettings settings = const ReaderAloudCloudSettings();
  String? apiKey;
  int settingsFailuresRemaining;
  int saveSettingsCalls = 0;
  int writeApiKeyCalls = 0;
  int clearApiKeyCalls = 0;

  @override
  Future<void> clearApiKey() async {
    clearApiKeyCalls++;
    apiKey = null;
  }

  @override
  Future<ReaderAloudEngineType> loadEngineType() async => engineType;

  @override
  Future<ReaderAloudCloudSettings> loadSettings() async => settings;

  @override
  Future<String?> readApiKey() async => apiKey;

  @override
  Future<void> saveEngineType(ReaderAloudEngineType type) async {
    engineType = type;
  }

  @override
  Future<void> saveSettings(ReaderAloudCloudSettings settings) async {
    saveSettingsCalls++;
    if (settingsFailuresRemaining > 0) {
      settingsFailuresRemaining--;
      throw StateError('settings write failed');
    }
    this.settings = settings;
  }

  @override
  Future<void> writeApiKey(String apiKey) async {
    writeApiKeyCalls++;
    this.apiKey = apiKey;
  }
}

class _FakeAdjustableEngine extends ChangeNotifier
    implements ReaderAloudAdjustableEngine {
  @override
  int get currentPosition => 0;

  @override
  bool get isPaused => false;

  @override
  bool get isPlaying => false;

  @override
  double get speechRate => 0.5;

  @override
  double get speechVolume => 1;

  @override
  Future<void> pause() async {}

  @override
  Future<void> speak(String text) async {}

  @override
  Future<void> stop() async {}
}

class _FakeCloudClient implements ReaderAloudCloudClient {
  @override
  Future<Uint8List> synthesize({
    required ReaderAloudCloudSettings settings,
    required String apiKey,
    required String text,
    required double speed,
  }) async => Uint8List(0);
}

class _FakeBytesPlayer extends ChangeNotifier
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
