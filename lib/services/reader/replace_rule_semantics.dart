import 'replace_rule_execution.dart';

const int replaceRuleMaximumOutputCharacters = 16 * 1024 * 1024;
const int replaceRuleMaximumExpansionRatio = 32;

final RegExp _inlineFlags = RegExp(r'\(\?([ims]+)\)');
final RegExp _replacementCapture = RegExp(r'\$(\d+)');
final RegExp _scopeSeparator = RegExp(r'[;,\n]');

class PreparedReplaceRule {
  PreparedReplaceRule(ReplaceRuleExecutionRule rule)
    : source = rule,
      pattern = rule.isRegex ? compileReplaceRulePattern(rule.pattern) : null;

  final ReplaceRuleExecutionRule source;
  final RegExp? pattern;

  bool appliesTo(
    ReplaceRuleTarget target,
    String bookTitle,
    String? sourceName,
  ) {
    if (!source.enabled) return false;
    if (target == ReplaceRuleTarget.title
        ? !source.scopeTitle
        : !source.scopeContent) {
      return false;
    }
    return replaceRuleMatchesScope(source, bookTitle, sourceName);
  }

  String apply(String input) {
    if (source.isRegex) {
      return input.replaceAllMapped(
        pattern!,
        (match) => expandReplaceRuleReplacement(source.replacement, match),
      );
    }
    return input.replaceAll(source.pattern, source.replacement);
  }
}

List<PreparedReplaceRule> prepareReplaceRules(
  Iterable<ReplaceRuleExecutionRule> rules,
) {
  final ordered = rules.where((rule) => rule.enabled).toList(growable: false)
    ..sort((left, right) => left.order.compareTo(right.order));
  return ordered.map(PreparedReplaceRule.new).toList(growable: false);
}

bool replaceRuleMatchesScope(
  ReplaceRuleExecutionRule rule,
  String title,
  String? source,
) {
  final haystack = '$title ${source ?? ''}'.toLowerCase();
  bool contains(String value) => value
      .split(_scopeSeparator)
      .map((item) => item.trim().toLowerCase())
      .where((item) => item.isNotEmpty)
      .any(haystack.contains);
  if (contains(rule.excludeScope)) return false;
  return rule.scope.trim().isEmpty || contains(rule.scope);
}

String expandReplaceRuleReplacement(String replacement, Match match) {
  return replacement.replaceAllMapped(_replacementCapture, (token) {
    final index = int.tryParse(token.group(1) ?? '');
    if (index == null || index > match.groupCount) return token.group(0)!;
    return match.group(index) ?? '';
  });
}

RegExp compileReplaceRulePattern(String pattern) {
  var source = pattern;
  var caseSensitive = true;
  var multiLine = false;
  var dotAll = false;
  // Reading-source JVM rules commonly place flags at the beginning or after an
  // alternation. Preserve the historical Open Reading behavior: promote every
  // supported inline flag to the complete Dart expression.
  source = source.replaceAllMapped(_inlineFlags, (match) {
    final flags = match.group(1)!;
    if (flags.contains('i')) caseSensitive = false;
    if (flags.contains('m')) multiLine = true;
    if (flags.contains('s')) dotAll = true;
    return '';
  });
  source = replaceRuleHorizontalWhitespace(source);
  return RegExp(
    source,
    caseSensitive: caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
  );
}

String replaceRuleHorizontalWhitespace(String source) {
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
      output
        ..write(character)
        ..write(escaped);
      index++;
      continue;
    }
    if (character == '[') inClass = true;
    if (character == ']' && inClass) inClass = false;
    output.write(character);
  }
  return output.toString();
}

int replaceRuleOutputCharacterLimit(Iterable<String> inputs) {
  final inputCharacters = inputs.fold<int>(
    0,
    (sum, value) => sum + value.length,
  );
  if (inputCharacters == 0) return 1024 * 1024;
  return (inputCharacters * replaceRuleMaximumExpansionRatio).clamp(
    1024 * 1024,
    replaceRuleMaximumOutputCharacters,
  );
}
