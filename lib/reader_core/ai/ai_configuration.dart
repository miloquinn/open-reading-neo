// 文件说明：AI Provider 与 Protocol 配置模型、URL 规范化和校验规则。
// 技术要点：稳定存储值、协议默认值、Provider 默认配置、错误码校验。

part of 'ai_service.dart';

enum AIProviderType { minimax, glm, openai, claude, gemini, custom }

enum AIProtocolType { openai, anthropic, gemini }

extension AIProtocolTypeX on AIProtocolType {
  String get value {
    switch (this) {
      case AIProtocolType.openai:
        return 'openai';
      case AIProtocolType.anthropic:
        return 'anthropic';
      case AIProtocolType.gemini:
        return 'gemini';
    }
  }

  String get displayName {
    switch (this) {
      case AIProtocolType.openai:
        return 'OpenAI Compatible';
      case AIProtocolType.anthropic:
        return 'Anthropic';
      case AIProtocolType.gemini:
        return 'Google Gemini';
    }
  }

  static AIProtocolType fromValue(
    String? value, {
    required AIProtocolType fallback,
  }) {
    switch (value) {
      case 'anthropic':
        return AIProtocolType.anthropic;
      case 'gemini':
        return AIProtocolType.gemini;
      case 'openai':
        return AIProtocolType.openai;
      default:
        return fallback;
    }
  }
}

extension AIProviderTypeX on AIProviderType {
  String get value {
    switch (this) {
      case AIProviderType.minimax:
        return 'minimax';
      case AIProviderType.glm:
        return 'glm';
      case AIProviderType.openai:
        return 'openai';
      case AIProviderType.claude:
        return 'claude';
      case AIProviderType.gemini:
        return 'gemini';
      case AIProviderType.custom:
        return 'custom';
    }
  }

  String get displayName {
    switch (this) {
      case AIProviderType.minimax:
        return 'MiniMax';
      case AIProviderType.glm:
        return 'GLM';
      case AIProviderType.openai:
        return 'OpenAI';
      case AIProviderType.claude:
        return 'Claude';
      case AIProviderType.gemini:
        return 'Gemini';
      case AIProviderType.custom:
        return 'Custom';
    }
  }

  static AIProviderType fromValue(String? value) {
    switch (value) {
      case 'glm':
        return AIProviderType.glm;
      case 'openai':
        return AIProviderType.openai;
      case 'claude':
        return AIProviderType.claude;
      case 'gemini':
        return AIProviderType.gemini;
      case 'custom':
        return AIProviderType.custom;
      default:
        return AIProviderType.minimax;
    }
  }

  AIProtocolType get defaultProtocol {
    switch (this) {
      case AIProviderType.minimax:
      case AIProviderType.glm:
      case AIProviderType.openai:
      case AIProviderType.custom:
        return AIProtocolType.openai;
      case AIProviderType.claude:
        return AIProtocolType.anthropic;
      case AIProviderType.gemini:
        return AIProtocolType.gemini;
    }
  }
}

String normalizeAIBaseUrl(
  AIProviderType provider,
  String baseUrl, {
  AIProtocolType? protocol,
}) {
  final trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (trimmed.isEmpty) {
    return '';
  }

  final uri = Uri.tryParse(trimmed);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return trimmed;
  }

  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  final effectiveProtocol = provider == AIProviderType.custom
      ? protocol ?? provider.defaultProtocol
      : provider.defaultProtocol;
  switch (effectiveProtocol) {
    case AIProtocolType.openai:
      path = path.replaceFirst(
        RegExp(r'/chat/completions$', caseSensitive: false),
        '',
      );
      break;
    case AIProtocolType.anthropic:
      path = path.replaceFirst(
        RegExp(r'/v1/messages$', caseSensitive: false),
        '/v1',
      );
      path = path.replaceFirst(RegExp(r'/messages$', caseSensitive: false), '');
      break;
    case AIProtocolType.gemini:
      path = path.replaceFirst(
        RegExp(r'/models/[^/]+:generateContent$', caseSensitive: false),
        '',
      );
      break;
  }

  return uri.replace(path: path).toString().replaceAll(RegExp(r'/+$'), '');
}

String? validateAIProviderSettings(
  AIProviderSettings settings, {
  bool requireApiKey = true,
}) {
  final normalized = settings.normalized();
  if (requireApiKey && normalized.apiKey.isEmpty) {
    return 'api_key_required';
  }
  if (normalized.model.isEmpty) {
    return 'model_required';
  }

  final uri = Uri.tryParse(normalized.baseUrl);
  if (normalized.baseUrl.isEmpty ||
      uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https'))) {
    return 'base_url_invalid';
  }

  if (!_isValidTemperature(normalized, normalized.temperature)) {
    return normalized.provider == AIProviderType.minimax
        ? 'temp_error_minimax'
        : 'temp_error_out_of_range';
  }

  final model = normalized.model.toLowerCase();
  switch (normalized.provider) {
    case AIProviderType.claude:
      if (!model.startsWith('claude')) {
        return 'model_mismatch_claude';
      }
      break;
    case AIProviderType.gemini:
      if (!model.contains('gemini')) {
        return 'model_mismatch_gemini';
      }
      break;
    case AIProviderType.glm:
      if (!model.startsWith('glm')) {
        return 'model_mismatch_glm';
      }
      break;
    case AIProviderType.minimax:
      if (!model.contains('minimax')) {
        return 'model_mismatch_minimax';
      }
      break;
    case AIProviderType.openai:
    case AIProviderType.custom:
      break;
  }

  return null;
}

bool _isValidTemperature(AIProviderSettings settings, double value) {
  if (!value.isFinite || value < 0 || value > 2) {
    return false;
  }
  if (settings.provider == AIProviderType.minimax) {
    return value > 0 && value <= 1;
  }
  if ((settings.effectiveProtocol == AIProtocolType.anthropic ||
          settings.effectiveProtocol == AIProtocolType.gemini) &&
      value > 1) {
    return false;
  }
  return true;
}

class AIProviderSettings {
  final AIProviderType provider;
  final AIProtocolType? protocol;
  final String apiKey;
  final String baseUrl;
  final String model;
  final double temperature;

  const AIProviderSettings({
    required this.provider,
    this.protocol,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.temperature,
  });

  factory AIProviderSettings.defaults(AIProviderType provider) {
    if (provider == AIProviderType.custom) {
      return const AIProviderSettings(
        provider: AIProviderType.custom,
        protocol: AIProtocolType.openai,
        apiKey: '',
        baseUrl: '',
        model: '',
        temperature: 0.7,
      );
    }
    return AIModelPresets.defaultForProvider(provider).toSettings();
  }

  AIProtocolType get effectiveProtocol => protocol ?? provider.defaultProtocol;

  AIProviderSettings copyWith({
    AIProviderType? provider,
    AIProtocolType? protocol,
    String? apiKey,
    String? baseUrl,
    String? model,
    double? temperature,
  }) {
    return AIProviderSettings(
      provider: provider ?? this.provider,
      protocol: protocol ?? this.protocol,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
    );
  }

  AIProviderSettings normalized() {
    final normalizedProtocol = provider == AIProviderType.custom
        ? effectiveProtocol
        : provider.defaultProtocol;
    final normalizedBaseUrl = normalizeAIBaseUrl(
      provider,
      baseUrl,
      protocol: normalizedProtocol,
    );
    final normalizedModel = model.trim();
    final normalizedTemperature = temperature.isFinite ? temperature : 0.7;
    return copyWith(
      apiKey: apiKey.trim(),
      protocol: normalizedProtocol,
      baseUrl: normalizedBaseUrl.isEmpty
          ? _defaultBaseUrl(provider)
          : normalizedBaseUrl,
      model: normalizedModel.isEmpty
          ? _defaultModel(provider)
          : normalizedModel,
      temperature: normalizedTemperature.clamp(0.0, 2.0),
    );
  }

  bool get isConfigured => apiKey.trim().isNotEmpty;

  static String _defaultBaseUrl(AIProviderType provider) =>
      AIProviderSettings.defaults(provider).baseUrl;
  static String _defaultModel(AIProviderType provider) =>
      AIProviderSettings.defaults(provider).model;
}
