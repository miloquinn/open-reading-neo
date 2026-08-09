class SourceScriptCacheEntry {
  const SourceScriptCacheEntry({required this.value, this.expiresAt});

  final Object? value;
  final DateTime? expiresAt;
}

class SourceScriptState {
  String variable = '';
  Map<String, String> values = {};
  Map<String, String> loginInfo = {};
  Map<String, String> loginHeaders = {};
  Map<String, Object?> javaState = {};
  final Map<String, SourceScriptCacheEntry> cache = {};
  final Map<String, Object?> memoryCache = {};

  Object? readCache(String key, DateTime now) {
    final entry = cache[key];
    if (entry == null) return null;
    if (entry.expiresAt?.isBefore(now) ?? false) {
      cache.remove(key);
      return null;
    }
    return sourceScriptJsonSafe(entry.value);
  }

  void deleteCache(String key) {
    cache.remove(key);
    memoryCache.remove(key);
  }
}

Object? sourceScriptJsonSafe(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    return value.map(
      (key, item) => MapEntry('$key', sourceScriptJsonSafe(item)),
    );
  }
  if (value is Iterable) {
    return value.map(sourceScriptJsonSafe).toList(growable: false);
  }
  return '$value';
}
