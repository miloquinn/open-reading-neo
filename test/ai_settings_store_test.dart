import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/reader_core/ai/ai_service.dart';

class _MemorySecretStore implements AISecretStore {
  _MemorySecretStore({this.failRead = false, this.failWrite = false});

  final bool failRead;
  final bool failWrite;
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async {
    if (failRead) throw Exception('secret read unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw Exception('secret write unavailable');
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('migrates a legacy plaintext API key into secret storage', () async {
    SharedPreferences.setMockInitialValues({
      'reader_ai_openai_api_key_v1': 'legacy-key',
    });
    final secrets = _MemorySecretStore();
    final store = SharedPreferencesAISettingsStore(secretStore: secrets);

    final settings = await store.load(AIProviderType.openai);

    expect(settings.apiKey, 'legacy-key');
    expect(secrets.values['reader_ai_openai_api_key_v1'], 'legacy-key');
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'reader_ai_openai_api_key_v1',
      ),
      isFalse,
    );
  });

  test('prefers secure API key and removes plaintext residue', () async {
    SharedPreferences.setMockInitialValues({
      'reader_ai_openai_api_key_v1': 'stale-plaintext',
    });
    final secrets = _MemorySecretStore()
      ..values['reader_ai_openai_api_key_v1'] = 'secure-key';
    final store = SharedPreferencesAISettingsStore(secretStore: secrets);

    final settings = await store.load(AIProviderType.openai);

    expect(settings.apiKey, 'secure-key');
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        'reader_ai_openai_api_key_v1',
      ),
      isFalse,
    );
  });

  test('uses plaintext API key when secure reads are unavailable', () async {
    SharedPreferences.setMockInitialValues({
      'reader_ai_openai_api_key_v1': 'fallback-key',
    });
    final store = SharedPreferencesAISettingsStore(
      secretStore: _MemorySecretStore(failRead: true),
    );

    final settings = await store.load(AIProviderType.openai);

    expect(settings.apiKey, 'fallback-key');
  });

  test('persists normalized custom protocol settings', () async {
    final secrets = _MemorySecretStore();
    final store = SharedPreferencesAISettingsStore(secretStore: secrets);

    await store.save(
      const AIProviderSettings(
        provider: AIProviderType.custom,
        protocol: AIProtocolType.anthropic,
        apiKey: 'custom-secret',
        baseUrl: 'https://gateway.example.com/v1/messages',
        model: 'private-model',
        temperature: 0.7,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('reader_ai_provider_v1'), 'custom');
    expect(
      prefs.getString('reader_ai_custom_base_url_v1'),
      'https://gateway.example.com/v1',
    );
    expect(prefs.getString('reader_ai_custom_model_v1'), 'private-model');
    expect(prefs.getDouble('reader_ai_custom_temp_v1'), 0.7);
    expect(prefs.getString('reader_ai_custom_protocol_v1'), 'anthropic');
    expect(secrets.values['reader_ai_custom_api_key_v1'], 'custom-secret');
  });

  test('falls back to plaintext when secure writes are unavailable', () async {
    final store = SharedPreferencesAISettingsStore(
      secretStore: _MemorySecretStore(failWrite: true),
    );

    await store.save(
      const AIProviderSettings(
        provider: AIProviderType.openai,
        apiKey: 'fallback-secret',
        baseUrl: 'https://api.openai.com/v1',
        model: 'gpt-4o-mini',
        temperature: 0.7,
      ),
    );

    expect(
      (await SharedPreferences.getInstance()).getString(
        'reader_ai_openai_api_key_v1',
      ),
      'fallback-secret',
    );
  });
}
