import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  List<ReplaceRule> get rules => _rules;
  bool get isLoaded => _loaded;
  List<ReplaceRule> get enabledRules =>
      _rules.where((rule) => rule.enabled).toList(growable: false);

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _loadInternal();
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
        _compileReplacePattern(rule.pattern);
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
            _compileReplacePattern(rule.pattern),
            (match) => _expandReplacement(rule.replacement, match),
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

  String _expandReplacement(String replacement, Match match) {
    return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (token) {
      final index = int.tryParse(token.group(1) ?? '');
      if (index == null || index > match.groupCount) return token.group(0)!;
      return match.group(index) ?? '';
    });
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

  @visibleForTesting
  void resetForTesting() {
    _rules = const [];
    _loaded = false;
    _loading = null;
  }
}

final RegExp _inlineFlags = RegExp(r'\(\?([ims]+)\)');

RegExp _compileReplacePattern(String pattern) {
  var source = pattern;
  var caseSensitive = true;
  var multiLine = false;
  var dotAll = false;
  // Legado/JVM sources commonly place flags at the beginning or after an
  // alternation. Dart takes these options on the RegExp constructor instead.
  source = source.replaceAllMapped(_inlineFlags, (match) {
    final flags = match.group(1)!;
    if (flags.contains('i')) caseSensitive = false;
    if (flags.contains('m')) multiLine = true;
    if (flags.contains('s')) dotAll = true;
    return '';
  });
  // Java's horizontal whitespace class has no Dart spelling. Keep newlines
  // out so line-oriented cleanup rules retain their source boundaries.
  source = _replaceHorizontalWhitespace(source);
  return RegExp(
    source,
    caseSensitive: caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
  );
}

String _replaceHorizontalWhitespace(String source) {
  final output = StringBuffer();
  var inClass = false;
  for (var index = 0; index < source.length; index++) {
    final character = source[index];
    if (character == r'\' && index + 1 < source.length) {
      final escaped = source[index + 1];
      if (escaped == 'h') {
        output.write(inClass ? r'\t ' : r'(?:\t| )');
        index++;
        continue;
      }
      if (escaped == 'H') {
        output.write(inClass ? r'\s\S' : r'[\s\S]');
        index++;
        continue;
      }
      output.write(character);
      output.write(escaped);
      index++;
      continue;
    }
    if (character == '[') inClass = true;
    if (character == ']' && inClass) inClass = false;
    output.write(character);
  }
  return output.toString();
}
