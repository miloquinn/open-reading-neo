import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class MemberTokenStore {
  Future<String?> readAccessToken();
  Future<String?> readRefreshToken();
  Future<bool> readMfaPending();
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    bool mfaPending = false,
  });
  Future<void> clear();
}

abstract interface class PendingDeviceAuthorizationStore {
  Future<String?> read();
  Future<void> save(String payload);
  Future<void> clear();
}

class SecurePendingDeviceAuthorizationStore
    implements PendingDeviceAuthorizationStore {
  SecurePendingDeviceAuthorizationStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'open_reading.account.pending_device_authorization';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String payload) async {
    try {
      await _storage.write(key: _key, value: payload);
    } catch (_) {
      // In-memory polling remains available when secure storage is absent.
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Nothing to clear on hosts without secure storage.
    }
  }
}

class SecureMemberTokenStore implements MemberTokenStore {
  SecureMemberTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _accessTokenKey = 'open_reading.account.access_token';
  static const _refreshTokenKey = 'open_reading.account.refresh_token';
  static const _mfaPendingKey = 'open_reading.account.mfa_pending';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readAccessToken() => _storage.read(key: _accessTokenKey);

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _refreshTokenKey);

  @override
  Future<bool> readMfaPending() async =>
      await _storage.read(key: _mfaPendingKey) == 'true';

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    bool mfaPending = false,
  }) async {
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    try {
      await _storage.write(key: _accessTokenKey, value: accessToken);
      await _storage.write(
        key: _mfaPendingKey,
        value: mfaPending ? 'true' : 'false',
      );
    } catch (_) {
      await _storage.delete(key: _refreshTokenKey);
      await _storage.delete(key: _accessTokenKey);
      await _storage.delete(key: _mfaPendingKey);
      rethrow;
    }
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _accessTokenKey);
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _mfaPendingKey);
  }
}
