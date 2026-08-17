// 文件说明：阅读内核 AI 配置与请求模型，统一描述模型、提供商和请求参数。
// 技术要点：ReaderCore、Dio、SharedPreferences、Secure Storage、JSON。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'ai_settings_store.dart';
part 'ai_protocol_adapter.dart';
part 'ai_http_error_translator.dart';
part 'ai_model_presets.dart';
part 'ai_configuration.dart';

class AIRequestMeta {
  final String bookId;
  final String chapterId;
  final int? pageIndex;

  const AIRequestMeta({
    required this.bookId,
    required this.chapterId,
    this.pageIndex,
  });
}

class AIChatMessage {
  final String role;
  final String content;

  const AIChatMessage({required this.role, required this.content});

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

abstract class AIService {
  Future<String> askSelection({
    required String selectedText,
    required String contextBefore,
    required String contextAfter,
    required AIRequestMeta meta,
  });

  Future<String> analyzePage({
    required String pageText,
    required AIRequestMeta meta,
  });

  Future<String> chat({
    required List<AIChatMessage> history,
    required String pageText,
    required AIRequestMeta meta,
  });
}

abstract class ConfigurableAIService implements AIService {
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]);
  Future<void> saveSettings(AIProviderSettings settings);
}

class AIServiceException implements Exception {
  final String code;
  final String? status;
  final String? text;
  final String? endpoint;
  final String? error;
  final String? provider;
  final String? snippet;

  const AIServiceException({
    required this.code,
    this.status,
    this.text,
    this.endpoint,
    this.error,
    this.provider,
    this.snippet,
  });

  @override
  String toString() => code;
}

class ReaderHttpAIService implements ConfigurableAIService {
  ReaderHttpAIService({
    Dio? dio,
    AISettingsStore? settingsStore,
    AIProtocolAdapter? protocolAdapter,
    AIErrorTranslator? errorTranslator,
  }) : _dio = dio ?? Dio(),
       _settingsStore = settingsStore ?? SharedPreferencesAISettingsStore(),
       _protocolAdapter = protocolAdapter ?? const AIProtocolAdapter(),
       _errorTranslator = errorTranslator ?? const AIErrorTranslator();

  final Dio _dio;
  final AISettingsStore _settingsStore;
  final AIProtocolAdapter _protocolAdapter;
  final AIErrorTranslator _errorTranslator;

  @override
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]) =>
      _settingsStore.load(provider);

  @override
  Future<void> saveSettings(AIProviderSettings settings) =>
      _settingsStore.save(settings);

  Future<List<String>> fetchAvailableModels(AIProviderSettings settings) async {
    final normalized = settings.normalized();
    if (normalized.apiKey.isEmpty) {
      throw const AIServiceException(code: 'api_key_required');
    }

    final endpoint = _protocolAdapter.modelListEndpoint(normalized);
    final options = _protocolAdapter
        .requestOptions(normalized)
        .copyWith(
          responseType: ResponseType.json,
          receiveTimeout: const Duration(seconds: 30),
        );

    try {
      final response = await _dio.get<dynamic>(endpoint, options: options);
      dynamic body = response.data;
      if (body is String) {
        body = jsonDecode(body);
      }
      if (body is! Map) {
        throw const AIServiceException(code: 'model_list_format_unrecognized');
      }

      final rawModels = body['data'] ?? body['models'];
      if (rawModels is! List) {
        throw const AIServiceException(code: 'no_models_returned');
      }

      final models =
          rawModels
              .map((item) {
                if (item is String) return item;
                if (item is Map) {
                  final value = item['id'] ?? item['name'] ?? item['model'];
                  return value?.toString();
                }
                return null;
              })
              .whereType<String>()
              .map(
                (model) => model.replaceFirst(RegExp(r'^models/'), '').trim(),
              )
              .where((model) => model.isNotEmpty)
              .toSet()
              .toList()
            ..sort();

      if (models.isEmpty) {
        throw const AIServiceException(code: 'no_models_available');
      }
      return models;
    } on DioException catch (error) {
      throw _errorTranslator.translate(error);
    } on AIServiceException {
      rethrow;
    } catch (error) {
      throw AIServiceException(
        code: 'fetch_models_failed',
        error: error.toString(),
      );
    }
  }

  @override
  Future<String> askSelection({
    required String selectedText,
    required String contextBefore,
    required String contextAfter,
    required AIRequestMeta meta,
  }) {
    final prompt = StringBuffer()
      ..writeln('请解释下面这段选中文本，并给出 3 条要点。')
      ..writeln()
      ..writeln('【选中文本】')
      ..writeln(selectedText.trim())
      ..writeln()
      ..writeln('【上文】')
      ..writeln(contextBefore.trim().isEmpty ? '(无)' : contextBefore.trim())
      ..writeln()
      ..writeln('【下文】')
      ..writeln(contextAfter.trim().isEmpty ? '(无)' : contextAfter.trim());

    return chat(
      history: [AIChatMessage(role: 'user', content: prompt.toString())],
      pageText: '$contextBefore\n$selectedText\n$contextAfter',
      meta: meta,
    );
  }

  @override
  Future<String> analyzePage({
    required String pageText,
    required AIRequestMeta meta,
  }) {
    return chat(
      history: const [
        AIChatMessage(role: 'user', content: '请总结当前页的核心观点，并给出 3 条可执行的阅读建议。'),
      ],
      pageText: pageText,
      meta: meta,
    );
  }

  @override
  Future<String> chat({
    required List<AIChatMessage> history,
    required String pageText,
    required AIRequestMeta meta,
  }) async {
    final settings = await _resolveActiveSettings();
    final validationError = validateAIProviderSettings(settings);
    if (validationError != null) {
      throw AIServiceException(code: validationError);
    }

    final context = _compactPageContext(pageText);
    final singleSystemPrompt = _buildSingleSystemPrompt(
      context: context,
      meta: meta,
    );
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': singleSystemPrompt},
      ...history
          .where(
            (m) =>
                (m.role == 'user' ||
                    m.role == 'assistant' ||
                    m.role == 'system') &&
                m.content.trim().isNotEmpty,
          )
          .map((m) => m.toJson()),
    ];

    if (!messages.any((m) => m['role'] == 'user')) {
      throw const AIServiceException(code: 'enter_question_first');
    }

    final endpoint = _protocolAdapter.chatEndpoint(settings);
    final payload = _protocolAdapter.buildPayload(
      settings: settings,
      messages: messages,
    );

    try {
      final response = await _dio.post<String>(
        endpoint,
        data: payload,
        options: _protocolAdapter.requestOptions(settings),
      );
      final responseData = _decodeResponseBody(
        rawBody: response.data,
        endpoint: endpoint,
        settings: settings,
      );
      final answer = _protocolAdapter.extractAssistantContent(
        settings: settings,
        responseData: responseData,
      );
      if (answer.trim().isEmpty) {
        throw const AIServiceException(code: 'empty_response');
      }
      return answer.trim();
    } on DioException catch (e) {
      throw _errorTranslator.translate(e);
    } catch (e) {
      throw AIServiceException(code: 'request_failed', error: e.toString());
    }
  }

  /// 每次请求都重新读取当前激活配置：服务在各页面被独立实例化，
  /// 实例级缓存会让设置页切换的模型无法作用到已打开的对话界面。
  Future<AIProviderSettings> _resolveActiveSettings() => loadSettings();

  String _compactPageContext(String pageText) {
    final text = pageText
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (text.length <= 2800) {
      return text;
    }
    return '${text.substring(0, 2800)}...';
  }

  String _buildSingleSystemPrompt({
    required String context,
    required AIRequestMeta meta,
  }) {
    final buffer = StringBuffer()
      ..writeln('你是一个中文阅读助手。')
      ..writeln('回答要求：简洁、准确、结构清晰，优先结合用户当前阅读页内容。')
      ..writeln(
        '元信息：bookId=${meta.bookId}, chapterId=${meta.chapterId}, pageIndex=${meta.pageIndex ?? -1}',
      );
    if (context.isNotEmpty) {
      buffer
        ..writeln('当前阅读页正文（仅供参考）：')
        ..writeln(context);
    }
    return buffer.toString().trim();
  }

  dynamic _decodeResponseBody({
    required String? rawBody,
    required String endpoint,
    required AIProviderSettings settings,
  }) {
    final body = rawBody?.trim() ?? '';
    if (body.isEmpty) {
      throw AIServiceException(
        code: 'empty_response_error',
        endpoint: endpoint,
      );
    }

    try {
      return jsonDecode(body);
    } on FormatException {
      throw AIServiceException(
        code: 'invalid_json_error',
        provider: settings.provider.displayName,
        endpoint: endpoint,
        snippet: _errorTranslator.truncateForError(body),
      );
    }
  }
}

class MockAIService implements ConfigurableAIService {
  AIProviderSettings _settings = AIProviderSettings.defaults(
    AIProviderType.minimax,
  );

  @override
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]) async {
    if (provider == null || provider == _settings.provider) {
      return _settings;
    }
    return AIProviderSettings.defaults(provider);
  }

  @override
  Future<void> saveSettings(AIProviderSettings settings) async {
    _settings = settings.normalized();
  }

  @override
  Future<String> askSelection({
    required String selectedText,
    required String contextBefore,
    required String contextAfter,
    required AIRequestMeta meta,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    return _mockToken('mock_selection_response', {
      'selectedText': selectedText,
      'before': _trim(contextBefore),
      'after': _trim(contextAfter),
    });
  }

  @override
  Future<String> analyzePage({
    required String pageText,
    required AIRequestMeta meta,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    return _mockToken('mock_page_analysis', {'chars': pageText.length});
  }

  @override
  Future<String> chat({
    required List<AIChatMessage> history,
    required String pageText,
    required AIRequestMeta meta,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    final last = history.isNotEmpty ? history.last.content : '';
    if (last.trim().isEmpty) {
      return _mockToken('mock_greeting', {});
    }
    return _mockToken('mock_chat_response', {
      'question': _trim(last),
      'chars': pageText.length,
    });
  }

  String _trim(String text) {
    if (text.length <= 80) return text;
    return '${text.substring(0, 80)}...';
  }

  /// Encode a mock response as a token that the UI layer translates
  /// via [translateMockAiResponse].
  static String _mockToken(String code, Map<String, dynamic> params) {
    return '[[mock:$code|${jsonEncode(params)}]]';
  }
}
