import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/services/core/settings_page_preferences.dart';
import 'package:xxread/services/reading/reading_resume_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads existing values and enables animations migration', () async {
    SharedPreferences.setMockInitialValues({
      'enableAnimations': false,
      'enableAutoSave': false,
      'autoSaveInterval': 90,
      'enableAutoExtractCover': false,
      'enableVolumeKeyTurn': false,
      ReadingResumeService.enabledPreferenceKey: true,
      ReaderKeepScreenOnController.preferenceKey: true,
      'enableFullscreen': true,
      'enableDeveloperMode': true,
      'enableDebugLogging': true,
      'enablePerformanceMonitor': true,
      'enableMemoryStats': true,
      'showFPS': true,
    });
    final store = SharedPreferencesSettingsPagePreferencesStore(
      loadReaderTopBarStyle: () async => ReaderTopBarStyle.hidden,
    );

    final settings = await store.load();

    expect(settings.enableAutoSave, isFalse);
    expect(settings.autoSaveInterval, 90);
    expect(settings.enableAutoExtractCover, isFalse);
    expect(settings.enableVolumeKeyTurn, isFalse);
    expect(settings.autoResumeReading, isTrue);
    expect(settings.keepScreenOn, isTrue);
    expect(settings.readerTopBarStyle, ReaderTopBarStyle.hidden);
    expect(settings.enableFullscreen, isTrue);
    expect(settings.enableDeveloperMode, isTrue);
    expect(settings.enableDebugLogging, isTrue);
    expect(settings.enablePerformanceMonitor, isTrue);
    expect(settings.enableMemoryStats, isTrue);
    expect(settings.showFPS, isTrue);
    expect(
      (await SharedPreferences.getInstance()).getBool('enableAnimations'),
      isTrue,
    );
  });

  test('uses the same defaults as the settings page', () async {
    final store = SharedPreferencesSettingsPagePreferencesStore(
      loadReaderTopBarStyle: () async => ReaderTopBarStyle.reader,
    );

    final settings = await store.load();

    expect(settings.enableAutoSave, isTrue);
    expect(settings.autoSaveInterval, 30);
    expect(settings.enableAutoExtractCover, isTrue);
    expect(settings.enableVolumeKeyTurn, isTrue);
    expect(settings.autoResumeReading, isFalse);
    expect(settings.keepScreenOn, isFalse);
    expect(settings.readerTopBarStyle, ReaderTopBarStyle.reader);
    expect(settings.enableFullscreen, isFalse);
    expect(settings.enableDeveloperMode, isFalse);
    expect(settings.enableDebugLogging, isFalse);
    expect(settings.enablePerformanceMonitor, isFalse);
    expect(settings.enableMemoryStats, isFalse);
    expect(settings.showFPS, isFalse);
  });

  test('saves page-owned values and reader top bar style', () async {
    ReaderTopBarStyle? savedTopBarStyle;
    final store = SharedPreferencesSettingsPagePreferencesStore(
      saveReaderTopBarStyle: (style) async => savedTopBarStyle = style,
    );
    const settings = SettingsPagePreferences(
      enableAutoSave: false,
      keepScreenOn: true,
      autoSaveInterval: 120,
      enableAutoExtractCover: false,
      enableVolumeKeyTurn: false,
      autoResumeReading: true,
      readerTopBarStyle: ReaderTopBarStyle.floating,
      enableFullscreen: true,
      enableDeveloperMode: true,
      enableDebugLogging: true,
      enablePerformanceMonitor: true,
      enableMemoryStats: true,
      showFPS: true,
    );

    await store.save(settings);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('enableAnimations'), isTrue);
    expect(prefs.getBool('enableAutoSave'), isFalse);
    expect(prefs.getInt('autoSaveInterval'), 120);
    expect(prefs.getBool('enableAutoExtractCover'), isFalse);
    expect(prefs.getBool('enableVolumeKeyTurn'), isFalse);
    expect(prefs.getBool(ReadingResumeService.enabledPreferenceKey), isTrue);
    expect(prefs.getBool('enableFullscreen'), isTrue);
    expect(prefs.getBool('enableDeveloperMode'), isTrue);
    expect(prefs.getBool('enableDebugLogging'), isTrue);
    expect(prefs.getBool('enablePerformanceMonitor'), isTrue);
    expect(prefs.getBool('enableMemoryStats'), isTrue);
    expect(prefs.getBool('showFPS'), isTrue);
    expect(savedTopBarStyle, ReaderTopBarStyle.floating);
  });
}
