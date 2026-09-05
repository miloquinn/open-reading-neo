import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';

void main() {
  test(
    'new connections keep typography local and preserve explicit choices',
    () async {
      final store = SecureSyncConfigStore(
        secretStorage: _MemorySecrets(),
        preferences: _MemoryPreferences(),
      );
      expect((await store.readScope()).readerSettings, isFalse);
      await store.saveScope(const WebDavSyncScope(readerSettings: true));
      expect((await store.readScope()).readerSettings, isTrue);
      expect(await store.readAutoResume(), isTrue);
      await store.saveAutoResume(false);
      expect(await store.readAutoResume(), isFalse);
      await store.clear();
      expect(await store.readAutoResume(), isTrue);
    },
  );

  test(
    'legacy connection without scope keeps its typography preference',
    () async {
      final store = SecureSyncConfigStore(
        secretStorage: _MemorySecrets(),
        preferences: _MemoryPreferences(),
      );
      await store.save(
        const WebDavSyncConfiguration(
          serverUrl: 'https://dav.example.com/',
          username: 'reader',
        ),
        'password',
      );
      expect((await store.readScope()).readerSettings, isTrue);
    },
  );

  test('password is stored only in secure storage', () async {
    final secrets = _MemorySecrets();
    final preferences = _MemoryPreferences();
    final store = SecureSyncConfigStore(
      secretStorage: secrets,
      preferences: preferences,
    );
    const configuration = WebDavSyncConfiguration(
      serverUrl: 'https://dav.example.com/',
      username: 'reader',
    );

    await store.save(configuration, 'application-password');

    expect(secrets.values.values, contains('application-password'));
    expect(
      preferences.values.values.any(
        (value) => value.contains('application-password'),
      ),
      isFalse,
    );
    expect((await store.readCredentials())!.password, 'application-password');
  });

  test('secure storage failure has no insecure fallback', () async {
    final preferences = _MemoryPreferences();
    final store = SecureSyncConfigStore(
      secretStorage: _FailingSecrets(),
      preferences: preferences,
    );

    await expectLater(
      store.save(
        const WebDavSyncConfiguration(
          serverUrl: 'https://dav.example.com/',
          username: 'reader',
        ),
        'secret',
      ),
      throwsA(
        isA<WebDavSyncFailure>().having(
          (error) => error.code,
          'code',
          WebDavSyncErrorCode.secureStorage,
        ),
      ),
    );
    expect(preferences.values, isEmpty);
  });

  test('HTTP requires explicit private-network opt in', () {
    expect(
      () => validateWebDavConfiguration(
        const WebDavSyncConfiguration(
          serverUrl: 'http://dav.example.com',
          username: 'reader',
          allowInsecurePrivateHttp: true,
        ),
      ),
      throwsA(isA<WebDavSyncFailure>()),
    );
    expect(
      validateWebDavConfiguration(
        const WebDavSyncConfiguration(
          serverUrl: 'http://192.168.1.2',
          username: 'reader',
          allowInsecurePrivateHttp: true,
        ),
      ).host,
      '192.168.1.2',
    );
  });

  test(
    'new-book upload policy is explicit and cleared with configuration',
    () async {
      final preferences = _MemoryPreferences();
      final store = SecureSyncConfigStore(
        secretStorage: _MemorySecrets(),
        preferences: preferences,
      );

      expect(
        await store.readNewBookUploadPolicy(),
        WebDavNewBookUploadPolicy.askEveryTime,
      );
      await store.saveNewBookUploadPolicy(WebDavNewBookUploadPolicy.automatic);
      expect(
        await store.readNewBookUploadPolicy(),
        WebDavNewBookUploadPolicy.automatic,
      );

      await store.clear();
      expect(
        await store.readNewBookUploadPolicy(),
        WebDavNewBookUploadPolicy.askEveryTime,
      );
    },
  );

  test(
    'legacy scope enables portable settings without exposing private data',
    () async {
      final preferences = _MemoryPreferences()
        ..values['webdav_sync_scope_v1'] =
            '{"books":true,"progress":true,"bookmarks":true}';
      final store = SecureSyncConfigStore(
        secretStorage: _MemorySecrets(),
        preferences: preferences,
      );

      final scope = await store.readScope();
      expect(scope.readerSettings, isTrue);
      expect(scope.notes, isFalse);
      expect(scope.replaceRules, isFalse);
    },
  );
}

class _MemorySecrets implements SyncSecretStorage {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _FailingSecrets implements SyncSecretStorage {
  @override
  Future<void> delete(String key) async => throw StateError('unavailable');

  @override
  Future<String?> read(String key) async => throw StateError('unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('unavailable');
}

class _MemoryPreferences implements SyncPreferences {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
