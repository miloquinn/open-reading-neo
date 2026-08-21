import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../../utils/font_catalog_helper.dart';

/// Immutable, fully resolved font contract shared by reader measurement,
/// painting, previews and pagination caches.
///
/// Platform-default profiles resolve to an explicit preferred family. EPUB
/// rendering may still preserve a book-provided family before applying this
/// profile; TXT and book-source text consume it directly.
@immutable
class ReaderFontProfile {
  const ReaderFontProfile({
    required this.selectionId,
    required this.fontFamily,
    required this.fontFamilyFallback,
    required this.cacheSignature,
    required this.isPlatformDefault,
  });

  final String selectionId;
  final String? fontFamily;
  final List<String> fontFamilyFallback;
  final String cacheSignature;
  final bool isPlatformDefault;

  String? get preferredFamily =>
      fontFamily ??
      (fontFamilyFallback.isEmpty ? null : fontFamilyFallback.first);
}

const List<String> _androidPlatformReaderFamilies = <String>['sans-serif'];

const List<String> _windowsSimplifiedChineseReaderFamilies = <String>[
  'Microsoft YaHei',
  'Microsoft YaHei UI',
  'Segoe UI',
  'Arial',
];

const List<String> _iosSimplifiedChineseReaderFamilies = <String>[
  'PingFang SC',
  'PingFang TC',
];

const List<String> _iosTraditionalChineseReaderFamilies = <String>[
  'PingFang TC',
  'PingFang SC',
];

ReaderFontProfile resolveReaderFontProfile({
  required FontOption selection,
  Locale? locale,
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (selection.id != FontCatalog.systemId) {
    final fallbacks = List<String>.unmodifiable(selection.fallbackFamilies);
    return ReaderFontProfile(
      selectionId: selection.id,
      fontFamily: selection.family,
      fontFamilyFallback: fallbacks,
      cacheSignature: _fontProfileSignature(
        selectionId: selection.id,
        fontFamily: selection.family,
        fallbacks: fallbacks,
        platformKey: 'explicit',
      ),
      isPlatformDefault: false,
    );
  }

  if (isWeb) {
    return const ReaderFontProfile(
      selectionId: FontCatalog.systemId,
      fontFamily: null,
      fontFamilyFallback: <String>[],
      cacheSignature: 'reader-font-profile-v1:platform:web',
      isPlatformDefault: true,
    );
  }

  final resolvedPlatform = platform ?? defaultTargetPlatform;
  final families = switch (resolvedPlatform) {
    TargetPlatform.android => _androidPlatformReaderFamilies,
    TargetPlatform.iOS || TargetPlatform.macOS =>
      _usesTraditionalChinese(locale)
          ? _iosTraditionalChineseReaderFamilies
          : _iosSimplifiedChineseReaderFamilies,
    TargetPlatform.windows => _windowsSimplifiedChineseReaderFamilies,
    TargetPlatform.linux => const <String>['sans-serif'],
    TargetPlatform.fuchsia => const <String>[],
  };
  final platformKey = switch (resolvedPlatform) {
    TargetPlatform.android => 'android-generic-sans',
    TargetPlatform.iOS =>
      _usesTraditionalChinese(locale) ? 'ios-pingfang-tc' : 'ios-pingfang-sc',
    TargetPlatform.macOS =>
      _usesTraditionalChinese(locale)
          ? 'macos-pingfang-tc'
          : 'macos-pingfang-sc',
    TargetPlatform.windows => 'windows-microsoft-yahei',
    TargetPlatform.linux => 'linux-generic-sans',
    TargetPlatform.fuchsia => 'fuchsia-engine-default',
  };
  final primaryFamily = families.isEmpty ? null : families.first;
  final fallbacks = List<String>.unmodifiable(
    families.isEmpty ? const <String>[] : families.skip(1),
  );
  return ReaderFontProfile(
    selectionId: FontCatalog.systemId,
    fontFamily: primaryFamily,
    fontFamilyFallback: fallbacks,
    cacheSignature: _fontProfileSignature(
      selectionId: FontCatalog.systemId,
      fontFamily: primaryFamily,
      fallbacks: fallbacks,
      platformKey: platformKey,
    ),
    isPlatformDefault: true,
  );
}

bool _usesTraditionalChinese(Locale? locale) {
  if (locale?.languageCode.toLowerCase() != 'zh') return false;
  final scriptCode = locale?.scriptCode?.toLowerCase();
  final countryCode = locale?.countryCode?.toUpperCase();
  return scriptCode == 'hant' ||
      countryCode == 'TW' ||
      countryCode == 'HK' ||
      countryCode == 'MO';
}

String _fontProfileSignature({
  required String selectionId,
  required String? fontFamily,
  required List<String> fallbacks,
  required String platformKey,
}) =>
    'reader-font-profile-v1:$platformKey:$selectionId:'
    '${fontFamily ?? '-'}:${fallbacks.join('>')}';
