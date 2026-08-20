// 文件说明：整页图片阅读器（漫画/PDF 共用）的专属设置：阅读方向与页面背景。
// 技术要点：阅读方向按书持久化（日漫从右到左与普通 PDF 从左到右并存），
// 页面背景全局一份；SharedPreferences 存储，解码失败回退默认值。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 图片阅读方式：纵向连续滚动，或左右整页翻阅。
enum ImageReaderDirection {
  vertical,
  ltr,
  rtl;

  static ImageReaderDirection fromName(
    String? name, {
    ImageReaderDirection fallback = ImageReaderDirection.ltr,
  }) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }
}

/// 页面外围（信箱区）背景色；页面本体仍由图片内容决定。
enum ImageReaderBackground {
  black(Color(0xFF000000)),
  gray(Color(0xFF424242)),
  white(Color(0xFFFFFFFF));

  const ImageReaderBackground(this.color);

  final Color color;

  /// 背景为浅色时，加载指示与破图占位需要换成深色前景。
  bool get isLight => this == white;

  static ImageReaderBackground fromName(String? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return black;
  }
}

/// 图片阅读器设置存取；阅读方式可按书覆盖，页面背景全局共享。
class PagedImageReaderSettingsStore {
  const PagedImageReaderSettingsStore();

  static const directionOverridesKey = 'image_reader_direction_overrides_v1';
  static const backgroundKey = 'image_reader_background_v1';

  Future<ImageReaderDirection> loadDirection(
    int? bookId, {
    ImageReaderDirection fallback = ImageReaderDirection.ltr,
  }) async {
    if (bookId == null) return fallback;
    return loadDirectionForKey('$bookId', fallback: fallback);
  }

  Future<ImageReaderDirection> loadDirectionForKey(
    String? key, {
    ImageReaderDirection fallback = ImageReaderDirection.ltr,
  }) async {
    if (key == null || key.isEmpty) return fallback;
    final overrides = await _loadOverrides();
    return ImageReaderDirection.fromName(overrides[key], fallback: fallback);
  }

  Future<void> saveDirection(
    int? bookId,
    ImageReaderDirection direction,
  ) async {
    if (bookId == null) return;
    await saveDirectionForKey('$bookId', direction);
  }

  Future<void> saveDirectionForKey(
    String? key,
    ImageReaderDirection direction,
  ) async {
    if (key == null || key.isEmpty) return;
    final overrides = await _loadOverrides();
    overrides[key] = direction.name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(directionOverridesKey, jsonEncode(overrides));
  }

  Future<ImageReaderBackground> loadBackground() async {
    final prefs = await SharedPreferences.getInstance();
    return ImageReaderBackground.fromName(prefs.getString(backgroundKey));
  }

  Future<void> saveBackground(ImageReaderBackground background) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(backgroundKey, background.name);
  }

  Future<Map<String, String>> _loadOverrides() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(directionOverridesKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return <String, String>{
        for (final entry in decoded.entries)
          if (entry.value is String) '${entry.key}': entry.value as String,
      };
    } on FormatException {
      return <String, String>{};
    }
  }
}
