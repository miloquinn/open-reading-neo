import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../protocol/book_source_protocol.dart';

class SourcePlatformBytesResult {
  const SourcePlatformBytesResult({
    required this.statusCode,
    required this.bytes,
    this.location,
  });

  final int statusCode;
  final Uint8List bytes;
  final String? location;
}

class SourceWebViewResult {
  const SourceWebViewResult({
    required this.body,
    required this.finalUri,
    this.cookieHeader,
  });

  final String body;
  final Uri finalUri;
  final String? cookieHeader;
}

abstract interface class SourceWebViewLoaderPort {
  Future<SourcePlatformBytesResult> loadBytes({
    required Uri url,
    required Map<String, String> headers,
    required int maxBytes,
  });

  Future<SourceWebViewResult> load({
    required Uri url,
    required String method,
    required Map<String, String> headers,
    String? body,
    String? webJs,
    String? html,
  });
}

class SourceWebViewLoader implements SourceWebViewLoaderPort {
  const SourceWebViewLoader();

  static const MethodChannel _channel = MethodChannel(
    'com.niki.xxread/source_webview',
  );

  @override
  Future<SourcePlatformBytesResult> loadBytes({
    required Uri url,
    required Map<String, String> headers,
    required int maxBytes,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const BookSourceProtocolException(
        'Platform byte loading is available on Android only.',
      );
    }
    try {
      final result = await _channel
          .invokeMapMethod<String, dynamic>('loadBytes', {
            'url': url.toString(),
            'headers': headers,
            'maxBytes': maxBytes,
            'timeoutMs': 15000,
          });
      final statusCode = result?['statusCode'];
      final bytes = result?['bytes'];
      if (statusCode is! int || bytes is! Uint8List) {
        throw const BookSourceProtocolException(
          'Platform byte loader returned an invalid response.',
        );
      }
      return SourcePlatformBytesResult(
        statusCode: statusCode,
        bytes: bytes,
        location: result?['location'] as String?,
      );
    } on PlatformException catch (error) {
      throw BookSourceProtocolException(
        error.message ?? 'Platform byte loading failed.',
      );
    }
  }

  @override
  Future<SourceWebViewResult> load({
    required Uri url,
    required String method,
    required Map<String, String> headers,
    String? body,
    String? webJs,
    String? html,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const BookSourceProtocolException(
        'This source requires background browser loading on Android.',
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('load', {
        'url': url.toString(),
        'method': method,
        'headers': headers,
        'body': body,
        'webJs': webJs,
        'html': html,
        'timeoutMs': 15000,
      });
      final responseBody = result?['body'];
      final finalUrl = result?['finalUrl'];
      final cookieHeader = result?['cookieHeader'];
      final uri = finalUrl is String ? Uri.tryParse(finalUrl) : null;
      if (responseBody is! String || uri == null) {
        throw const BookSourceProtocolException(
          'Background browser returned an invalid response.',
        );
      }
      return SourceWebViewResult(
        body: responseBody,
        finalUri: uri,
        cookieHeader: cookieHeader is String ? cookieHeader : null,
      );
    } on PlatformException catch (error) {
      throw BookSourceProtocolException(
        error.message ?? 'Background browser failed to load this source.',
      );
    }
  }
}
