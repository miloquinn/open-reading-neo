import 'package:html/dom.dart';

import '../protocol/book_source_protocol.dart';

class SourceRegexRuleContext {
  SourceRegexRuleContext(RegExpMatch match)
    : fullMatch = match.group(0) ?? '',
      groups = List.generate(match.groupCount + 1, match.group);

  final String fullMatch;
  final List<String?> groups;

  String expand(String template) {
    return template.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index >= groups.length) return capture.group(0)!;
      return groups[index] ?? '';
    });
  }
}

List<Object?> evaluateSourceRegexList(Object? input, String selector) {
  final stages = selector.trimLeft().substring(1).split('&&');
  var inputs = <String>[sourceRuleRawString(input)];
  List<SourceRegexRuleContext> matches = const [];
  try {
    for (final stage in stages) {
      final pattern = RegExp(stage, multiLine: true, dotAll: true);
      matches = [
        for (final input in inputs)
          for (final match in pattern.allMatches(input))
            SourceRegexRuleContext(match),
      ];
      inputs = matches.map((match) => match.fullMatch).toList();
      if (inputs.isEmpty) break;
    }
  } on FormatException {
    throw const BookSourceProtocolException(
      'reading source list rule contains an invalid regular expression.',
    );
  }
  return matches;
}

String replaceSourceRegex(String input, RegExp pattern, String replacement) {
  return input.replaceAllMapped(pattern, (match) {
    return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index > match.groupCount) return capture.group(0)!;
      return match.group(index) ?? '';
    });
  });
}

String extractSourceRegex(String input, RegExp pattern, String replacement) {
  final match = pattern.firstMatch(input);
  if (match == null) return '';
  return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
    final index = int.tryParse(capture.group(1)!);
    if (index == null || index > match.groupCount) return capture.group(0)!;
    return match.group(index) ?? '';
  });
}

String sourceRuleStringValue(Object? value) => switch (value) {
  null => '',
  String text => text,
  num number => '$number',
  bool boolean => '$boolean',
  Element element => element.text,
  SourceRegexRuleContext match => match.fullMatch,
  _ => '$value',
};

String sourceRuleRawString(Object? value) => switch (value) {
  Document document => document.outerHtml,
  Element element => element.outerHtml,
  SourceRegexRuleContext match => match.fullMatch,
  null => '',
  _ => '$value',
};

Object? sourceRuleScriptInput(Object? value) => switch (value) {
  Document document => document.outerHtml,
  Element element => element.outerHtml,
  Iterable values => values.map(sourceRuleScriptInput).toList(growable: false),
  _ => value,
};
