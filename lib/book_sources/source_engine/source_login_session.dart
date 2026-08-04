import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SourceLoginSession {
  const SourceLoginSession({
    this.loginInfo = const {},
    this.loginHeaders = const {},
  });

  final Map<String, String> loginInfo;
  final Map<String, String> loginHeaders;

  Map<String, Object?> toJson() => {
    'loginInfo': loginInfo,
    'loginHeaders': loginHeaders,
  };

  factory SourceLoginSession.fromJson(Object? value) {
    if (value is! Map) return const SourceLoginSession();
    return SourceLoginSession(
      loginInfo: _stringMap(value['loginInfo']),
      loginHeaders: _stringMap(value['loginHeaders']),
    );
  }
}

abstract interface class SourceLoginSessionStore {
  Future<SourceLoginSession> read(String sourceId);

  Future<void> write(String sourceId, SourceLoginSession session);

  Future<void> clear(String sourceId);
}

class SecureSourceLoginSessionStore implements SourceLoginSessionStore {
  SecureSourceLoginSessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'open_reading.source_session.';
  final FlutterSecureStorage _storage;

  String _key(String sourceId) => '$_prefix$sourceId';

  @override
  Future<SourceLoginSession> read(String sourceId) async {
    final raw = await _storage.read(key: _key(sourceId));
    if (raw == null || raw.trim().isEmpty) return const SourceLoginSession();
    try {
      return SourceLoginSession.fromJson(jsonDecode(raw));
    } on FormatException {
      return const SourceLoginSession();
    }
  }

  @override
  Future<void> write(String sourceId, SourceLoginSession session) {
    return _storage.write(
      key: _key(sourceId),
      value: jsonEncode(session.toJson()),
    );
  }

  @override
  Future<void> clear(String sourceId) => _storage.delete(key: _key(sourceId));
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return Map.unmodifiable({
    for (final entry in value.entries) '${entry.key}': '${entry.value ?? ''}',
  });
}
