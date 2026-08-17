import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/reader_core/ai/ai_service.dart';

DioException _responseError(dynamic data, {int statusCode = 400}) {
  final request = RequestOptions(path: 'https://api.example.com/v1/chat');
  return DioException(
    requestOptions: request,
    response: Response<dynamic>(
      requestOptions: request,
      statusCode: statusCode,
      data: data,
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  const translator = AIErrorTranslator();

  test('maps MiniMax invalid-chat-setting errors to a provider hint', () {
    final error = translator.translate(
      _responseError({
        'error': {'message': 'Invalid chat setting for this model'},
      }),
    );

    expect(error.code, 'request_failed_minimax_hint');
    expect(error.status, '400');
    expect(error.endpoint, 'https://api.example.com/v1/chat');
  });

  test('maps Anthropic version errors to the Claude hint', () {
    final error = translator.translate(
      _responseError({'message': 'anthropic-version header is required'}),
    );

    expect(error.code, 'request_failed_claude_hint');
  });

  test('maps invalid API keys to the provider mismatch hint', () {
    final error = translator.translate(
      _responseError({'detail': 'API key not valid for this provider'}),
    );

    expect(error.code, 'request_failed_provider_mismatch_hint');
  });

  test('maps missing response body errors explicitly', () {
    final request = RequestOptions(path: 'https://api.example.com/v1/chat');
    final error = translator.translate(
      DioException(
        requestOptions: request,
        error: 'Data is missing because it is missing',
        type: DioExceptionType.unknown,
      ),
    );

    expect(error.code, 'failed_read_body');
  });

  test('maps generic provider and transport failures', () {
    final providerError = translator.translate(
      _responseError({
        'message': 'provider is temporarily unavailable',
      }, statusCode: 503),
    );
    expect(providerError.code, 'request_failed_generic');
    expect(providerError.status, '503');

    final request = RequestOptions(path: 'https://api.example.com/v1/chat');
    final transportError = translator.translate(
      DioException(
        requestOptions: request,
        error: 'connection refused',
        type: DioExceptionType.connectionError,
      ),
    );
    expect(transportError.code, 'network_request_failed');
    expect(transportError.error, 'connection refused');
  });

  test('compacts and truncates response snippets', () {
    expect(
      translator.truncateForError('  first\n\n second   third  '),
      'first second third',
    );
    expect(translator.truncateForError('123456789', maxLength: 5), '12345...');
  });
}
