import 'package:html/dom.dart';

enum SourceXPathAxis { child, descendant, followingSibling }

class SourceXPathStep {
  const SourceXPathStep({
    required this.axis,
    required this.test,
    this.predicates = const [],
  });

  final SourceXPathAxis axis;
  final String test;
  final List<String> predicates;
}

List<Object?> evaluateSourceXPath(
  Object? root,
  String rule, {
  required bool listMode,
}) {
  var expression = rule.trim();
  if (expression.toLowerCase().startsWith('@xpath:')) {
    expression = expression.substring(7).trimLeft();
  }
  final roots = switch (root) {
    Document document => <Element>[document.documentElement!],
    Element element => <Element>[element],
    _ => const <Element>[],
  };
  if (roots.isEmpty) return const [];
  final steps = parseSourceXPathSteps(expression);
  if (steps.isEmpty) return const [];
  var current = roots;
  for (var index = 0; index < steps.length; index++) {
    final step = steps[index];
    if (step.test == 'text()') {
      if (index != steps.length - 1) return const [];
      return current.map(sourceOwnText).toList(growable: false);
    }
    if (step.test.startsWith('@')) {
      if (index != steps.length - 1) return const [];
      final attribute = step.test.substring(1);
      final targets = step.axis == SourceXPathAxis.descendant
          ? <Element>[
              for (final element in current)
                ...element.querySelectorAll('[$attribute]'),
            ]
          : current;
      if (!listMode) {
        // XPath 1.0 converts a node-set to a string using the first node in
        // document order, not by concatenating every matched node — matching
        // that avoids mangled URLs when `@href` etc. matches multiple nodes.
        for (final element in targets) {
          final value = element.attributes[attribute];
          if (value != null) return [value];
        }
        return const [''];
      }
      return targets
          .map((element) => element.attributes[attribute] ?? '')
          .toList(growable: false);
    }
    if (step.axis == SourceXPathAxis.followingSibling) {
      current = [
        for (final element in current)
          ...sourceFollowingSiblings(
            element,
          ).where((candidate) => sourceXPathMatches(candidate, step)),
      ];
      continue;
    }
    final next = <Element>[];
    for (final element in current) {
      final candidates = step.axis == SourceXPathAxis.descendant
          ? element.querySelectorAll('*')
          : element.children;
      next.addAll(
        candidates.where((candidate) => sourceXPathMatches(candidate, step)),
      );
    }
    current = next.toSet().toList(growable: false);
    if (current.isEmpty) break;
  }
  return listMode ? current : current.map((node) => node.text).toList();
}

List<SourceXPathStep> parseSourceXPathSteps(String input) {
  final steps = <SourceXPathStep>[];
  var index = 0;
  var axis = SourceXPathAxis.child;
  while (index < input.length) {
    if (input.startsWith('//', index)) {
      axis = SourceXPathAxis.descendant;
      index += 2;
    } else if (input[index] == '/') {
      axis = SourceXPathAxis.child;
      index++;
    }
    final start = index;
    var bracketDepth = 0;
    String? quote;
    while (index < input.length) {
      final char = input[index];
      if (quote != null) {
        if (char == quote) quote = null;
      } else if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '[') {
        bracketDepth++;
      } else if (char == ']') {
        bracketDepth--;
      } else if (char == '/' && bracketDepth == 0) {
        break;
      }
      index++;
    }
    var raw = input.substring(start, index).trim();
    if (raw.isEmpty) continue;
    var stepAxis = axis;
    if (raw.startsWith('following-sibling::')) {
      stepAxis = SourceXPathAxis.followingSibling;
      raw = raw.substring('following-sibling::'.length);
    }
    final test = raw.split('[').first.trim();
    final predicates = RegExp(r'\[([^\]]+)\]')
        .allMatches(raw)
        .map((match) => match.group(1)!.trim())
        .toList(growable: false);
    steps.add(
      SourceXPathStep(axis: stepAxis, test: test, predicates: predicates),
    );
    axis = SourceXPathAxis.child;
  }
  return steps;
}

bool sourceXPathMatches(Element element, SourceXPathStep step) {
  if (step.test != '*' && element.localName != step.test.toLowerCase()) {
    return false;
  }
  for (final predicate in step.predicates) {
    final attributeEquals = RegExp(
      r'''^@([\w:-]+)\s*=\s*(["'])(.*?)\2$''',
    ).firstMatch(predicate);
    if (attributeEquals != null) {
      if (element.attributes[attributeEquals.group(1)!] !=
          attributeEquals.group(3)) {
        return false;
      }
      continue;
    }
    final containsAttribute = RegExp(
      r'''^contains\(\s*@([\w:-]+)\s*,\s*(["'])(.*?)\2\s*\)$''',
    ).firstMatch(predicate);
    if (containsAttribute != null) {
      if (!(element.attributes[containsAttribute.group(1)!] ?? '').contains(
        containsAttribute.group(3)!,
      )) {
        return false;
      }
      continue;
    }
    final textEquals = RegExp(
      r'''^text\(\)\s*=\s*(["'])(.*?)\1$''',
    ).firstMatch(predicate);
    if (textEquals != null) {
      if (sourceOwnText(element).trim() != textEquals.group(2)) return false;
      continue;
    }
    final containsText = RegExp(
      r'''^contains\(\s*text\(\)\s*,\s*(["'])(.*?)\1\s*\)$''',
    ).firstMatch(predicate);
    if (containsText != null) {
      if (!element.text.contains(containsText.group(2)!)) return false;
      continue;
    }
    final position = int.tryParse(predicate);
    if (position != null) {
      if (sourceXPathSiblingPosition(element, step.test) != position) {
        return false;
      }
      continue;
    }
    final greaterThan = RegExp(
      r'^position\(\)\s*>\s*(\d+)$',
    ).firstMatch(predicate);
    if (greaterThan != null) {
      if (sourceXPathSiblingPosition(element, step.test) <=
          int.parse(greaterThan.group(1)!)) {
        return false;
      }
      continue;
    }
    if (RegExp(r'^[A-Za-z][\w-]*$').hasMatch(predicate)) {
      if (!element.children.any(
        (child) => child.localName == predicate.toLowerCase(),
      )) {
        return false;
      }
      continue;
    }
    return false;
  }
  return true;
}

int sourceXPathSiblingPosition(Element element, String test) {
  final siblings = element.parent?.children ?? const <Element>[];
  var position = 0;
  for (final sibling in siblings) {
    if (test == '*' || sibling.localName == test.toLowerCase()) position++;
    if (identical(sibling, element)) return position;
  }
  return -1;
}

Iterable<Element> sourceFollowingSiblings(Element element) sync* {
  final siblings = element.parent?.children ?? const <Element>[];
  var found = false;
  for (final sibling in siblings) {
    if (found) yield sibling;
    if (identical(sibling, element)) found = true;
  }
}

String sourceOwnText(Element element) =>
    element.nodes.whereType<Text>().map((node) => node.data).join().trim();

String sourceDirectTextNodes(Element element) => element.nodes
    .whereType<Text>()
    .map((node) => node.data.trim())
    .where((value) => value.isNotEmpty)
    .join('\n');
