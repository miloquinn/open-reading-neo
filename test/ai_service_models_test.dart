import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderHttpAIService.fetchAvailableModels', () {
    test('parses OpenAI-compatible model data', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'data': [
                      {'id': 'model-b'},
                      {'id': 'model-a'},
                    ],
                  },
                ),
              );
            },
          ),
        );
      final service = ReaderHttpAIService(dio: dio);

      final models = await service.fetchAvailableModels(
        const AIProviderSettings(
          provider: AIProviderType.openai,
          apiKey: 'test-key',
          baseUrl: 'https://example.com/v1',
          model: 'model-a',
          temperature: 0.7,
        ),
      );

      expect(models, ['model-a', 'model-b']);
    });

    test('parses and normalizes Gemini model names', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'models': [
                      {'name': 'models/gemini-2.5-flash'},
                      {'name': 'models/gemini-2.5-pro'},
                    ],
                  },
                ),
              );
            },
          ),
        );
      final service = ReaderHttpAIService(dio: dio);

      final models = await service.fetchAvailableModels(
        const AIProviderSettings(
          provider: AIProviderType.gemini,
          apiKey: 'test-key',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          model: 'gemini-2.5-flash',
          temperature: 0.7,
        ),
      );

      expect(models, ['gemini-2.5-flash', 'gemini-2.5-pro']);
    });

    test(
      'uses Anthropic model endpoint and headers for custom provider',
      () async {
        late RequestOptions captured;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                captured = options;
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'data': [
                        {'id': 'custom-claude-model'},
                      ],
                    },
                  ),
                );
              },
            ),
          );
        final service = ReaderHttpAIService(dio: dio);

        final models = await service.fetchAvailableModels(
          const AIProviderSettings(
            provider: AIProviderType.custom,
            protocol: AIProtocolType.anthropic,
            apiKey: 'anthropic-key',
            baseUrl: 'https://gateway.example.com',
            model: 'custom-claude-model',
            temperature: 0.7,
          ),
        );

        expect(models, ['custom-claude-model']);
        expect(
          captured.uri.toString(),
          'https://gateway.example.com/v1/models',
        );
        expect(captured.headers['x-api-key'], 'anthropic-key');
        expect(captured.headers['anthropic-version'], '2023-06-01');
        expect(captured.headers, isNot(contains('Authorization')));
      },
    );
  });

  group('custom AI provider protocol settings', () {
    test('OpenAI-compatible URL keeps v1 and strips full chat endpoint', () {
      final settings = const AIProviderSettings(
        provider: AIProviderType.custom,
        protocol: AIProtocolType.openai,
        apiKey: 'key',
        baseUrl: 'https://gateway.example.com/v1/chat/completions',
        model: 'reader-model',
        temperature: 1.2,
      ).normalized();

      expect(settings.baseUrl, 'https://gateway.example.com/v1');
      expect(settings.effectiveProtocol, AIProtocolType.openai);
      expect(validateAIProviderSettings(settings), isNull);
    });

    test(
      'Anthropic protocol accepts custom model names and limits temperature',
      () {
        final settings = const AIProviderSettings(
          provider: AIProviderType.custom,
          protocol: AIProtocolType.anthropic,
          apiKey: 'key',
          baseUrl: 'https://gateway.example.com/v1/messages',
          model: 'vendor-private-model',
          temperature: 1.2,
        ).normalized();

        expect(settings.baseUrl, 'https://gateway.example.com/v1');
        expect(validateAIProviderSettings(settings), 'temp_error_out_of_range');
      },
    );

    test('custom Anthropic chat uses messages endpoint and payload', () async {
      SharedPreferences.setMockInitialValues({});
      late RequestOptions captured;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              captured = options;
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 200,
                  data: jsonEncode({
                    'content': [
                      {'type': 'text', 'text': '自定义协议已生效'},
                    ],
                  }),
                ),
              );
            },
          ),
        );
      final service = ReaderHttpAIService(dio: dio);
      await service.saveSettings(
        const AIProviderSettings(
          provider: AIProviderType.custom,
          protocol: AIProtocolType.anthropic,
          apiKey: 'anthropic-key',
          baseUrl: 'https://gateway.example.com',
          model: 'private-reader-model',
          temperature: 0.7,
        ),
      );

      final answer = await service.chat(
        history: const [AIChatMessage(role: 'user', content: '解释这段文本')],
        pageText: '当前阅读页',
        meta: const AIRequestMeta(bookId: 'book', chapterId: 'chapter'),
      );

      expect(answer, '自定义协议已生效');
      expect(
        captured.uri.toString(),
        'https://gateway.example.com/v1/messages',
      );
      expect(captured.headers['x-api-key'], 'anthropic-key');
      final payload = captured.data as Map<String, dynamic>;
      expect(payload['model'], 'private-reader-model');
      expect(payload['system'], contains('中文阅读助手'));
      expect(payload['messages'], [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '解释这段文本'},
          ],
        },
      ]);
    });
  });
}
