import '../protocol/book_source_protocol.dart';
import 'source_script_contract.dart';

export 'source_script_contract.dart';

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
