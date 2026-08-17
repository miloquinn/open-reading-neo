// 文件说明：AI 提供商配置与 API Key 持久化边界。
// 技术要点：SharedPreferences、Flutter Secure Storage、明文迁移、无 keyring 平台回退。

part of 'ai_service.dart';

abstract interface class AISecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

class FlutterSecureAISecretStore implements AISecretStore {
  FlutterSecureAISecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

abstract interface class AISettingsStore {
  Future<AIProviderSettings> load([AIProviderType? provider]);

  Future<void> save(AIProviderSettings settings);
}

class SharedPreferencesAISettingsStore implements AISettingsStore {
  SharedPreferencesAISettingsStore({
    Future<SharedPreferences> Function()? preferences,
    AISecretStore? secretStore,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _secretStore = secretStore ?? FlutterSecureAISecretStore();

  static const _activeProviderKey = 'reader_ai_provider_v1';
  static const _minimaxApiKeyKey = 'reader_ai_minimax_api_key_v1';
  static const _glmApiKeyKey = 'reader_ai_glm_api_key_v1';
  static const _openaiApiKeyKey = 'reader_ai_openai_api_key_v1';
  static const _claudeApiKeyKey = 'reader_ai_claude_api_key_v1';
  static const _geminiApiKeyKey = 'reader_ai_gemini_api_key_v1';
  static const _customApiKeyKey = 'reader_ai_custom_api_key_v1';
  static const _minimaxBaseUrlKey = 'reader_ai_minimax_base_url_v1';
  static const _glmBaseUrlKey = 'reader_ai_glm_base_url_v1';
  static const _openaiBaseUrlKey = 'reader_ai_openai_base_url_v1';
  static const _claudeBaseUrlKey = 'reader_ai_claude_base_url_v1';
  static const _geminiBaseUrlKey = 'reader_ai_gemini_base_url_v1';
  static const _customBaseUrlKey = 'reader_ai_custom_base_url_v1';
  static const _minimaxModelKey = 'reader_ai_minimax_model_v1';
  static const _glmModelKey = 'reader_ai_glm_model_v1';
  static const _openaiModelKey = 'reader_ai_openai_model_v1';
  static const _claudeModelKey = 'reader_ai_claude_model_v1';
  static const _geminiModelKey = 'reader_ai_gemini_model_v1';
  static const _customModelKey = 'reader_ai_custom_model_v1';
  static const _minimaxTemperatureKey = 'reader_ai_minimax_temp_v1';
  static const _glmTemperatureKey = 'reader_ai_glm_temp_v1';
  static const _openaiTemperatureKey = 'reader_ai_openai_temp_v1';
  static const _claudeTemperatureKey = 'reader_ai_claude_temp_v1';
  static const _geminiTemperatureKey = 'reader_ai_gemini_temp_v1';
  static const _customTemperatureKey = 'reader_ai_custom_temp_v1';
  static const _customProtocolKey = 'reader_ai_custom_protocol_v1';

  final Future<SharedPreferences> Function() _preferences;
  final AISecretStore _secretStore;

  @override
  Future<AIProviderSettings> load([AIProviderType? provider]) async {
    final prefs = await _preferences();
    final activeProvider =
        provider ??
        AIProviderTypeX.fromValue(prefs.getString(_activeProviderKey));
    final defaults = AIProviderSettings.defaults(activeProvider);

    final apiKey = await _readApiKey(prefs, activeProvider);
    final baseUrl =
        prefs.getString(_baseUrlKey(activeProvider)) ?? defaults.baseUrl;
    final model = prefs.getString(_modelKey(activeProvider)) ?? defaults.model;
    final temperature =
        prefs.getDouble(_temperatureKey(activeProvider)) ??
        defaults.temperature;
    final protocol = activeProvider == AIProviderType.custom
        ? AIProtocolTypeX.fromValue(
            prefs.getString(_customProtocolKey),
            fallback: defaults.effectiveProtocol,
          )
        : activeProvider.defaultProtocol;

    return AIProviderSettings(
      provider: activeProvider,
      protocol: protocol,
      apiKey: apiKey,
      baseUrl: baseUrl,
      model: model,
      temperature: temperature,
    ).normalized();
  }

  @override
  Future<void> save(AIProviderSettings settings) async {
    final normalized = settings.normalized();
    final validationError = validateAIProviderSettings(normalized);
    if (validationError != null) {
      throw AIServiceException(code: validationError);
    }
    final prefs = await _preferences();
    await prefs.setString(_activeProviderKey, normalized.provider.value);
    await _writeApiKey(prefs, normalized.provider, normalized.apiKey);
    await prefs.setString(_baseUrlKey(normalized.provider), normalized.baseUrl);
    await prefs.setString(_modelKey(normalized.provider), normalized.model);
    await prefs.setDouble(
      _temperatureKey(normalized.provider),
      normalized.temperature,
    );
    if (normalized.provider == AIProviderType.custom) {
      await prefs.setString(
        _customProtocolKey,
        normalized.effectiveProtocol.value,
      );
    }
  }

  /// 优先安全存储；发现 SharedPreferences 中的历史明文 key 时迁移并删除。
  Future<String> _readApiKey(
    SharedPreferences prefs,
    AIProviderType provider,
  ) async {
    final storageKey = _apiKeyKey(provider);
    try {
      final secureValue = await _secretStore.read(storageKey);
      if (secureValue != null) {
        if (prefs.containsKey(storageKey)) {
          await prefs.remove(storageKey);
        }
        return secureValue;
      }
      final legacyValue = prefs.getString(storageKey);
      if (legacyValue != null) {
        await _secretStore.write(storageKey, legacyValue);
        await prefs.remove(storageKey);
        return legacyValue;
      }
      return '';
    } on Exception {
      // 安全存储不可用（如 Linux 无 keyring）时保留原有明文兼容路径。
      return prefs.getString(storageKey) ?? '';
    }
  }

  Future<void> _writeApiKey(
    SharedPreferences prefs,
    AIProviderType provider,
    String apiKey,
  ) async {
    final storageKey = _apiKeyKey(provider);
    try {
      await _secretStore.write(storageKey, apiKey);
      if (prefs.containsKey(storageKey)) {
        await prefs.remove(storageKey);
      }
    } on Exception {
      await prefs.setString(storageKey, apiKey);
    }
  }

  String _apiKeyKey(AIProviderType provider) {
    switch (provider) {
      case AIProviderType.minimax:
        return _minimaxApiKeyKey;
      case AIProviderType.glm:
        return _glmApiKeyKey;
      case AIProviderType.openai:
        return _openaiApiKeyKey;
      case AIProviderType.claude:
        return _claudeApiKeyKey;
      case AIProviderType.gemini:
        return _geminiApiKeyKey;
      case AIProviderType.custom:
        return _customApiKeyKey;
    }
  }

  String _baseUrlKey(AIProviderType provider) {
    switch (provider) {
      case AIProviderType.minimax:
        return _minimaxBaseUrlKey;
      case AIProviderType.glm:
        return _glmBaseUrlKey;
      case AIProviderType.openai:
        return _openaiBaseUrlKey;
      case AIProviderType.claude:
        return _claudeBaseUrlKey;
      case AIProviderType.gemini:
        return _geminiBaseUrlKey;
      case AIProviderType.custom:
        return _customBaseUrlKey;
    }
  }

  String _modelKey(AIProviderType provider) {
    switch (provider) {
      case AIProviderType.minimax:
        return _minimaxModelKey;
      case AIProviderType.glm:
        return _glmModelKey;
      case AIProviderType.openai:
        return _openaiModelKey;
      case AIProviderType.claude:
        return _claudeModelKey;
      case AIProviderType.gemini:
        return _geminiModelKey;
      case AIProviderType.custom:
        return _customModelKey;
    }
  }

  String _temperatureKey(AIProviderType provider) {
    switch (provider) {
      case AIProviderType.minimax:
        return _minimaxTemperatureKey;
      case AIProviderType.glm:
        return _glmTemperatureKey;
      case AIProviderType.openai:
        return _openaiTemperatureKey;
      case AIProviderType.claude:
        return _claudeTemperatureKey;
      case AIProviderType.gemini:
        return _geminiTemperatureKey;
      case AIProviderType.custom:
        return _customTemperatureKey;
    }
  }
}
