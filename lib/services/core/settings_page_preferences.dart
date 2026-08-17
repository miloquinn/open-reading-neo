// 文件说明：设置主页局部偏好快照与持久化边界，集中管理页面字段的默认值和存储键。
// 技术要点：SharedPreferences、不可变值对象、阅读器系统栏偏好委托。

import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/services/reading/reading_resume_service.dart';

class SettingsPagePreferences {
  const SettingsPagePreferences({
    this.enableAutoSave = true,
    this.keepScreenOn = false,
    this.autoSaveInterval = 30,
    this.enableAutoExtractCover = true,
    this.enableVolumeKeyTurn = true,
    this.autoResumeReading = false,
    this.readerTopBarStyle = ReaderTopBarStyle.reader,
    this.enableFullscreen = false,
    this.enableDeveloperMode = false,
    this.enableDebugLogging = false,
    this.enablePerformanceMonitor = false,
    this.enableMemoryStats = false,
    this.showFPS = false,
  });

  final bool enableAutoSave;
  final bool keepScreenOn;
  final int autoSaveInterval;
  final bool enableAutoExtractCover;
  final bool enableVolumeKeyTurn;
  final bool autoResumeReading;
  final ReaderTopBarStyle readerTopBarStyle;
  final bool enableFullscreen;
  final bool enableDeveloperMode;
  final bool enableDebugLogging;
  final bool enablePerformanceMonitor;
  final bool enableMemoryStats;
  final bool showFPS;
}

abstract interface class SettingsPagePreferencesStore {
  Future<SettingsPagePreferences> load();

  Future<void> save(SettingsPagePreferences preferences);
}

class SharedPreferencesSettingsPagePreferencesStore
    implements SettingsPagePreferencesStore {
  SharedPreferencesSettingsPagePreferencesStore({
    Future<SharedPreferences> Function()? preferences,
    Future<ReaderTopBarStyle> Function()? loadReaderTopBarStyle,
    Future<void> Function(ReaderTopBarStyle)? saveReaderTopBarStyle,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _loadReaderTopBarStyle =
           loadReaderTopBarStyle ?? ReaderSystemUiController.loadPreference,
       _saveReaderTopBarStyle =
           saveReaderTopBarStyle ?? ReaderSystemUiController.savePreference;

  final Future<SharedPreferences> Function() _preferences;
  final Future<ReaderTopBarStyle> Function() _loadReaderTopBarStyle;
  final Future<void> Function(ReaderTopBarStyle) _saveReaderTopBarStyle;

  @override
  Future<SettingsPagePreferences> load() async {
    final prefs = await _preferences();
    final readerTopBarStyle = await _loadReaderTopBarStyle();
    if (prefs.getBool('enableAnimations') != true) {
      await prefs.setBool('enableAnimations', true);
    }
    return SettingsPagePreferences(
      enableAutoSave: prefs.getBool('enableAutoSave') ?? true,
      keepScreenOn:
          prefs.getBool(ReaderKeepScreenOnController.preferenceKey) ?? false,
      autoSaveInterval: prefs.getInt('autoSaveInterval') ?? 30,
      enableAutoExtractCover: prefs.getBool('enableAutoExtractCover') ?? true,
      enableVolumeKeyTurn: prefs.getBool('enableVolumeKeyTurn') ?? true,
      autoResumeReading:
          prefs.getBool(ReadingResumeService.enabledPreferenceKey) ?? false,
      readerTopBarStyle: readerTopBarStyle,
      enableFullscreen: prefs.getBool('enableFullscreen') ?? false,
      enableDeveloperMode: prefs.getBool('enableDeveloperMode') ?? false,
      enableDebugLogging: prefs.getBool('enableDebugLogging') ?? false,
      enablePerformanceMonitor:
          prefs.getBool('enablePerformanceMonitor') ?? false,
      enableMemoryStats: prefs.getBool('enableMemoryStats') ?? false,
      showFPS: prefs.getBool('showFPS') ?? false,
    );
  }

  @override
  Future<void> save(SettingsPagePreferences preferences) async {
    final prefs = await _preferences();
    await prefs.setBool('enableAnimations', true);
    await prefs.setBool('enableAutoSave', preferences.enableAutoSave);
    await prefs.setInt('autoSaveInterval', preferences.autoSaveInterval);
    await prefs.setBool(
      'enableAutoExtractCover',
      preferences.enableAutoExtractCover,
    );
    await prefs.setBool('enableVolumeKeyTurn', preferences.enableVolumeKeyTurn);
    await prefs.setBool(
      ReadingResumeService.enabledPreferenceKey,
      preferences.autoResumeReading,
    );
    await _saveReaderTopBarStyle(preferences.readerTopBarStyle);
    await prefs.setBool('enableFullscreen', preferences.enableFullscreen);
    await prefs.setBool('enableDeveloperMode', preferences.enableDeveloperMode);
    await prefs.setBool('enableDebugLogging', preferences.enableDebugLogging);
    await prefs.setBool(
      'enablePerformanceMonitor',
      preferences.enablePerformanceMonitor,
    );
    await prefs.setBool('enableMemoryStats', preferences.enableMemoryStats);
    await prefs.setBool('showFPS', preferences.showFPS);
  }
}
