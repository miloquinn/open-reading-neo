import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../protocol/book_source_protocol.dart';

class SourceInteractiveBrowserResult {
  const SourceInteractiveBrowserResult({
    required this.body,
    required this.finalUri,
    this.cookieHeader,
  });

  final String body;
  final Uri finalUri;
  final String? cookieHeader;
}

class SourceInteractiveBrowserCancelled implements Exception {
  const SourceInteractiveBrowserCancelled();
}

class SourceInteractiveBrowser {
  const SourceInteractiveBrowser();

  static const MethodChannel _channel = MethodChannel(
    'com.niki.xxread/source_interactive_browser',
  );

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<SourceInteractiveBrowserResult> open({
    required Uri url,
    required Map<String, String> headers,
    String? html,
  }) async {
    if (!isSupported) {
      throw const BookSourceProtocolException(
        'Interactive reading source verification is currently available on Android.',
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('open', {
        'url': url.toString(),
        'headers': headers,
        'html': html,
      });
      final body = result?['body'];
      final finalUrl = result?['finalUrl'];
      final parsed = finalUrl is String ? Uri.tryParse(finalUrl) : null;
      if (body is! String || parsed == null) {
        throw const BookSourceProtocolException(
          'Interactive browser returned an invalid result.',
        );
      }
      return SourceInteractiveBrowserResult(
        body: body,
        finalUri: parsed,
        cookieHeader: result?['cookieHeader'] as String?,
      );
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') {
        throw const SourceInteractiveBrowserCancelled();
      }
      throw BookSourceProtocolException(
        error.message ?? 'Interactive reading source verification failed.',
      );
    }
  }
}
