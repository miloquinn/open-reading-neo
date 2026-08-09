import 'package:json_path/json_path.dart';

import '../protocol/book_source_protocol.dart';
import 'source_rule_parser.dart';

List<Object?> evaluateSourceJsonPath(Object? root, String path) {
  var normalized = path.trim();
  if (normalized == r'$') return [root];
  if (normalized.startsWith(r'$')) {
    try {
      return JsonPath(
        normalizeLegacySourceJsonPath(normalized),
      ).read(root).map((match) => match.value).toList(growable: false);
    } on Object catch (error) {
      throw BookSourceProtocolException(
        'reading source JSONPath could not be evaluated: $error',
      );
    }
  }
  if (normalized.startsWith(r'$.')) normalized = normalized.substring(2);
  final tokens = RegExp(r'([^\.\[\]]+)|\[(-?\d+|\*)\]')
      .allMatches(normalized)
      .map((match) => match.group(1) ?? match.group(2)!)
      .toList();
  if (tokens.isEmpty || tokens.join().isEmpty) return const [];
  var values = <Object?>[root];
  for (final token in tokens) {
    final next = <Object?>[];
    for (final value in values) {
      if (token == '*' && value is List) {
        next.addAll(value);
      } else if (value is Map && value.containsKey(token)) {
        next.add(value[token]);
      } else if (value is List) {
        final rawIndex = int.tryParse(token);
        if (rawIndex != null) {
          final index = normalizeSourceIndex(rawIndex, value.length);
          if (index >= 0 && index < value.length) next.add(value[index]);
        }
      }
    }
    values = next;
  }
  return values;
}

String normalizeLegacySourceJsonPath(String input) {
  return input.replaceAllMapped(RegExp(r'\[\?\((.*?)\)\]'), (match) {
    return '[?${match.group(1)}]';
  });
}
