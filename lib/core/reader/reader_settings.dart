import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_layout.dart';
import 'reader_margin_settings.dart';
import 'reader_tap_zones.dart';

enum ReaderTextAlignment { natural, justified }

/// Converts the reader's 0–100 brightness setting into an opaque gray.
///
/// Dark reader themes use the natural scale: 0 is #000000 and 100 is
/// #FFFFFF. Light reader themes reverse it so 100 is #000000 and 0 is
/// #FFFFFF, matching the direction users expect while reading on paper-like
/// backgrounds.
Color readerTextColorForBrightness(int brightness, {required bool isDarkMode}) {
  final brightnessChannel =
      (brightness.clamp(
                ReaderSettings.minTextBrightness,
                ReaderSettings.maxTextBrightness,
              ) *
              255 /
              ReaderSettings.maxTextBrightness)
          .round();
  final channel = isDarkMode ? brightnessChannel : 255 - brightnessChannel;
  return Color.fromARGB(255, channel, channel, channel);
}

int effectiveReaderTextBrightness({
  required int brightness,
  required bool dimInDarkMode,
  required bool isDarkMode,
}) => isDarkMode && dimInDarkMode ? 70 : brightness;

int normalizeReaderFontWeight(num value) => ((value / 100).round() * 100).clamp(
  ReaderSettings.minFontWeight,
  ReaderSettings.maxFontWeight,
);

FontWeight readerFontWeightFromValue(int value) =>
    FontWeight.values[(normalizeReaderFontWeight(value) ~/ 100) - 1];

/// Explicitly sets the `wght` axis for variable reader fonts instead of
/// relying on [FontWeight] alone. Impeller (iOS's default renderer) doesn't
/// reliably resolve a `TextStyle.fontWeight` to a registered variable font's
/// axis on its own — without this, weight changes silently no-op and glyphs
/// missing from whichever default instance gets picked fall back to a
/// different font, producing visibly mismatched glyph sizes mid-paragraph.
List<FontVariation> readerFontVariationsFromValue(
  int value, {
  required bool supportsVariableWeight,
  int? variableWeightMin,
  int? variableWeightMax,
}) {
  if (!supportsVariableWeight) return const <FontVariation>[];
  final normalized = normalizeReaderFontWeight(value);
  final clamped = normalized.clamp(
    variableWeightMin ?? normalized,
    variableWeightMax ?? normalized,
  );
  return <FontVariation>[FontVariation('wght', clamped.toDouble())];
}

@immutable
class ReaderSettings {
  static const double defaultFontSize = 19;

  /// Text brightness uses the active reader theme direction:
  /// dark: 0 is black and 100 is white; light: 0 is white and 100 is black.
  static const int minTextBrightness = 0;
  static const int maxTextBrightness = 100;
  static const int defaultTextBrightness = 100;
  static const bool defaultDimTextInDarkMode = true;
  static const int minFontWeight = 300;
  static const int maxFontWeight = 700;
  static const int defaultFontWeight = 400;
  static const double defaultLineHeight = 1.75;
  static const double minLetterSpacing = 0;
  static const double maxLetterSpacing = 1.2;
  static const double defaultLetterSpacing = 0;
  static const ReaderTextAlignment defaultTextAlignment =
      ReaderTextAlignment.natural;
  static const double defaultHorizontalMargin = 18;
  static const int defaultFirstLineIndent = 2;
  static const int defaultParagraphSpacing = 0;
  static const String defaultThemeId = 'day';
  static const ReaderPageMode defaultPageMode = ReaderPageMode.horizontalSlide;
  static const bool defaultTabletTwoPageEnabled = true;

  const ReaderSettings({
    required this.fontSize,
    this.textBrightness = defaultTextBrightness,
    this.dimTextInDarkMode = defaultDimTextInDarkMode,
    this.fontWeight = defaultFontWeight,
    required this.lineHeight,
    this.letterSpacing = defaultLetterSpacing,
    this.textAlignment = defaultTextAlignment,
    required this.horizontalMargin,
    required this.topMargin,
    required this.bottomMargin,
    required this.themeId,
    required this.pageMode,
    this.firstLineIndent = defaultFirstLineIndent,
    this.paragraphSpacing = defaultParagraphSpacing,
    this.pullBookmarkEnabled = false,
    this.tapPageAnimationEnabled = true,
    this.tabletTwoPageEnabled = defaultTabletTwoPageEnabled,
  });

  final double fontSize;
  final int textBrightness;
  final bool dimTextInDarkMode;
  final int fontWeight;
  final double lineHeight;
  final double letterSpacing;
  final ReaderTextAlignment textAlignment;
  final double horizontalMargin;
  final double topMargin;
  final double bottomMargin;
  final String themeId;
  final ReaderPageMode pageMode;
  final int firstLineIndent;
  final int paragraphSpacing;
  final bool pullBookmarkEnabled;
  final bool tapPageAnimationEnabled;
  final bool tabletTwoPageEnabled;

  ReaderSettings copyWith({
    double? fontSize,
    int? textBrightness,
    bool? dimTextInDarkMode,
    int? fontWeight,
    double? lineHeight,
    double? letterSpacing,
    ReaderTextAlignment? textAlignment,
    double? horizontalMargin,
    double? topMargin,
    double? bottomMargin,
    String? themeId,
    ReaderPageMode? pageMode,
    int? firstLineIndent,
    int? paragraphSpacing,
    bool? pullBookmarkEnabled,
    bool? tapPageAnimationEnabled,
    bool? tabletTwoPageEnabled,
  }) {
    return ReaderSettings(
      fontSize: (fontSize ?? this.fontSize).clamp(14, 32),
      textBrightness: (textBrightness ?? this.textBrightness).clamp(
        minTextBrightness,
        maxTextBrightness,
      ),
      dimTextInDarkMode: dimTextInDarkMode ?? this.dimTextInDarkMode,
      fontWeight: normalizeReaderFontWeight(fontWeight ?? this.fontWeight),
      lineHeight: (lineHeight ?? this.lineHeight).clamp(1.4, 2.1),
      letterSpacing: (letterSpacing ?? this.letterSpacing).clamp(
        minLetterSpacing,
        maxLetterSpacing,
      ),
      textAlignment: textAlignment ?? this.textAlignment,
      horizontalMargin: (horizontalMargin ?? this.horizontalMargin).clamp(
        ReaderMarginSettings.horizontalMin,
        ReaderMarginSettings.horizontalMax,
      ),
      topMargin: (topMargin ?? this.topMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      ),
      bottomMargin: (bottomMargin ?? this.bottomMargin).clamp(
        ReaderMarginSettings.min,
        ReaderMarginSettings.max,
      ),
      themeId: themeId ?? this.themeId,
      pageMode: pageMode ?? this.pageMode,
      firstLineIndent: (firstLineIndent ?? this.firstLineIndent).clamp(0, 4),
      paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing).clamp(0, 2),
      pullBookmarkEnabled: pullBookmarkEnabled ?? this.pullBookmarkEnabled,
      tapPageAnimationEnabled:
          tapPageAnimationEnabled ?? this.tapPageAnimationEnabled,
      tabletTwoPageEnabled: tabletTwoPageEnabled ?? this.tabletTwoPageEnabled,
    );
  }
}

class ReaderSettingsStore {
  static const fontSizeKey = 'native_reader_font_size';
  static const textBrightnessKey = 'native_reader_text_brightness';
  static const _textBrightnessThemeRelativeVersionKey =
      'native_reader_text_brightness_theme_relative_v1';
  static const dimTextInDarkModeKey = 'native_reader_dim_text_in_dark_mode';
  static const fontWeightKey = 'native_reader_font_weight';
  static const lineHeightKey = 'native_reader_line_height';
  static const letterSpacingKey = 'native_reader_letter_spacing';
  static const textAlignmentKey = 'native_reader_text_alignment';
  static const horizontalMarginKey = 'native_reader_horizontal_margin';
  static const topMarginKey = 'native_reader_top_margin';
  static const bottomMarginKey = 'native_reader_bottom_margin';
  static const legacyVerticalMarginKey = 'native_reader_vertical_margin';
  static const themeKey = 'native_reader_theme';
  static const pageModeKey = 'native_reader_page_mode';
  static const firstLineIndentKey = 'native_reader_first_line_indent';
  static const paragraphSpacingKey = 'native_reader_paragraph_spacing';
  static const _legacyPageTurnStyleKey = 'native_reader_page_turn_style';
  static const pullBookmarkKey = 'reader_pull_bookmark_enabled';
  static const tapPageAnimationKey = 'reader_tap_page_animation_enabled';
  static const tabletTwoPageKey = 'reader_tablet_two_page_enabled';
  static const scrollByChapterKey = 'native_reader_scroll_by_chapter';
  static const txtChapterTitlePageKey =
      'native_reader_txt_chapter_title_page_enabled';
  static const tapZonesKey = 'reader_tap_zones_v1';
  static const legacyBookSourceLineHeightKey = 'book_source_reader_line_height';

  const ReaderSettingsStore();

  Future<String> loadThemeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(themeKey) ?? ReaderSettings.defaultThemeId;
  }

  Future<void> saveThemeId(String themeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(themeKey, themeId);
  }

  Future<ReaderSettings> load({
    ReaderPageMode fallbackPageMode = ReaderSettings.defaultPageMode,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final storedTopMargin = prefs.getDouble(topMarginKey);
    final storedBottomMargin = prefs.getDouble(bottomMarginKey);
    final margins = ReaderMarginSettings.fromStored(
      top: storedTopMargin,
      bottom: storedBottomMargin,
      legacyVertical: prefs.getDouble(legacyVerticalMarginKey),
    );
    if (storedTopMargin == null || storedBottomMargin == null) {
      await Future.wait([
        prefs.setDouble(topMarginKey, margins.top),
        prefs.setDouble(bottomMarginKey, margins.bottom),
      ]);
    }
    if (prefs.containsKey(_legacyPageTurnStyleKey)) {
      await prefs.remove(_legacyPageTurnStyleKey);
    }
    final storedTextBrightness = prefs.getInt(textBrightnessKey);
    final hasThemeRelativeBrightness =
        prefs.getBool(_textBrightnessThemeRelativeVersionKey) ?? false;
    final textBrightness = storedTextBrightness == null
        ? ReaderSettings.defaultTextBrightness
        : hasThemeRelativeBrightness
        ? storedTextBrightness
        : ReaderSettings.maxTextBrightness - storedTextBrightness;
    if (!hasThemeRelativeBrightness) {
      await Future.wait([
        if (storedTextBrightness != null)
          prefs.setInt(textBrightnessKey, textBrightness),
        prefs.setBool(_textBrightnessThemeRelativeVersionKey, true),
      ]);
    }

    return ReaderSettings(
      fontSize: (prefs.getDouble(fontSizeKey) ?? ReaderSettings.defaultFontSize)
          .clamp(14, 32),
      textBrightness: textBrightness.clamp(
        ReaderSettings.minTextBrightness,
        ReaderSettings.maxTextBrightness,
      ),
      dimTextInDarkMode:
          prefs.getBool(dimTextInDarkModeKey) ??
          ReaderSettings.defaultDimTextInDarkMode,
      fontWeight: normalizeReaderFontWeight(
        prefs.getInt(fontWeightKey) ?? ReaderSettings.defaultFontWeight,
      ),
      lineHeight:
          (prefs.getDouble(lineHeightKey) ??
                  prefs.getDouble(legacyBookSourceLineHeightKey) ??
                  ReaderSettings.defaultLineHeight)
              .clamp(1.4, 2.1),
      letterSpacing:
          (prefs.getDouble(letterSpacingKey) ??
                  ReaderSettings.defaultLetterSpacing)
              .clamp(
                ReaderSettings.minLetterSpacing,
                ReaderSettings.maxLetterSpacing,
              ),
      textAlignment: ReaderTextAlignment.values.firstWhere(
        (alignment) => alignment.name == prefs.getString(textAlignmentKey),
        orElse: () => ReaderSettings.defaultTextAlignment,
      ),
      horizontalMargin:
          (prefs.getDouble(horizontalMarginKey) ??
                  ReaderSettings.defaultHorizontalMargin)
              .clamp(
                ReaderMarginSettings.horizontalMin,
                ReaderMarginSettings.horizontalMax,
              ),
      topMargin: margins.top,
      bottomMargin: margins.bottom,
      themeId: prefs.getString(themeKey) ?? ReaderSettings.defaultThemeId,
      pageMode: readerPageModeFromName(
        prefs.getString(pageModeKey),
        fallback: fallbackPageMode,
      ),
      firstLineIndent:
          (prefs.getInt(firstLineIndentKey) ??
                  ReaderSettings.defaultFirstLineIndent)
              .clamp(0, 4),
      paragraphSpacing:
          (prefs.getInt(paragraphSpacingKey) ??
                  ReaderSettings.defaultParagraphSpacing)
              .clamp(0, 2),
      pullBookmarkEnabled: prefs.getBool(pullBookmarkKey) ?? false,
      tapPageAnimationEnabled: prefs.getBool(tapPageAnimationKey) ?? true,
      tabletTwoPageEnabled:
          prefs.getBool(tabletTwoPageKey) ??
          ReaderSettings.defaultTabletTwoPageEnabled,
    );
  }

  Future<void> save(ReaderSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble(fontSizeKey, settings.fontSize),
      prefs.setInt(textBrightnessKey, settings.textBrightness),
      prefs.setBool(_textBrightnessThemeRelativeVersionKey, true),
      prefs.setBool(dimTextInDarkModeKey, settings.dimTextInDarkMode),
      prefs.setInt(fontWeightKey, settings.fontWeight),
      prefs.setDouble(lineHeightKey, settings.lineHeight),
      prefs.setDouble(letterSpacingKey, settings.letterSpacing),
      prefs.setString(textAlignmentKey, settings.textAlignment.name),
      prefs.setDouble(horizontalMarginKey, settings.horizontalMargin),
      prefs.setDouble(topMarginKey, settings.topMargin),
      prefs.setDouble(bottomMarginKey, settings.bottomMargin),
      prefs.setString(themeKey, settings.themeId),
      prefs.setString(pageModeKey, settings.pageMode.name),
      prefs.setInt(firstLineIndentKey, settings.firstLineIndent),
      prefs.setInt(paragraphSpacingKey, settings.paragraphSpacing),
      prefs.setBool(pullBookmarkKey, settings.pullBookmarkEnabled),
      prefs.setBool(tapPageAnimationKey, settings.tapPageAnimationEnabled),
      prefs.setBool(tabletTwoPageKey, settings.tabletTwoPageEnabled),
    ]);
  }

  Future<bool> loadScrollByChapter() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(scrollByChapterKey) ?? false;
  }

  Future<void> saveScrollByChapter(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(scrollByChapterKey, value);
  }

  Future<bool> loadTxtChapterTitlePageEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(txtChapterTitlePageKey) ?? true;
  }

  Future<void> saveTxtChapterTitlePageEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(txtChapterTitlePageKey, value);
  }

  Future<ReaderTapZones> loadTapZones() async {
    final prefs = await SharedPreferences.getInstance();
    return ReaderTapZones.decode(prefs.getString(tapZonesKey));
  }

  Future<void> saveTapZones(ReaderTapZones zones) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(tapZonesKey, zones.encode());
  }
}
