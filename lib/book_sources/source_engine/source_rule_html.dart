import 'package:html/dom.dart';

import '../protocol/book_source_protocol.dart';
import 'source_rule_parser.dart';
import 'source_rule_xpath.dart';

const sourceHtmlAttributeNames = {
  'href',
  'src',
  'content',
  'value',
  'title',
  'alt',
  'data',
  'action',
};

List<Object?> evaluateSourceHtmlRule(
  List<Element> roots,
  String rule, {
  required bool listMode,
}) {
  final segments = rule.split('@').where((part) => part.isNotEmpty).toList();
  if (segments.isEmpty) return roots;
  var current = roots;
  for (var index = 0; index < segments.length; index++) {
    final segment = segments[index].trim();
    final isLast = index == segments.length - 1;
    final terminal = sourceHtmlTerminalValue(
      current,
      segment,
      singleValue: isLast && !listMode,
    );
    if (terminal != null && isLast) return terminal;
    current = selectSourceHtml(current, segment, includeRoots: index == 0);
    if (current.isEmpty) return const [];
  }
  return listMode ? current : current.map((node) => node.text).toList();
}

List<Object?>? sourceHtmlTerminalValue(
  List<Element> nodes,
  String segment, {
  required bool singleValue,
}) {
  return switch (segment) {
    'text' => nodes.map((node) => node.text).toList(),
    'ownText' => nodes.map(sourceOwnText).toList(),
    'textNodes' => nodes.map(sourceDirectTextNodes).toList(),
    'html' => nodes.map((node) => node.innerHtml).toList(),
    'all' => [nodes.map((node) => node.outerHtml).join()],
    _
        when sourceHtmlAttributeNames.contains(segment.toLowerCase()) ||
            nodes.any((node) => node.attributes.containsKey(segment)) =>
      singleValue
          ? [_sourceFirstAttributeValue(nodes, segment)]
          : nodes.map((node) => node.attributes[segment] ?? '').toList(),
    _ => null,
  };
}

/// Mirrors jsoup's `Elements.attr()`: the first matched element that carries
/// the attribute wins, instead of concatenating every matched element's
/// value together (which produced mangled URLs when a rule such as
/// `tag.a@href` matched more than one anchor inside a single item).
String _sourceFirstAttributeValue(List<Element> nodes, String segment) {
  for (final node in nodes) {
    final value = node.attributes[segment];
    if (value != null) return value;
  }
  return '';
}

List<Element> selectSourceHtml(
  List<Element> roots,
  String raw, {
  required bool includeRoots,
}) {
  final parsed = parseSourceLegacySelector(raw);
  final selected = <Element>[];
  for (final root in roots) {
    if (parsed.text != null) {
      final candidates = <Element>[root, ...root.querySelectorAll('*')];
      final exact = candidates
          .where((element) => element.text.trim() == parsed.text)
          .toList();
      selected.addAll(
        exact.isNotEmpty
            ? exact
            : candidates.where(
                (element) => element.text.contains(parsed.text!),
              ),
      );
    } else {
      try {
        if (includeRoots && sourceHtmlMatches(root, parsed.css)) {
          selected.add(root);
        }
        selected.addAll(root.querySelectorAll(parsed.css));
      } on FormatException {
        final compatible = selectSourceHtmlWithJsoupAttributeRegex(
          root,
          parsed.css,
          includeRoot: includeRoots,
        );
        if (compatible != null) {
          selected.addAll(compatible);
          continue;
        }
        throw BookSourceProtocolException(
          'Unsupported reading source CSS selector: ${parsed.css}.',
        );
      }
    }
  }
  final deduped = selected.toSet().toList();
  if (parsed.exclude != null) {
    final excluded = normalizeSourceIndex(parsed.exclude!, deduped.length);
    if (excluded >= 0 && excluded < deduped.length) deduped.removeAt(excluded);
  }
  if (deduped.isEmpty) return const [];
  if (parsed.excludedSelection != null) {
    final excluded = sourceSelectionIndexes(
      parsed.excludedSelection!,
      deduped.length,
    ).toSet();
    return [
      for (var index = 0; index < deduped.length; index++)
        if (!excluded.contains(index)) deduped[index],
    ];
  }
  if (parsed.selection == null) return deduped;
  return sourceSelectionIndexes(parsed.selection!, deduped.length)
      .where((value) => value >= 0 && value < deduped.length)
      .map((value) => deduped[value])
      .toList();
}

List<Element>? selectSourceHtmlWithJsoupAttributeRegex(
  Element root,
  String selector, {
  required bool includeRoot,
}) {
  final matches = sourceJsoupAttributeRegexSelector
      .allMatches(selector)
      .toList();
  if (matches.isEmpty) return null;
  final candidates = <Element>[root, ...root.querySelectorAll('*')];
  final markers = <String>[];
  var rewritten = selector;
  var markerSuffix = 0;
  try {
    for (final match in matches.reversed) {
      final attribute = match.group(1)!.toLowerCase();
      var patternSource = match.group(2)!.trim();
      if (patternSource.length >= 2 &&
          ((patternSource.startsWith('"') && patternSource.endsWith('"')) ||
              (patternSource.startsWith("'") && patternSource.endsWith("'")))) {
        patternSource = patternSource.substring(1, patternSource.length - 1);
      }
      final pattern = sourceJsoupAttributeRegExp(patternSource);
      late String marker;
      do {
        marker = 'data-open-reading-regex-${markerSuffix++}';
      } while (markers.contains(marker) ||
          candidates.any(
            (candidate) => candidate.attributes.containsKey(marker),
          ));
      markers.add(marker);
      for (final candidate in candidates) {
        final value = candidate.attributes[attribute];
        if (value != null && pattern.hasMatch(value)) {
          candidate.attributes[marker] = '';
        }
      }
      rewritten = rewritten.replaceRange(match.start, match.end, '[$marker]');
    }
    return <Element>[
      if (includeRoot && sourceHtmlMatches(root, rewritten)) root,
      ...root.querySelectorAll(rewritten),
    ];
  } on FormatException {
    return null;
  } finally {
    for (final candidate in candidates) {
      for (final marker in markers) {
        candidate.attributes.remove(marker);
      }
    }
  }
}

RegExp sourceJsoupAttributeRegExp(String source) {
  var pattern = source;
  var caseSensitive = true;
  var multiLine = false;
  var dotAll = false;
  final flags = RegExp(r'^\(\?([ims]+)\)').firstMatch(pattern);
  if (flags != null) {
    final enabled = flags.group(1)!;
    caseSensitive = !enabled.contains('i');
    multiLine = enabled.contains('m');
    dotAll = enabled.contains('s');
    pattern = pattern.substring(flags.end);
  }
  return RegExp(
    pattern,
    caseSensitive: caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
  );
}

final sourceJsoupAttributeRegexSelector = RegExp(
  r'\[\s*([A-Za-z_][A-Za-z0-9_.:-]*)\s*~=\s*([^\]\r\n]+?)\s*\]',
);

bool sourceHtmlMatches(Element element, String selector) {
  final parent = element.parent;
  if (parent != null) {
    return parent.querySelectorAll(selector).contains(element);
  }
  return selector == '*' || selector == element.localName;
}
