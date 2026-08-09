import '../protocol/book_source_protocol.dart';
import 'source_rule_engine.dart';
import 'source_script_contract.dart';

abstract interface class SourceRuntimeRulePort {
  SourceRuleDocument document(
    String body,
    Uri baseUri, {
    required SourceScriptContext scriptContext,
    Map<String, Object?>? ruleState,
  });

  Future<List<Object?>> list(
    SourceRuleDocument document,
    Object? context,
    String rule,
  );

  Future<String> value(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    bool required,
    String joinSeparator,
    bool regexDotAll,
  });

  Future<String> url(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  );

  Future<String> evaluateUrl(
    SourceRuleDocument document,
    Object? context,
    String rule,
  );

  String replace(String value, String rule);
  String requiredRule(Map<String, dynamic> rules, String key);
  String optionalRule(Map<String, dynamic> rules, String key);
}

class SourceRuntimeRules implements SourceRuntimeRulePort {
  SourceRuntimeRules(SourceRuleEngine engine) : _engine = engine;

  final SourceRuleEngine _engine;

  @override
  SourceRuleDocument document(
    String body,
    Uri baseUri, {
    required SourceScriptContext scriptContext,
    Map<String, Object?>? ruleState,
  }) => SourceRuleDocument.parse(
    body,
    baseUri,
    ruleState: ruleState ?? <String, Object?>{},
    scriptContext: scriptContext,
  );

  @override
  Future<List<Object?>> list(
    SourceRuleDocument document,
    Object? context,
    String rule,
  ) => _engine.evaluateListAsync(document, context, rule);

  @override
  Future<String> value(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    bool required = false,
    String joinSeparator = '',
    bool regexDotAll = true,
  }) async {
    final rule = required ? requiredRule(rules, key) : optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _engine.evaluateStringAsync(
      document,
      context,
      rule,
      joinSeparator: joinSeparator,
      regexDotAll: regexDotAll,
    );
  }

  @override
  Future<String> url(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final rule = optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return evaluateUrl(document, context, rule);
  }

  @override
  Future<String> evaluateUrl(
    SourceRuleDocument document,
    Object? context,
    String rule,
  ) => _engine.evaluateStringAsync(document, context, rule, resolveUrl: true);

  @override
  String replace(String value, String rule) =>
      _engine.applyReplaceRule(value, rule);

  @override
  String requiredRule(Map<String, dynamic> rules, String key) {
    final rule = optionalRule(rules, key);
    if (rule.isEmpty) {
      throw BookSourceProtocolException(
        'Compatible source is missing the $key rule.',
      );
    }
    return rule;
  }

  @override
  String optionalRule(Map<String, dynamic> rules, String key) {
    final value = rules[key];
    return value is String ? value.trim() : '';
  }
}
