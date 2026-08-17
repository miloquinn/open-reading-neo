// 文件说明：应用主题状态服务，负责主题模式、UI 风格、强调色持久化与旧设置迁移。
// 技术要点：ChangeNotifier、SharedPreferences、Material 3 配色、玻璃效果配置。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/utils/app_themes.dart';
import 'package:xxread/utils/glass_config.dart';
import 'package:xxread/utils/ui_style.dart';

class ThemeNotifier extends ChangeNotifier {
  static const String _themeModePrefKey = 'isDarkMode';
  static const String _uiStylePrefKey = 'ui_style_mode';
  static const String _accentColorPrefKey = 'appAccentColorV2';

  // 仅用于从旧版“双层主题 + 强调色”设置迁移。
  static const String _appThemePrefKey = 'appTheme';
  static const String _customAccentPrefKey = 'customAccentColor';
  static const String _globalAccentPrefKey = 'globalAccentColor';
  static const String _lastPresetThemePrefKey = 'last_preset_app_theme';

  ThemeMode _themeMode = ThemeMode.system;
  bool _isInitialized = false;
  Color _accentColor = AppThemes.defaultAccentColor;
  AppTheme _currentAppTheme = AppThemes.fromAccentColor(
    AppThemes.defaultAccentColor,
  );
  AppUiStyle _uiStyle = AppUiStyle.glass;

  ThemeMode get themeMode => _themeMode;
  bool get isInitialized => _isInitialized;
  Color get accentColor => _accentColor;
  AppTheme get currentAppTheme => _currentAppTheme;
  AppUiStyle get uiStyle => _uiStyle;
  bool get isGlassEffectsEnabled => _uiStyle == AppUiStyle.glass;
  bool get shouldDisableGlassEffects => _uiStyle == AppUiStyle.material3;

  ThemeNotifier() {
    _loadTheme();
  }

  void _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDarkMode = prefs.getBool(_themeModePrefKey);
    _uiStyle = appUiStyleFromStorage(prefs.getString(_uiStylePrefKey));
    await prefs.remove('disable_glass_effects');
    final storedAccentColor = prefs.getInt(_accentColorPrefKey);

    _syncGlassEffectState();
    if (prefs.getBool('enableAnimations') != true) {
      await prefs.setBool('enableAnimations', true);
    }

    if (isDarkMode == null) {
      _themeMode = ThemeMode.system;
    } else {
      _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
    }

    if (storedAccentColor != null) {
      _accentColor = Color(storedAccentColor);
    } else {
      _accentColor = _migrateLegacyAccentColor(prefs);
      await prefs.setInt(_accentColorPrefKey, _accentColor.toARGB32());
    }
    await _removeLegacyThemePreferences(prefs);
    _currentAppTheme = AppThemes.fromAccentColor(_accentColor);

    _isInitialized = true;
    notifyListeners();
  }

  void toggleTheme(bool isDarkMode) async {
    final newThemeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
    if (_themeMode == newThemeMode) return;

    _themeMode = newThemeMode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_themeModePrefKey, isDarkMode);
  }

  /// 强调色是应用配色的唯一来源，Material 3 会由它生成完整浅色/深色色板。
  Future<void> setAccentColor(Color color) async {
    if (_accentColor.toARGB32() == color.toARGB32()) return;

    _accentColor = color;
    _currentAppTheme = AppThemes.fromAccentColor(color);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentColorPrefKey, color.toARGB32());
    await _removeLegacyThemePreferences(prefs);
  }

  Color _migrateLegacyAccentColor(SharedPreferences prefs) {
    final globalAccent = prefs.getInt(_globalAccentPrefKey);
    if (globalAccent != null) return Color(globalAccent);

    final appThemeName = prefs.getString(_appThemePrefKey);
    final customAccent = prefs.getInt(_customAccentPrefKey);
    if (appThemeName == 'custom' && customAccent != null) {
      return Color(customAccent);
    }
    return AppThemes.accentColorForLegacyTheme(appThemeName);
  }

  Future<void> _removeLegacyThemePreferences(SharedPreferences prefs) async {
    await prefs.remove(_appThemePrefKey);
    await prefs.remove(_customAccentPrefKey);
    await prefs.remove(_globalAccentPrefKey);
    await prefs.remove(_lastPresetThemePrefKey);
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;

    _themeMode = mode;
    notifyListeners();
    _saveThemeMode(mode);
  }

  void _saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    if (mode == ThemeMode.system) {
      await prefs.remove(_themeModePrefKey);
    } else {
      await prefs.setBool(_themeModePrefKey, mode == ThemeMode.dark);
    }
  }

  Future<void> setUiStyle(AppUiStyle style) async {
    if (_uiStyle == style) return;
    _uiStyle = style;
    _syncGlassEffectState();
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_uiStylePrefKey, style.storageValue);
  }

  Future<void> setGlassEffectsEnabled(bool enabled) {
    return setUiStyle(enabled ? AppUiStyle.glass : AppUiStyle.material3);
  }

  void _syncGlassEffectState() {
    GlassEffectConfig.setDisableAllGlassEffects(shouldDisableGlassEffects);
    GlassEffectConfig.applyPerformanceMode(
      reduceEffects: shouldDisableGlassEffects,
    );
  }
}
