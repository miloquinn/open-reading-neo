// 文件说明：AI HTTP 与服务商错误翻译器，将 Dio 失败映射为稳定的产品错误码。
// 技术要点：DioException、JSON 错误体、服务商提示分类、响应摘要截断。

part of 'ai_service.dart';

class AIErrorTranslator {
  const AIErrorTranslator();

  AIServiceException translate(DioException error) {
    final statusText = error.response?.statusCode?.toString() ?? '';
    final data = error.response?.data;
    final endpoint = error.requestOptions.uri.toString();
    if (data is Map) {
      final message = _extractMapErrorMessage(data);
      if (message != null) {
        return _enhanceProviderException(message, statusText, endpoint);
      }
    }
    if (data is String && data.trim().isNotEmpty) {
      try {
        final jsonMap = jsonDecode(data);
        if (jsonMap is Map) {
          final message = _extractMapErrorMessage(jsonMap);
          if (message != null) {
            return _enhanceProviderException(message, statusText, endpoint);
          }
        }
      } catch (_) {
        return _enhanceProviderException(data, statusText, endpoint);
      }
    }
    final rawError = error.error?.toString() ?? error.message ?? '';
    if (_looksLikeMissingResponse(rawError)) {
      return AIServiceException(
        code: 'failed_read_body',
        status: statusText,
        endpoint: endpoint,
      );
    }
    return AIServiceException(
      code: 'network_request_failed',
      status: statusText,
      error: rawError,
      endpoint: endpoint,
    );
  }

  String truncateForError(String text, {int maxLength = 220}) {
    final compact = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= maxLength) return compact;
    return '${compact.substring(0, maxLength)}...';
  }

  String? _extractMapErrorMessage(Map data) {
    final error = data['error'];
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) return message;
    }
    final message = data['message'];
    if (message is String && message.trim().isNotEmpty) return message;
    final detail = data['detail'];
    if (detail is String && detail.trim().isNotEmpty) return detail;
    return null;
  }

  AIServiceException _enhanceProviderException(
    String message,
    String status,
    String endpoint,
  ) {
    final text = message.trim();
    final lower = text.toLowerCase();
    if (lower.contains('invalid chat setting')) {
      return AIServiceException(
        code: 'request_failed_minimax_hint',
        status: status,
        text: text,
        endpoint: endpoint,
      );
    }
    if (lower.contains('anthropic-version')) {
      return AIServiceException(
        code: 'request_failed_claude_hint',
        status: status,
        text: text,
        endpoint: endpoint,
      );
    }
    if (lower.contains('api key not valid') ||
        lower.contains('invalid api key')) {
      return AIServiceException(
        code: 'request_failed_provider_mismatch_hint',
        status: status,
        text: text,
        endpoint: endpoint,
      );
    }
    if (_looksLikeMissingResponse(text)) {
      return AIServiceException(
        code: 'failed_read_body',
        status: status,
        endpoint: endpoint,
      );
    }
    return AIServiceException(
      code: 'request_failed_generic',
      status: status,
      text: text,
      endpoint: endpoint,
    );
  }

  bool _looksLikeMissingResponse(String text) {
    final lower = text.toLowerCase();
    return lower.contains('data couldn') && lower.contains('missing') ||
        lower.contains('data is missing') ||
        lower.contains('because it is missing') ||
        lower.contains('unexpected end of input');
  }
}
