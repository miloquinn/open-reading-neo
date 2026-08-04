// 文件说明：聚合搜索页的可调参数（并发数、单源超时、书源数量上限）及其持久化。
// 技术要点：SharedPreferences 读写、取值范围校验。

import 'package:shared_preferences/shared_preferences.dart';

/// 聚合搜索的可调参数。范围过大的值会在 [BookSourceSearchSettingsStore.load]
/// 中被夹紧，避免旧版本写入的越界值影响本次会话。
class BookSourceSearchSettings {
  final int maxConcurrentSearches;
  final Duration perSourceSearchTimeout;

  /// "全部书源"范围下实际参与搜索的书源数量上限，按注册顺序取前 N 个。
  /// 书源数量很大时（用户一次性导入几千个书源的情况并不少见），不加上限会
  /// 同时打开海量网络请求，明显消耗流量和设备资源。
  final int sourceLimit;

  const BookSourceSearchSettings({
    required this.maxConcurrentSearches,
    required this.perSourceSearchTimeout,
    required this.sourceLimit,
  });

  static const BookSourceSearchSettings defaults = BookSourceSearchSettings(
    maxConcurrentSearches: 8,
    perSourceSearchTimeout: Duration(seconds: 6),
    sourceLimit: 300,
  );

  static const int minConcurrency = 1;
  static const int maxConcurrency = 32;
  static const int minTimeoutSeconds = 2;
  static const int maxTimeoutSeconds = 30;
  static const int minSourceLimit = 20;
  static const int maxSourceLimit = 2000;

  BookSourceSearchSettings copyWith({
    int? maxConcurrentSearches,
    Duration? perSourceSearchTimeout,
    int? sourceLimit,
  }) {
    return BookSourceSearchSettings(
      maxConcurrentSearches:
          maxConcurrentSearches ?? this.maxConcurrentSearches,
      perSourceSearchTimeout:
          perSourceSearchTimeout ?? this.perSourceSearchTimeout,
      sourceLimit: sourceLimit ?? this.sourceLimit,
    );
  }

  BookSourceSearchSettings _clamped() => BookSourceSearchSettings(
    maxConcurrentSearches: maxConcurrentSearches.clamp(
      minConcurrency,
      maxConcurrency,
    ),
    perSourceSearchTimeout: Duration(
      seconds: perSourceSearchTimeout.inSeconds.clamp(
        minTimeoutSeconds,
        maxTimeoutSeconds,
      ),
    ),
    sourceLimit: sourceLimit.clamp(minSourceLimit, maxSourceLimit),
  );
}

/// 聚合搜索参数的持久化存储；每台设备/账号本地生效，不参与同步。
class BookSourceSearchSettingsStore {
  const BookSourceSearchSettingsStore();

  static const String _concurrencyKey = 'book_source_search_concurrency_v1';
  static const String _timeoutSecondsKey =
      'book_source_search_timeout_seconds_v1';
  static const String _sourceLimitKey = 'book_source_search_source_limit_v1';

  Future<BookSourceSearchSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    final defaults = BookSourceSearchSettings.defaults;
    return BookSourceSearchSettings(
      maxConcurrentSearches:
          preferences.getInt(_concurrencyKey) ?? defaults.maxConcurrentSearches,
      perSourceSearchTimeout: Duration(
        seconds:
            preferences.getInt(_timeoutSecondsKey) ??
            defaults.perSourceSearchTimeout.inSeconds,
      ),
      sourceLimit: preferences.getInt(_sourceLimitKey) ?? defaults.sourceLimit,
    )._clamped();
  }

  Future<void> save(BookSourceSearchSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    final clamped = settings._clamped();
    await preferences.setInt(_concurrencyKey, clamped.maxConcurrentSearches);
    await preferences.setInt(
      _timeoutSecondsKey,
      clamped.perSourceSearchTimeout.inSeconds,
    );
    await preferences.setInt(_sourceLimitKey, clamped.sourceLimit);
  }
}
