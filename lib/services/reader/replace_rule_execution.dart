import 'dart:convert';

/// Whether a replacement pipeline is cleaning display titles or body text.
enum ReplaceRuleTarget { title, content }

/// Isolate-safe, immutable representation of one replacement rule.
///
/// The persistence model deliberately stays in [ReplaceRuleService]. Workers
/// receive only primitive values so they never depend on plugins, Flutter
/// bindings, or process-global state.
class ReplaceRuleExecutionRule {
  const ReplaceRuleExecutionRule({
    required this.id,
    required this.name,
    required this.pattern,
    required this.replacement,
    required this.group,
    required this.scope,
    required this.excludeScope,
    required this.enabled,
    required this.isRegex,
    required this.scopeTitle,
    required this.scopeContent,
    required this.order,
  });

  final String id;
  final String name;
  final String pattern;
  final String replacement;
  final String group;
  final String scope;
  final String excludeScope;
  final bool enabled;
  final bool isRegex;
  final bool scopeTitle;
  final bool scopeContent;
  final int order;

  /// Stable within and across processes. It is intentionally independent of
  /// list position so a timed-out rule remains identifiable after a reorder.
  String get fingerprint => jsonEncode(<Object?>[
    id,
    pattern,
    replacement,
    isRegex,
    scopeTitle,
    scopeContent,
    scope,
    excludeScope,
  ]);

  Map<String, Object?> toMessage() => <String, Object?>{
    'id': id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'group': group,
    'scope': scope,
    'excludeScope': excludeScope,
    'enabled': enabled,
    'isRegex': isRegex,
    'scopeTitle': scopeTitle,
    'scopeContent': scopeContent,
    'order': order,
    'fingerprint': fingerprint,
  };

  factory ReplaceRuleExecutionRule.fromMessage(Map<Object?, Object?> value) =>
      ReplaceRuleExecutionRule(
        id: '${value['id'] ?? ''}',
        name: '${value['name'] ?? ''}',
        pattern: '${value['pattern'] ?? ''}',
        replacement: '${value['replacement'] ?? ''}',
        group: '${value['group'] ?? ''}',
        scope: '${value['scope'] ?? ''}',
        excludeScope: '${value['excludeScope'] ?? ''}',
        enabled: value['enabled'] == true,
        isRegex: value['isRegex'] == true,
        scopeTitle: value['scopeTitle'] == true,
        scopeContent: value['scopeContent'] == true,
        order: value['order'] as int? ?? 0,
      );
}

class ReplaceRuleExecutionBatch {
  const ReplaceRuleExecutionBatch({
    required this.values,
    required this.rules,
    required this.rulesSignature,
    required this.bookTitle,
    required this.target,
    this.sourceName,
  });

  final List<String> values;
  final List<ReplaceRuleExecutionRule> rules;
  final String rulesSignature;
  final String bookTitle;
  final String? sourceName;
  final ReplaceRuleTarget target;
}

enum ReplaceRuleDiagnosticKind {
  timeout,
  workerCrash,
  invalidRegex,
  outputLimit,
  regexUnavailable,
  emptyOutput,
}

class ReplaceRuleDiagnostic {
  const ReplaceRuleDiagnostic({
    required this.kind,
    required this.rulesSignature,
    this.ruleId,
    this.ruleName,
    this.ruleFingerprint,
    this.detail = '',
  });

  final ReplaceRuleDiagnosticKind kind;
  final String rulesSignature;
  final String? ruleId;
  final String? ruleName;
  final String? ruleFingerprint;
  final String detail;
}

class ReplaceRuleExecutionResult {
  const ReplaceRuleExecutionResult({
    required this.values,
    this.diagnostics = const <ReplaceRuleDiagnostic>[],
    this.skippedRuleIds = const <String>[],
    this.degraded = false,
  });

  final List<String> values;
  final List<ReplaceRuleDiagnostic> diagnostics;
  final List<String> skippedRuleIds;
  final bool degraded;
}
