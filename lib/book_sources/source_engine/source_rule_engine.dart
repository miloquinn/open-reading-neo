import 'package:html/dom.dart';

import '../protocol/book_source_protocol.dart';
import 'source_request_template.dart';
import 'source_rule_html.dart';
import 'source_rule_interpolation.dart';
import 'source_rule_json.dart';
import 'source_rule_parser.dart';
import 'source_rule_port.dart';
import 'source_rule_regex.dart';
import 'source_rule_script.dart';
import 'source_rule_xpath.dart';
import 'source_script_contract.dart';

export 'source_rule_port.dart' show SourceRuleDocument, SourceRuleSelectorPort;

class SourceRuleEngine implements SourceRuleSelectorPort {
  const SourceRuleEngine({this.scriptEvaluatorProvider});

  final SourceScriptEvaluator Function()? scriptEvaluatorProvider;

  SourceRuleScript get _scripts => SourceRuleScript(
    selectors: this,
    scriptEvaluatorProvider: scriptEvaluatorProvider,
  );

  @override
  List<Object?> evaluateList(
    SourceRuleDocument document,
    Object? context,
    String rule,
  ) {
    final putRule = splitSourcePutRule(rule);
    if (putRule != null) {
      return _scripts.evaluatePutList(document, context, putRule);
    }
    final scripted = splitSourceScriptRule(rule);
    if (scripted != null) {
      return _scripts.evaluateScriptedList(document, context, scripted);
    }
    final transformed = splitSourceRuleTransform(rule);
    if (transformed.selector.trimLeft().startsWith(':')) {
      return evaluateSourceRegexList(
        context ?? document.value,
        transformed.selector,
      );
    }
    final values = _interpolation(
      document,
    ).evaluateAlternatives(context, transformed.selector, listMode: true);
    return values.where((value) => value != null).toList(growable: false);
  }

  @override
  Future<List<Object?>> evaluateListAsync(
    SourceRuleDocument document,
    Object? context,
    String rule,
  ) async {
    final putRule = splitSourcePutRule(rule);
    if (putRule != null) {
      return _scripts.evaluatePutListAsync(document, context, putRule);
    }
    final scripted = splitSourceScriptRule(rule);
    if (scripted != null) {
      return _scripts.evaluateScriptedListAsync(document, context, scripted);
    }
    final transformed = splitSourceRuleTransform(rule);
    if (transformed.selector.trimLeft().startsWith(':')) {
      return evaluateSourceRegexList(
        context ?? document.value,
        transformed.selector,
      );
    }
    final values = await _interpolation(
      document,
    ).evaluateAlternativesAsync(context, transformed.selector, listMode: true);
    return values.where((value) => value != null).toList(growable: false);
  }

  @override
  String evaluateString(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
  }) {
    final putRule = splitSourcePutRule(rule);
    if (putRule != null) {
      return _scripts.evaluatePutString(
        document,
        context,
        putRule,
        resolveUrl: resolveUrl,
      );
    }
    final scripted = splitSourceScriptRule(rule);
    if (scripted != null) {
      return _scripts.evaluateScriptedString(
        document,
        context,
        scripted,
        resolveUrl: resolveUrl,
      );
    }
    final transformed = splitSourceRuleTransform(rule);
    final selected = transformed.selector.trim().isEmpty
        ? _rawValues(document, context)
        : _interpolation(document).evaluateAlternatives(
            context,
            transformed.selector,
            listMode: false,
          );
    final values = selected
        .map(sourceRuleStringValue)
        .where((value) => value.isNotEmpty)
        .toList();
    var result = values.join();
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: true,
        );
        result =
            transformed.selector.trim().isEmpty &&
                transformed.replacement.isNotEmpty
            ? extractSourceRegex(result, pattern, transformed.replacement)
            : replaceSourceRegex(result, pattern, transformed.replacement);
      } on FormatException {
        throw const BookSourceProtocolException(
          'reading source rule contains an invalid regular expression.',
        );
      }
    }
    result = result.trim();
    if (resolveUrl && result.isNotEmpty) {
      return _resolveRuleRequestUrl(
        document.baseUri,
        result,
        'reading source rule produced a non-HTTP URL.',
      );
    }
    return result;
  }

  @override
  Future<String> evaluateStringAsync(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
    String joinSeparator = '',
    bool regexDotAll = true,
  }) async {
    final putRule = splitSourcePutRule(rule);
    if (putRule != null) {
      return _scripts.evaluatePutStringAsync(
        document,
        context,
        putRule,
        resolveUrl: resolveUrl,
        joinSeparator: joinSeparator,
        regexDotAll: regexDotAll,
      );
    }
    final scripted = splitSourceScriptRule(rule);
    if (scripted != null) {
      return _scripts.evaluateScriptedStringAsync(
        document,
        context,
        scripted,
        resolveUrl: resolveUrl,
        joinSeparator: joinSeparator,
        regexDotAll: regexDotAll,
      );
    }
    final transformed = splitSourceRuleTransform(rule);
    final selected = transformed.selector.trim().isEmpty
        ? _rawValues(document, context)
        : await _interpolation(document).evaluateAlternativesAsync(
            context,
            transformed.selector,
            listMode: false,
          );
    final values = selected
        .map(sourceRuleStringValue)
        .where((value) => value.isNotEmpty)
        .toList();
    var result = values.join(joinSeparator);
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: regexDotAll,
        );
        result =
            transformed.selector.trim().isEmpty &&
                transformed.replacement.isNotEmpty
            ? extractSourceRegex(result, pattern, transformed.replacement)
            : replaceSourceRegex(result, pattern, transformed.replacement);
      } on FormatException {
        throw const BookSourceProtocolException(
          'Source rule contains an invalid regular expression.',
        );
      }
    }
    result = result.trim();
    if (resolveUrl && result.isNotEmpty) {
      return _resolveRuleRequestUrl(
        document.baseUri,
        result,
        'Source rule produced a non-HTTP URL.',
      );
    }
    return result;
  }

  @override
  String applyReplaceRule(String input, String rule) {
    if (rule.trim().isEmpty) return input;
    final transformed = splitSourceRuleTransform(
      rule.trim().startsWith('##') ? rule : '##$rule',
    );
    if (transformed.pattern == null) return input;
    try {
      // Sources commonly ship a trailing `##.*some watermark.*` to strip one
      // injected line from otherwise multi-paragraph content. With `.`
      // crossing newlines, that greedy pattern matches from the start of the
      // string through the last occurrence of the watermark and erases the
      // entire chapter instead of just that line, so this mirrors the
      // reference engine's line-scoped (non-dotAll) regex semantics.
      return replaceSourceRegex(
        input,
        RegExp(transformed.pattern!, multiLine: true, dotAll: false),
        transformed.replacement,
      );
    } on FormatException {
      throw const BookSourceProtocolException(
        'reading source replacement contains an invalid regular expression.',
      );
    }
  }

  SourceRuleInterpolation _interpolation(SourceRuleDocument document) {
    return SourceRuleInterpolation(
      evaluateSingle: (context, rule, {required listMode}) =>
          _evaluateSingle(document, context, rule, listMode: listMode),
      evaluateSingleAsync: (context, rule, {required listMode}) =>
          _evaluateSingleAsync(document, context, rule, listMode: listMode),
      evaluateScript: (context, script) =>
          _scripts.evaluateInline(document, context, script),
      evaluateScriptAsync: (context, script) =>
          _scripts.evaluateInlineAsync(document, context, script),
    );
  }

  List<Object?> _evaluateSingle(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
  }) {
    var normalized = _normalizeSelector(rule);
    if (normalized.isEmpty) return const [];
    final expandedState = expandSourceRuleStateGets(
      normalized,
      document.ruleState,
    );
    final usedState = expandedState != normalized;
    normalized = expandedState;
    final root = context ?? document.value;
    if (root is SourceRegexRuleContext) return [root.expand(normalized)];
    if (normalized.contains('{{')) {
      return [_interpolation(document).interpolate(normalized, root)];
    }
    if (usedState) return [normalized];
    if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
        (normalized.startsWith("'") && normalized.endsWith("'"))) {
      return [normalized.substring(1, normalized.length - 1)];
    }
    if (looksLikeProtocolRelativeSourceUrl(normalized)) return [normalized];
    if (looksLikeSourceXPathRule(normalized)) {
      return evaluateSourceXPath(root, normalized, listMode: listMode);
    }
    final normalizedRule = normalized.toLowerCase().startsWith('@json:')
        ? normalized.substring(6)
        : normalized;
    if (root is Map || root is List || normalizedRule.startsWith(r'$.')) {
      return evaluateSourceJsonPath(root, normalizedRule);
    }
    final nodes = _htmlRoots(root);
    if (nodes == null) return [root];
    return evaluateSourceHtmlRule(nodes, normalized, listMode: listMode);
  }

  Future<List<Object?>> _evaluateSingleAsync(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
  }) async {
    var normalized = _normalizeSelector(rule);
    if (normalized.isEmpty) return const [];
    final expandedState = expandSourceRuleStateGets(
      normalized,
      document.ruleState,
    );
    final usedState = expandedState != normalized;
    normalized = expandedState;
    final root = context ?? document.value;
    if (root is SourceRegexRuleContext) return [root.expand(normalized)];
    if (normalized.contains('{{')) {
      return [
        await _interpolation(document).interpolateAsync(normalized, root),
      ];
    }
    if (usedState) return [normalized];
    if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
        (normalized.startsWith("'") && normalized.endsWith("'"))) {
      return [normalized.substring(1, normalized.length - 1)];
    }
    if (looksLikeProtocolRelativeSourceUrl(normalized)) return [normalized];
    if (looksLikeSourceXPathRule(normalized)) {
      return evaluateSourceXPath(root, normalized, listMode: listMode);
    }
    final normalizedRule = normalized.toLowerCase().startsWith('@json:')
        ? normalized.substring(6)
        : normalized;
    if (root is Map || root is List || normalizedRule.startsWith(r'$.')) {
      return evaluateSourceJsonPath(root, normalizedRule);
    }
    final nodes = _htmlRoots(root);
    if (nodes == null) return [root];
    return evaluateSourceHtmlRule(nodes, normalized, listMode: listMode);
  }

  String _normalizeSelector(String rule) {
    var normalized = rule.trim();
    if (normalized.startsWith('+')) {
      normalized = normalized.substring(1).trimLeft();
    }
    if (normalized.toLowerCase().startsWith('@css:')) {
      normalized = normalized.substring(5).trimLeft();
    }
    return normalized;
  }

  List<Element>? _htmlRoots(Object? root) {
    if (root is Document) return <Element>[root.documentElement!];
    if (root is Element) return <Element>[root];
    return null;
  }

  List<Object?> _rawValues(SourceRuleDocument document, Object? context) {
    final value = context ?? document.value;
    return switch (value) {
      Document document => [document.outerHtml],
      Element element => [element.outerHtml],
      _ => [value],
    };
  }
}

String _resolveRuleRequestUrl(Uri baseUri, String value, String errorMessage) {
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
