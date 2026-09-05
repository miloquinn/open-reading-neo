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
    Document document => <Node>[document],
    Element element => <Node>[element],
    _ => const <Node>[],
  };
  if (roots.isEmpty) return const [];
  final steps = parseSourceXPathSteps(expression);
  if (steps.isEmpty) return const [];
  var current = roots;
  Map<Node, int>? documentOrder;

  List<Element> inDocumentOrder(Iterable<Element> candidates) {
    final nodes = candidates.toSet().toList(growable: false);
    if (nodes.length > 1) {
      // Overlapping contexts can discover the same nodes in different orders.
      // XPath node-sets use node identity and document order, including after
      // following-sibling steps and before scalar attribute extraction.
      // Child/descendant queries stay inside the root. Following siblings can
      // also reach its parent's subtree, but never require the whole document
      // for a chapter-local query.
      final orderRoot =
          steps.any((step) => step.axis == SourceXPathAxis.followingSibling)
          ? roots.single.parentNode ?? roots.single
          : roots.single;
      documentOrder ??= _sourceXPathDocumentOrder(orderRoot);
      nodes.sort(
        (left, right) =>
            documentOrder![left]!.compareTo(documentOrder![right]!),
      );
    }
    return nodes;
  }

  for (var index = 0; index < steps.length; index++) {
    final step = steps[index];
    if (step.test == 'text()') {
      if (index != steps.length - 1) return const [];
      return current
          .whereType<Element>()
          .map(sourceOwnText)
          .toList(growable: false);
    }
    if (step.test.startsWith('@')) {
      if (index != steps.length - 1) return const [];
      final attribute = step.test.substring(1);
      final targets = inDocumentOrder(
        (step.axis == SourceXPathAxis.descendant
                ? current
                      .expand(_sourceXPathDescendantOrSelf)
                      .whereType<Element>()
                : current.whereType<Element>())
            .where((element) => element.attributes.containsKey(attribute)),
      );
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
    final next = <Element>{};
    for (final node in current) {
      if (step.axis == SourceXPathAxis.followingSibling) {
        if (node is Element) {
          next.addAll(
            _selectSourceXPathStep(sourceFollowingSiblings(node), step),
          );
        }
      } else {
        // `//` abbreviates /descendant-or-self::node()/child::, so each
        // parent has its own candidate list and predicate positions.
        final contexts = step.axis == SourceXPathAxis.descendant
            ? _sourceXPathDescendantOrSelf(node)
            : [node];
        for (final context in contexts) {
          next.addAll(_selectSourceXPathStep(context.children, step));
        }
      }
    }
    current = inDocumentOrder(next);
    if (current.isEmpty) break;
  }
  return listMode
      ? current
      : current.whereType<Element>().map((node) => node.text).toList();
}

Iterable<Node> _sourceXPathDescendantOrSelf(Node node) sync* {
  yield node;
  for (final child in node.children) {
    yield* _sourceXPathDescendantOrSelf(child);
  }
}

Map<Node, int> _sourceXPathDocumentOrder(Node node) {
  var index = 0;
  return {
    for (final descendant in _sourceXPathDescendantOrSelf(node))
      descendant: index++,
  };
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

List<Element> _selectSourceXPathStep(
  Iterable<Element> candidates,
  SourceXPathStep step,
) {
  var selected = candidates
      .where(
        (element) =>
            step.test == '*' || element.localName == step.test.toLowerCase(),
      )
      .toList(growable: false);
  for (final predicate in step.predicates) {
    if (selected.isEmpty) break;
    // Each predicate filters the result of the preceding predicate. Positions
    // are one-based within that result, never within unfiltered DOM siblings.
    final position = int.tryParse(predicate);
    if (position != null) {
      selected = position > 0 && position <= selected.length
          ? [selected[position - 1]]
          : [];
      continue;
    }
    final greaterThan = RegExp(
      r'^position\(\)\s*>\s*(\d+)$',
    ).firstMatch(predicate);
    if (greaterThan != null) {
      selected = selected
          .skip(int.parse(greaterThan.group(1)!))
          .toList(growable: false);
      continue;
    }
    selected = selected
        .where((element) => _sourceXPathPredicateMatches(element, predicate))
        .toList(growable: false);
  }
  return selected;
}

bool _sourceXPathPredicateMatches(Element element, String predicate) {
  final attributeEquals = RegExp(
    r'''^@([\w:-]+)\s*=\s*(["'])(.*?)\2$''',
  ).firstMatch(predicate);
  if (attributeEquals != null) {
    return element.attributes[attributeEquals.group(1)!] ==
        attributeEquals.group(3);
  }
  final containsAttribute = RegExp(
    r'''^contains\(\s*@([\w:-]+)\s*,\s*(["'])(.*?)\2\s*\)$''',
  ).firstMatch(predicate);
  if (containsAttribute != null) {
    return (element.attributes[containsAttribute.group(1)!] ?? '').contains(
      containsAttribute.group(3)!,
    );
  }
  final textEquals = RegExp(
    r'''^text\(\)\s*=\s*(["'])(.*?)\1$''',
  ).firstMatch(predicate);
  if (textEquals != null) {
    return sourceOwnText(element).trim() == textEquals.group(2);
  }
  final containsText = RegExp(
    r'''^contains\(\s*text\(\)\s*,\s*(["'])(.*?)\1\s*\)$''',
  ).firstMatch(predicate);
  if (containsText != null) {
    return element.text.contains(containsText.group(2)!);
  }
  if (RegExp(r'^[A-Za-z][\w-]*$').hasMatch(predicate)) {
    return element.children.any(
      (child) => child.localName == predicate.toLowerCase(),
    );
  }
  return false;
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
