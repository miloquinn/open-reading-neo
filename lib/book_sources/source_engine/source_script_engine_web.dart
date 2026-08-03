import '../protocol/book_source_protocol.dart';
import 'source_config.dart';

class SourceScriptContext {
  const SourceScriptContext({
    required this.source,
    this.result,
    this.baseUrl,
    this.variables = const {},
    this.networkHandler,
  });

  final ReadingSourceConfig source;
  final Object? result;
  final Uri? baseUrl;
  final Map<String, String> variables;
  final Future<SourceScriptNetworkResult> Function(
    SourceScriptNetworkRequest request,
  )?
  networkHandler;
}

class SourceScriptNetworkResult {
  const SourceScriptNetworkResult({required this.body, required this.finalUrl});

  final String body;
  final String finalUrl;

  Map<String, Object?> toJson() => {'body': body, 'finalUrl': finalUrl};
}

class SourceScriptNetworkRequest {
  const SourceScriptNetworkRequest({
    required this.signature,
    required this.method,
    required this.url,
    this.body,
    this.headers = const {},
    this.webJs,
  });

  final String signature;
  final String method;
  final String url;
  final String? body;
  final Map<String, String> headers;
  final String? webJs;
}

abstract class SourceScriptEvaluator {
  Object? evaluate(String script, SourceScriptContext context);

  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  void dispose();
}

class QuickJsSourceScriptEvaluator implements SourceScriptEvaluator {
  @override
  Object? evaluate(String script, SourceScriptContext context) {
    throw const BookSourceProtocolException(
      'Script-based reading source rules are not supported on Web.',
    );
  }

  @override
  Future<Object?> evaluateAsync(
    String script,
    SourceScriptContext context,
  ) async => evaluate(script, context);

  @override
  void dispose() {}
}
