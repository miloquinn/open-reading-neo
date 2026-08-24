import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'replace_rule_executor.dart';
import 'replace_rule_semantics.dart';

class ReplaceRule {
  const ReplaceRule({
    required this.id,
    required this.name,
    required this.pattern,
    required this.replacement,
    this.group = '',
    this.scope = '',
    this.excludeScope = '',
    this.enabled = true,
    this.isRegex = true,
    this.scopeTitle = false,
    this.scopeContent = true,
    this.order = 0,
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

  ReplaceRule copyWith({
    String? id,
    String? name,
    String? pattern,
    String? replacement,
    String? group,
    String? scope,
    String? excludeScope,
    bool? enabled,
    bool? isRegex,
    bool? scopeTitle,
    bool? scopeContent,
    int? order,
  }) => ReplaceRule(
    id: id ?? this.id,
    name: name ?? this.name,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    group: group ?? this.group,
    scope: scope ?? this.scope,
    excludeScope: excludeScope ?? this.excludeScope,
    enabled: enabled ?? this.enabled,
    isRegex: isRegex ?? this.isRegex,
    scopeTitle: scopeTitle ?? this.scopeTitle,
    scopeContent: scopeContent ?? this.scopeContent,
    order: order ?? this.order,
  );

  Map<String, dynamic> toJson() => {
    'id': int.tryParse(id) ?? id,
    'name': name,
    'pattern': pattern,
    'replacement': replacement,
    'group': group,
    'scope': scope,
    'excludeScope': excludeScope,
    'isEnabled': enabled,
    'isRegex': isRegex,
    'scopeTitle': scopeTitle,
    'scopeContent': scopeContent,
    'order': order,
  };

  factory ReplaceRule.fromJson(Map<String, dynamic> json, int index) {
    final pattern = '${json['pattern'] ?? json['regex'] ?? ''}';
    if (pattern.trim().isEmpty) {
      throw const ReplaceRuleValidationException(
        ReplaceRuleValidationKind.emptyPattern,
      );
    }
    final legacyFormat =
        !json.containsKey('pattern') && json.containsKey('regex');
    return ReplaceRule(
      id: '${json['id'] ?? DateTime.now().microsecondsSinceEpoch + index}',
      name: '${json['name'] ?? json['replaceSummary'] ?? '导入规则'}',
      pattern: pattern,
      replacement: '${json['replacement'] ?? ''}',
      group: '${json['group'] ?? ''}',
      scope: '${json['scope'] ?? json['useTo'] ?? ''}',
      excludeScope: '${json['excludeScope'] ?? ''}',
      enabled: _jsonBool(
        json['enabled'] ?? json['isEnabled'] ?? json['enable'],
        fallback: true,
      ),
      isRegex: _jsonBool(json['isRegex'], fallback: !legacyFormat),
      scopeTitle: _jsonBool(json['scopeTitle'], fallback: false),
      scopeContent: _jsonBool(json['scopeContent'], fallback: true),
      order:
          _jsonInt(
            json['order'] ?? json['sortOrder'] ?? json['serialNumber'],
          ) ??
          index,
    );
  }
}

enum ReplaceRuleValidationKind {
  emptyPattern,
  patternTooLong,
  invalidRegex,
  tooManyRules,
}

class ReplaceRuleValidationException extends FormatException {
  const ReplaceRuleValidationException(this.kind, [String detail = ''])
    : super(detail);

  final ReplaceRuleValidationKind kind;
}

bool _jsonBool(Object? value, {required bool fallback}) => switch (value) {
  final bool value => value,
  final num value => value != 0,
  final String value when value.toLowerCase() == 'true' || value == '1' => true,
  final String value when value.toLowerCase() == 'false' || value == '0' =>
    false,
  _ => fallback,
};

int? _jsonInt(Object? value) => switch (value) {
  final num value => value.toInt(),
  final String value => int.tryParse(value),
  _ => null,
};

class ReplaceRuleService extends ChangeNotifier {
  ReplaceRuleService._();
  static final ReplaceRuleService instance = ReplaceRuleService._();
  static const preferenceKey = 'reader_replace_rules_v1';
  static const maxRules = 5000;
  static const maxPatternLength = 20000;
  static const maxImportBytes = 8 * 1024 * 1024;

  List<ReplaceRule> _rules = const [];
  bool _loaded = false;
  Future<void>? _loading;
  int _revision = 0;
  String? _rulesSignatureCache;
  ReplaceRuleExecutor _executor = ReplaceRuleExecutor();
  final List<ReplaceRuleDiagnostic> _recentDiagnostics =
      <ReplaceRuleDiagnostic>[];
  StreamSubscription<ReplaceRuleDiagnostic>? _diagnosticSubscription;

  List<ReplaceRule> get rules => _rules;
  bool get isLoaded => _loaded;
  int get revision => _revision;
  String get rulesSignature => _rulesSignatureCache ??= _buildRulesSignature();

  String _buildRulesSignature() {
    final payload = enabledRules
        .map(
          (rule) => jsonEncode(<Object?>[
            rule.id,
            rule.pattern,
            rule.replacement,
            rule.scope,
            rule.excludeScope,
            rule.isRegex,
            rule.scopeTitle,
            rule.scopeContent,
            rule.order,
          ]),
        )
        .join('\u0000');
    return 'replace-rules-v2:${sha1.convert(utf8.encode(payload))}';
  }

  List<ReplaceRuleDiagnostic> get recentDiagnostics =>
      List<ReplaceRuleDiagnostic>.unmodifiable(_recentDiagnostics);
  List<ReplaceRule> get enabledRules =>
      _rules.where((rule) => rule.enabled).toList(growable: false);

  Future<void> load() {
    if (_loaded) return Future.value();
    _listenToExecutorDiagnostics();
    return _loading ??= _loadInternal();
  }

  void _listenToExecutorDiagnostics() {
    _diagnosticSubscription ??= _executor.diagnostics.listen((diagnostic) {
      _recentDiagnostics.add(diagnostic);
      if (_recentDiagnostics.length > 32) _recentDiagnostics.removeAt(0);
      debugPrint(
        'replacement rule ${diagnostic.kind.name}: '
        '${diagnostic.ruleName ?? diagnostic.ruleId ?? 'unknown'} '
        '${diagnostic.detail}',
      );
    });
  }

  Future<void> _loadInternal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _rules =
              decoded
                  .whereType<Map>()
                  .map(
                    (item) => ReplaceRule.fromJson(
                      Map<String, dynamic>.from(item),
                      0,
                    ),
                  )
                  .toList()
                ..sort((a, b) => a.order.compareTo(b.order));
        }
      }
    } catch (error) {
      debugPrint('replace rules load failed: $error');
      _rules = const [];
    } finally {
      _loaded = true;
      _revision++;
      _rulesSignatureCache = null;
      _loading = null;
      notifyListeners();
    }
  }

  Future<void> saveAll(List<ReplaceRule> rules) async {
    if (rules.length > maxRules) {
      throw const ReplaceRuleValidationException(
        ReplaceRuleValidationKind.tooManyRules,
      );
    }
    final normalized = rules
        .asMap()
        .entries
        .map((entry) => entry.value.copyWith(order: entry.key))
        .toList(growable: false);
    for (final rule in normalized) {
      validate(rule);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      preferenceKey,
      jsonEncode(normalized.map((rule) => rule.toJson()).toList()),
    );
    _rules = normalized;
    _loaded = true;
    _revision++;
    _rulesSignatureCache = null;
    notifyListeners();
  }

  Future<void> upsert(ReplaceRule rule) async {
    final next = [..._rules];
    final index = next.indexWhere((item) => item.id == rule.id);
    if (index < 0) {
      next.add(rule.copyWith(order: next.length));
    } else {
      next[index] = rule.copyWith(order: next[index].order);
    }
    await saveAll(next);
  }

  Future<void> remove(String id) =>
      saveAll(_rules.where((rule) => rule.id != id).toList());

  Future<void> toggle(String id, bool enabled) async {
    await saveAll(
      _rules
          .map((rule) => rule.id == id ? rule.copyWith(enabled: enabled) : rule)
          .toList(),
    );
  }

  static void validate(ReplaceRule rule) {
    if (rule.pattern.trim().isEmpty) {
      throw const ReplaceRuleValidationException(
        ReplaceRuleValidationKind.emptyPattern,
      );
    }
    if (rule.pattern.length > maxPatternLength) {
      throw const ReplaceRuleValidationException(
        ReplaceRuleValidationKind.patternTooLong,
      );
    }
    if (rule.isRegex) {
      try {
        compileReplaceRulePattern(rule.pattern);
      } on FormatException catch (error) {
        throw ReplaceRuleValidationException(
          ReplaceRuleValidationKind.invalidRegex,
          error.message,
        );
      }
    }
  }

  List<ReplaceRule> mergeImported(Iterable<ReplaceRule> imported) {
    final merged = [..._rules];
    for (final rule in imported) {
      validate(rule);
      final index = merged.indexWhere(
        (existing) =>
            existing.id == rule.id ||
            (existing.name == rule.name && existing.pattern == rule.pattern),
      );
      if (index < 0) {
        merged.add(rule);
      } else {
        merged[index] = rule.copyWith(order: merged[index].order);
      }
    }
    if (merged.length > maxRules) {
      throw const ReplaceRuleValidationException(
        ReplaceRuleValidationKind.tooManyRules,
      );
    }
    return merged;
  }

  Future<ReplaceRuleExecutionResult> applyBatchAsync(
    List<String> inputs, {
    required String bookTitle,
    String? sourceName,
    bool title = false,
    bool preserveNonEmpty = true,
  }) async {
    await load();
    final signature = rulesSignature;
    final executionRules = enabledRules
        .map(_executionRule)
        .where(
          (rule) =>
              (title ? rule.scopeTitle : rule.scopeContent) &&
              replaceRuleMatchesScope(rule, bookTitle, sourceName),
        )
        .toList(growable: false);
    if (executionRules.isEmpty || inputs.isEmpty) {
      return ReplaceRuleExecutionResult(values: List<String>.from(inputs));
    }
    // Literal-only pipelines have deterministic linear behavior and are
    // cheaper to execute directly than to copy chapter/catalog strings through
    // an isolate. Every regex pipeline still uses the killable worker below.
    if (executionRules.every((rule) => !rule.isRegex)) {
      final prepared = executionRules.map(PreparedReplaceRule.new).toList();
      final outputLimit = replaceRuleOutputCharacterLimit(inputs);
      final values = <String>[];
      final diagnostics = <ReplaceRuleDiagnostic>[];
      var degraded = false;
      for (final input in inputs) {
        var output = input;
        for (final rule in prepared) {
          output = rule.apply(output);
          if (output.length > outputLimit) {
            output = input;
            diagnostics.add(
              ReplaceRuleDiagnostic(
                kind: ReplaceRuleDiagnosticKind.outputLimit,
                rulesSignature: signature,
                ruleId: rule.source.id,
                ruleName: rule.source.name,
                ruleFingerprint: rule.source.fingerprint,
                detail: 'Replacement output exceeded the safety limit.',
              ),
            );
            degraded = true;
            break;
          }
        }
        if (preserveNonEmpty &&
            input.trim().isNotEmpty &&
            output.trim().isEmpty) {
          output = input;
          diagnostics.add(
            ReplaceRuleDiagnostic(
              kind: ReplaceRuleDiagnosticKind.emptyOutput,
              rulesSignature: signature,
              detail:
                  'Replacement rules removed all readable text; original retained.',
            ),
          );
          degraded = true;
        }
        values.add(output);
      }
      return ReplaceRuleExecutionResult(
        values: values,
        diagnostics: diagnostics,
        degraded: degraded,
      );
    }
    final executedValues = <String>[];
    final executedDiagnostics = <ReplaceRuleDiagnostic>[];
    final skippedRuleIds = <String>{};
    var executedDegraded = false;
    for (final batchInputs in _replaceRuleInputBatches(inputs)) {
      final batchResult = await _executor.applyBatch(
        ReplaceRuleExecutionBatch(
          values: batchInputs,
          rules: executionRules,
          rulesSignature: signature,
          bookTitle: bookTitle,
          sourceName: sourceName,
          target: title ? ReplaceRuleTarget.title : ReplaceRuleTarget.content,
        ),
      );
      executedValues.addAll(batchResult.values);
      executedDiagnostics.addAll(batchResult.diagnostics);
      skippedRuleIds.addAll(batchResult.skippedRuleIds);
      executedDegraded = executedDegraded || batchResult.degraded;
    }
    final result = ReplaceRuleExecutionResult(
      values: executedValues,
      diagnostics: executedDiagnostics,
      skippedRuleIds: skippedRuleIds.toList(growable: false),
      degraded: executedDegraded,
    );
    if (!preserveNonEmpty) return result;
    final values = <String>[];
    final diagnostics = <ReplaceRuleDiagnostic>[...result.diagnostics];
    var degraded = result.degraded;
    for (var index = 0; index < inputs.length; index++) {
      final original = inputs[index];
      final cleaned = result.values[index];
      if (original.trim().isNotEmpty && cleaned.trim().isEmpty) {
        values.add(original);
        diagnostics.add(
          ReplaceRuleDiagnostic(
            kind: ReplaceRuleDiagnosticKind.emptyOutput,
            rulesSignature: signature,
            detail:
                'Replacement rules removed all readable text; original retained.',
          ),
        );
        degraded = true;
      } else {
        values.add(cleaned);
      }
    }
    return ReplaceRuleExecutionResult(
      values: values,
      diagnostics: diagnostics,
      skippedRuleIds: result.skippedRuleIds,
      degraded: degraded,
    );
  }

  Iterable<List<String>> _replaceRuleInputBatches(List<String> inputs) sync* {
    const maximumBatchCharacters = 512 * 1024;
    var batch = <String>[];
    var characters = 0;
    for (final input in inputs) {
      if (batch.isNotEmpty &&
          characters + input.length > maximumBatchCharacters) {
        yield batch;
        batch = <String>[];
        characters = 0;
      }
      batch.add(input);
      characters += input.length;
    }
    if (batch.isNotEmpty) yield batch;
  }

  Future<String> applyAsync(
    String input, {
    required String bookTitle,
    String? sourceName,
    bool title = false,
    bool preserveNonEmpty = true,
  }) async {
    final result = await applyBatchAsync(
      <String>[input],
      bookTitle: bookTitle,
      sourceName: sourceName,
      title: title,
      preserveNonEmpty: preserveNonEmpty,
    );
    return result.values.single;
  }

  String apply(
    String input, {
    required String bookTitle,
    String? sourceName,
    bool title = false,
  }) {
    return applyRules(
      enabledRules,
      input,
      bookTitle: bookTitle,
      sourceName: sourceName,
      title: title,
    );
  }

  String applyRules(
    Iterable<ReplaceRule> rules,
    String input, {
    required String bookTitle,
    String? sourceName,
    bool title = false,
  }) {
    var output = input;
    for (final rule in rules.where((rule) => rule.enabled)) {
      if (title ? !rule.scopeTitle : !rule.scopeContent) continue;
      if (!_matchesScope(rule, bookTitle, sourceName)) continue;
      try {
        if (rule.isRegex) {
          output = output.replaceAllMapped(
            compileReplaceRulePattern(rule.pattern),
            (match) => expandReplaceRuleReplacement(rule.replacement, match),
          );
        } else {
          output = output.replaceAll(rule.pattern, rule.replacement);
        }
      } on FormatException {
        // Invalid rules are rejected on save/import; a corrupt legacy entry
        // must not prevent the reader from opening the book.
      }
    }
    return output;
  }

  bool _matchesScope(ReplaceRule rule, String title, String? source) {
    final haystack = '$title ${source ?? ''}'.toLowerCase();
    bool contains(String value) => value
        .split(RegExp(r'[;,\n]'))
        .map((item) => item.trim().toLowerCase())
        .where((item) => item.isNotEmpty)
        .any(haystack.contains);
    if (contains(rule.excludeScope)) return false;
    return rule.scope.trim().isEmpty || contains(rule.scope);
  }

  static List<ReplaceRule> decodeImport(String text) {
    final decoded = jsonDecode(text.replaceFirst('\ufeff', '').trim());
    final items = decoded is List
        ? decoded
        : decoded is Map && decoded['rules'] is List
        ? decoded['rules'] as List
        : decoded is Map
        ? [decoded]
        : const [];
    if (items.length > maxRules) {
      throw const ReplaceRuleValidationException(
        ReplaceRuleValidationKind.tooManyRules,
      );
    }
    return items
        .asMap()
        .entries
        .map((entry) {
          final value = entry.value;
          if (value is! Map) {
            throw const FormatException('Rule entry must be an object');
          }
          final rule = ReplaceRule.fromJson(
            Map<String, dynamic>.from(value),
            entry.key,
          );
          validate(rule);
          return rule;
        })
        .toList(growable: false);
  }

  ReplaceRuleExecutionRule _executionRule(ReplaceRule rule) =>
      ReplaceRuleExecutionRule(
        id: rule.id,
        name: rule.name,
        pattern: rule.pattern,
        replacement: rule.replacement,
        group: rule.group,
        scope: rule.scope,
        excludeScope: rule.excludeScope,
        enabled: rule.enabled,
        isRegex: rule.isRegex,
        scopeTitle: rule.scopeTitle,
        scopeContent: rule.scopeContent,
        order: rule.order,
      );

  @visibleForTesting
  void resetForTesting() {
    _rules = const [];
    _loaded = false;
    _loading = null;
    _revision = 0;
    _rulesSignatureCache = null;
    _recentDiagnostics.clear();
    unawaited(_diagnosticSubscription?.cancel());
    _diagnosticSubscription = null;
    unawaited(_executor.dispose());
    _executor = ReplaceRuleExecutor();
  }
}
