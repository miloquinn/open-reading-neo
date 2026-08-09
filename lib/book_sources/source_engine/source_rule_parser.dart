class SourceRuleTransform {
  const SourceRuleTransform({
    required this.selector,
    this.pattern,
    this.replacement = '',
  });

  final String selector;
  final String? pattern;
  final String replacement;
}

class SourceScriptRule {
  const SourceScriptRule({
    required this.selector,
    required this.script,
    required this.suffix,
  });

  final String selector;
  final String script;
  final String suffix;
}

class SourcePutRule {
  const SourcePutRule({required this.selector, required this.mappings});

  final String selector;
  final Map<String, String> mappings;
}

class SourceLegacySelector {
  const SourceLegacySelector({
    required this.css,
    this.selection,
    this.excludedSelection,
    this.exclude,
    this.text,
  });

  final String css;
  final List<SourceIndexSpec>? selection;
  final List<SourceIndexSpec>? excludedSelection;
  final int? exclude;
  final String? text;
}

class SourceIndexSpec {
  const SourceIndexSpec.single(int value)
    : start = value,
      end = value,
      step = 1;

  const SourceIndexSpec.range(this.start, this.end, this.step);

  final int? start;
  final int? end;
  final int step;
}

SourcePutRule? splitSourcePutRule(String rule) {
  final match = RegExp(
    r'@put:\s*\{([\s\S]*)\}\s*$',
    caseSensitive: false,
  ).firstMatch(rule);
  if (match == null) return null;
  final mappings = <String, String>{};
  for (final entry in splitSourceRuleTopLevel(match.group(1)!, ',')) {
    final parts = splitSourceRuleTopLevel(entry, ':', limit: 2);
    if (parts.length != 2) continue;
    final key = stripSourceRuleQuotes(parts.first.trim());
    final value = stripSourceRuleQuotes(parts.last.trim());
    if (key.isNotEmpty && value.isNotEmpty) mappings[key] = value;
  }
  if (mappings.isEmpty) return null;
  return SourcePutRule(
    selector: rule.substring(0, match.start),
    mappings: Map.unmodifiable(mappings),
  );
}

String expandSourceRuleStateGets(String rule, Map<String, Object?> state) {
  return rule.replaceAllMapped(
    RegExp(r'@get:\s*\{\s*([^{}]+?)\s*\}', caseSensitive: false),
    (match) => '${state[stripSourceRuleQuotes(match.group(1)!.trim())] ?? ''}',
  );
}

List<String> splitSourceRuleTopLevel(
  String input,
  String separator, {
  int? limit,
}) {
  final parts = <String>[];
  var start = 0;
  var depth = 0;
  String? quote;
  var escaped = false;
  for (var index = 0; index < input.length; index++) {
    final char = input[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == '\\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'" || char == '`') {
      quote = char;
      continue;
    }
    if (char == '{' || char == '[' || char == '(') depth++;
    if (char == '}' || char == ']' || char == ')') depth--;
    if (depth == 0 && input.startsWith(separator, index)) {
      parts.add(input.substring(start, index));
      index += separator.length - 1;
      start = index + 1;
      if (limit != null && parts.length == limit - 1) break;
    }
  }
  parts.add(input.substring(start));
  return parts;
}

String stripSourceRuleQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('`') && value.endsWith('`')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

SourceScriptRule? splitSourceScriptRule(String rule) {
  final lowered = rule.toLowerCase();
  final atIndex = lowered.indexOf('@js:');
  final tag = RegExp(
    r'<js>(.*?)</js>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(rule);
  if (atIndex < 0 && tag == null) return null;
  if (atIndex >= 0 && (tag == null || atIndex < tag.start)) {
    return SourceScriptRule(
      selector: rule.substring(0, atIndex),
      script: rule.substring(atIndex + 4),
      suffix: '',
    );
  }
  return SourceScriptRule(
    selector: rule.substring(0, tag!.start),
    script: tag.group(1)!,
    suffix: rule.substring(tag.end),
  );
}

SourceRuleTransform splitSourceRuleTransform(String rule) {
  final parts = rule.split('##');
  if (parts.length == 1) return SourceRuleTransform(selector: rule);
  return SourceRuleTransform(
    selector: parts.first,
    pattern: parts.length > 1 ? parts[1] : null,
    replacement: parts.length > 2
        ? parts[2].replaceFirst(RegExp(r'###$'), '')
        : '',
  );
}

SourceLegacySelector parseSourceLegacySelector(String input) {
  var selector = input.trim();
  int? exclude;
  final exclusion = RegExp(r'!(-?\d+)$').firstMatch(selector);
  if (exclusion != null) {
    exclude = int.parse(exclusion.group(1)!);
    selector = selector.substring(0, exclusion.start);
  }
  List<SourceIndexSpec>? selection;
  final bracketMatch = RegExp(
    r'\[\s*(!?)([-\d:,\s]+)\s*\]$',
  ).firstMatch(selector);
  if (bracketMatch != null) {
    final excludes = bracketMatch.group(1) == '!';
    selection = parseSourceIndexSelection(bracketMatch.group(2)!);
    selector = selector.substring(0, bracketMatch.start);
    if (excludes) {
      return SourceLegacySelector(
        css: sourceLegacyCss(selector),
        excludedSelection: selection,
      );
    }
  } else {
    final indexMatch = RegExp(r'\.(-?\d+(?::-?\d+)*)$').firstMatch(selector);
    if (indexMatch != null) {
      selection = indexMatch
          .group(1)!
          .split(':')
          .map((value) => SourceIndexSpec.single(int.parse(value)))
          .toList(growable: false);
      selector = selector.substring(0, indexMatch.start);
    }
  }
  String? text;
  if (selector.startsWith('text.')) {
    text = selector.substring(5);
    selector = '*';
  } else {
    selector = sourceLegacyCss(selector);
  }
  if (selector.isEmpty) selector = '*';
  return SourceLegacySelector(
    css: selector,
    selection: selection,
    exclude: exclude,
    text: text,
  );
}

List<SourceIndexSpec> parseSourceIndexSelection(String input) {
  final specs = <SourceIndexSpec>[];
  for (final raw in input.split(',')) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    final parts = value.split(':').map((part) => part.trim()).toList();
    if (parts.length == 1) {
      final index = int.tryParse(parts.single);
      if (index != null) specs.add(SourceIndexSpec.single(index));
      continue;
    }
    final start = parts.first.isEmpty ? null : int.tryParse(parts.first);
    final end = parts[1].isEmpty ? null : int.tryParse(parts[1]);
    final step = parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1;
    specs.add(SourceIndexSpec.range(start, end, step));
  }
  return specs;
}

Iterable<int> sourceSelectionIndexes(
  List<SourceIndexSpec> specs,
  int length,
) sync* {
  final seen = <int>{};
  for (final spec in specs) {
    var start = spec.start ?? 0;
    var end = spec.end ?? length - 1;
    start = normalizeSourceIndex(start, length).clamp(0, length - 1);
    end = normalizeSourceIndex(end, length).clamp(0, length - 1);
    final distance = (end - start).abs();
    var step = spec.step.abs();
    if (step == 0 || (spec.step < 0 && step < length)) {
      step = spec.step < 0 ? length - step : 1;
    }
    if (distance == 0 || step > distance) {
      if (seen.add(start)) yield start;
      continue;
    }
    if (start <= end) {
      for (var index = start; index <= end; index += step) {
        if (seen.add(index)) yield index;
      }
    } else {
      for (var index = start; index >= end; index -= step) {
        if (seen.add(index)) yield index;
      }
    }
  }
}

String sourceLegacyCss(String selector) {
  if (selector.startsWith('class.')) {
    final classNames = selector
        .substring(6)
        .trim()
        .split(RegExp(r'\s+'))
        .where((name) => name.isNotEmpty);
    return classNames.map((name) => '.$name').join();
  }
  if (selector.startsWith('id.')) return '#${selector.substring(3)}';
  if (selector.startsWith('tag.')) return selector.substring(4);
  return selector.isEmpty ? '*' : selector;
}

List<Object?> interleaveSourceRuleValues(List<List<Object?>> groups) {
  final values = <Object?>[];
  final length = groups.fold<int>(
    0,
    (maximum, group) => group.length > maximum ? group.length : maximum,
  );
  for (var index = 0; index < length; index++) {
    for (final group in groups) {
      if (index < group.length) values.add(group[index]);
    }
  }
  return values;
}

int normalizeSourceIndex(int index, int length) =>
    index < 0 ? length + index : index;

bool looksLikeSourceScriptExpression(String value) => RegExp(
  r'\b(?:source|java|result|book|chapter)\b|[=;]|\b(?:if|let|var|const|function)\b',
).hasMatch(value);

bool looksLikeProtocolRelativeSourceUrl(String value) => RegExp(
  r'^//[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?::\d+)?(?:[/#?]|$)',
).hasMatch(value.trimLeft());

bool looksLikeSourceXPathRule(String value) {
  final text = value.trimLeft();
  if (text.toLowerCase().startsWith('@xpath:')) return true;
  return text.startsWith('//') && !looksLikeProtocolRelativeSourceUrl(text);
}
