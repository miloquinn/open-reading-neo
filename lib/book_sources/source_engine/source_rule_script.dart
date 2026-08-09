import '../protocol/book_source_protocol.dart';
import 'source_request_template.dart';
import 'source_rule_parser.dart';
import 'source_rule_port.dart';
import 'source_rule_regex.dart';
import 'source_script_contract.dart';

class SourceRuleScript {
  const SourceRuleScript({
    required this.selectors,
    required this.scriptEvaluatorProvider,
  });

  final SourceRuleSelectorPort selectors;
  final SourceScriptEvaluator Function()? scriptEvaluatorProvider;

  Object? evaluateInline(
    SourceRuleDocument document,
    Object? result,
    String script,
  ) => _evaluate(document, result, script);

  Future<Object?> evaluateInlineAsync(
    SourceRuleDocument document,
    Object? result,
    String script,
  ) => _evaluateAsync(document, result, script);

  List<Object?> evaluatePutList(
    SourceRuleDocument document,
    Object? context,
    SourcePutRule putRule,
  ) {
    final values = putRule.selector.trim().isEmpty
        ? <Object?>[context ?? document.value]
        : selectors.evaluateList(document, context, putRule.selector);
    _storePutMappings(document, context, putRule.mappings);
    return values;
  }

  Future<List<Object?>> evaluatePutListAsync(
    SourceRuleDocument document,
    Object? context,
    SourcePutRule putRule,
  ) async {
    final values = putRule.selector.trim().isEmpty
        ? <Object?>[context ?? document.value]
        : await selectors.evaluateListAsync(
            document,
            context,
            putRule.selector,
          );
    await _storePutMappingsAsync(document, context, putRule.mappings);
    return values;
  }

  String evaluatePutString(
    SourceRuleDocument document,
    Object? context,
    SourcePutRule putRule, {
    required bool resolveUrl,
  }) {
    final value = putRule.selector.trim().isEmpty
        ? sourceRuleStringValue(context ?? document.value)
        : selectors.evaluateString(
            document,
            context,
            putRule.selector,
            resolveUrl: resolveUrl,
          );
    _storePutMappings(document, context, putRule.mappings);
    return value;
  }

  Future<String> evaluatePutStringAsync(
    SourceRuleDocument document,
    Object? context,
    SourcePutRule putRule, {
    required bool resolveUrl,
    required String joinSeparator,
    required bool regexDotAll,
  }) async {
    final value = putRule.selector.trim().isEmpty
        ? sourceRuleStringValue(context ?? document.value)
        : await selectors.evaluateStringAsync(
            document,
            context,
            putRule.selector,
            resolveUrl: resolveUrl,
            joinSeparator: joinSeparator,
            regexDotAll: regexDotAll,
          );
    await _storePutMappingsAsync(document, context, putRule.mappings);
    return value;
  }

  List<Object?> evaluateScriptedList(
    SourceRuleDocument document,
    Object? context,
    SourceScriptRule scripted,
  ) {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : selectors.evaluateList(document, context, scripted.selector);
    final output = _evaluate(document, input, scripted.script);
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _outputDocument(document, output);
      return selectors.evaluateList(
        nextDocument,
        nextDocument.value,
        scripted.suffix,
      );
    }
    if (output is Iterable) return output.toList(growable: false);
    return output == null ? const [] : [output];
  }

  Future<List<Object?>> evaluateScriptedListAsync(
    SourceRuleDocument document,
    Object? context,
    SourceScriptRule scripted,
  ) async {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : await selectors.evaluateListAsync(
            document,
            context,
            scripted.selector,
          );
    final output = await _evaluateAsync(document, input, scripted.script);
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _outputDocument(document, output);
      return selectors.evaluateListAsync(
        nextDocument,
        nextDocument.value,
        scripted.suffix,
      );
    }
    if (output is Iterable) return output.toList(growable: false);
    return output == null ? const [] : [output];
  }

  String evaluateScriptedString(
    SourceRuleDocument document,
    Object? context,
    SourceScriptRule scripted, {
    required bool resolveUrl,
  }) {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : selectors.evaluateString(document, context, scripted.selector);
    final output = _evaluate(document, input, scripted.script);
    var value = '';
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _outputDocument(document, output);
      value = selectors.evaluateString(
        nextDocument,
        nextDocument.value,
        scripted.suffix,
      );
    } else if (output is Iterable && output is! String) {
      value = output.map(sourceRuleStringValue).join();
    } else {
      value = sourceRuleStringValue(output);
    }
    value = value.trim();
    if (resolveUrl && value.isNotEmpty) {
      return _resolveUrl(
        document.baseUri,
        value,
        'reading source script produced a non-HTTP URL.',
      );
    }
    return value;
  }

  Future<String> evaluateScriptedStringAsync(
    SourceRuleDocument document,
    Object? context,
    SourceScriptRule scripted, {
    required bool resolveUrl,
    required String joinSeparator,
    required bool regexDotAll,
  }) async {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : await selectors.evaluateStringAsync(
            document,
            context,
            scripted.selector,
            joinSeparator: joinSeparator,
            regexDotAll: regexDotAll,
          );
    final output = await _evaluateAsync(document, input, scripted.script);
    var value = '';
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _outputDocument(document, output);
      value = await selectors.evaluateStringAsync(
        nextDocument,
        nextDocument.value,
        scripted.suffix,
        joinSeparator: joinSeparator,
        regexDotAll: regexDotAll,
      );
    } else if (output is Iterable && output is! String) {
      value = output.map(sourceRuleStringValue).join(joinSeparator);
    } else {
      value = sourceRuleStringValue(output);
    }
    value = value.trim();
    if (resolveUrl && value.isNotEmpty) {
      return _resolveUrl(
        document.baseUri,
        value,
        'Source script produced a non-HTTP URL.',
      );
    }
    return value;
  }

  void _storePutMappings(
    SourceRuleDocument document,
    Object? context,
    Map<String, String> mappings,
  ) {
    for (final entry in mappings.entries) {
      document.ruleState[entry.key] = selectors.evaluateString(
        document,
        context,
        entry.value,
      );
    }
  }

  Future<void> _storePutMappingsAsync(
    SourceRuleDocument document,
    Object? context,
    Map<String, String> mappings,
  ) async {
    for (final entry in mappings.entries) {
      document.ruleState[entry.key] = await selectors.evaluateStringAsync(
        document,
        context,
        entry.value,
      );
    }
  }

  Object? _evaluate(
    SourceRuleDocument document,
    Object? result,
    String script,
  ) {
    final evaluator = scriptEvaluatorProvider?.call();
    final context = document.scriptContext;
    if (evaluator == null || context == null) {
      throw const BookSourceProtocolException(
        'This reading source needs JavaScript execution.',
      );
    }
    return evaluator.evaluate(
      script,
      _context(context, document.baseUri, result, asynchronous: false),
    );
  }

  Future<Object?> _evaluateAsync(
    SourceRuleDocument document,
    Object? result,
    String script,
  ) {
    final evaluator = scriptEvaluatorProvider?.call();
    final context = document.scriptContext;
    if (evaluator == null || context == null) {
      throw const BookSourceProtocolException(
        'This reading source needs JavaScript execution.',
      );
    }
    return evaluator.evaluateAsync(
      script,
      _context(context, document.baseUri, result, asynchronous: true),
    );
  }

  SourceRuleDocument _outputDocument(
    SourceRuleDocument previous,
    Object? output,
  ) {
    if (output is String) {
      return SourceRuleDocument.parse(
        output,
        previous.baseUri,
        scriptContext: previous.scriptContext,
        ruleState: previous.ruleState,
      );
    }
    return SourceRuleDocument.fromValue(
      output,
      previous.baseUri,
      scriptContext: previous.scriptContext,
      ruleState: previous.ruleState,
    );
  }

  SourceScriptContext _context(
    SourceScriptContext context,
    Uri baseUri,
    Object? result, {
    required bool asynchronous,
  }) {
    return SourceScriptContext(
      source: context.source,
      result: sourceRuleScriptInput(result),
      baseUrl: baseUri,
      variables: context.variables,
      book: context.book,
      chapter: context.chapter,
      bookWriter: context.bookWriter,
      chapterWriter: context.chapterWriter,
      networkHandler: asynchronous ? context.networkHandler : null,
      cookieReader: context.cookieReader,
      cookieWriter: context.cookieWriter,
      cookieRemover: context.cookieRemover,
      loginInfo: context.loginInfo,
      loginHeaders: context.loginHeaders,
      loginInfoWriter: context.loginInfoWriter,
      loginHeaderWriter: context.loginHeaderWriter,
      interactionHandler: context.interactionHandler,
    );
  }
}

String _resolveUrl(Uri baseUri, String value, String errorMessage) {
  final urlText = value.split(RegExp(r',\s*\{')).first.trim();
  final directUri = Uri.tryParse(urlText);
  if (directUri?.scheme == 'data') return value;
  final resolved = resolveSourceRequestUrl(baseUri, value);
  final uri = Uri.tryParse(resolved.split(RegExp(r',\s*\{')).first);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw BookSourceProtocolException(errorMessage);
  }
  return resolved;
}
