class SourceRequestExpressions {
  const SourceRequestExpressions._();

  static String expand(String input, Map<String, String> variables) {
    final normalized = input.replaceAllMapped(
      RegExp(r'\{\{\s*([^{}]+?)\s*\}([*/]\s*\d+)\}'),
      (match) {
        final value = _evaluateIntegerExpression(
          '(${match.group(1)})${match.group(2)}',
          variables,
        );
        return value == null ? match.group(0)! : '$value';
      },
    );
    final expanded = normalized.replaceAllMapped(
      RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
      (match) {
        final key = match.group(1)!;
        var value = variables[key];
        if (value == null) {
          final calculated = _evaluateIntegerExpression(key, variables);
          if (calculated != null) value = '$calculated';
        }
        if (value == null) return match.group(0)!;
        return Uri.encodeQueryComponent(value);
      },
    );
    final page = int.tryParse(variables['page'] ?? '');
    if (page == null || page < 1) return expanded;
    return expanded.replaceAllMapped(RegExp(r'<([^<>]*)>'), (match) {
      final alternatives = match.group(1)!.split(',');
      if (alternatives.isEmpty) return '';
      final index = page <= alternatives.length
          ? page - 1
          : alternatives.length - 1;
      return alternatives[index].trim();
    });
  }

  static int? _evaluateIntegerExpression(
    String expression,
    Map<String, String> variables,
  ) {
    if (!RegExp(r'^[\w\s()+\-*/%]+$').hasMatch(expression)) return null;
    final parser = _IntegerExpressionParser(expression, variables);
    final value = parser.parseExpression();
    parser.skipSpaces();
    return parser.atEnd ? value : null;
  }
}

class _IntegerExpressionParser {
  _IntegerExpressionParser(this.input, this.variables);

  final String input;
  final Map<String, String> variables;
  var index = 0;

  bool get atEnd => index >= input.length;

  void skipSpaces() {
    while (!atEnd && input.codeUnitAt(index) <= 32) {
      index++;
    }
  }

  int? parseExpression() {
    var value = _parseTerm();
    if (value == null) return null;
    while (true) {
      skipSpaces();
      if (atEnd || (input[index] != '+' && input[index] != '-')) return value;
      final operator = input[index++];
      final right = _parseTerm();
      if (right == null) return null;
      value = operator == '+' ? value! + right : value! - right;
    }
  }

  int? _parseTerm() {
    var value = _parseFactor();
    if (value == null) return null;
    while (true) {
      skipSpaces();
      if (atEnd || !'*/%'.contains(input[index])) return value;
      final operator = input[index++];
      final right = _parseFactor();
      if (right == null || right == 0 && operator != '*') return null;
      value = switch (operator) {
        '*' => value! * right,
        '/' => value! ~/ right,
        _ => value! % right,
      };
    }
  }

  int? _parseFactor() {
    skipSpaces();
    if (atEnd) return null;
    if (input[index] == '(') {
      index++;
      final value = parseExpression();
      skipSpaces();
      if (atEnd || input[index] != ')') return null;
      index++;
      return value;
    }
    var sign = 1;
    if (input[index] == '+' || input[index] == '-') {
      if (input[index++] == '-') sign = -1;
      skipSpaces();
    }
    final start = index;
    while (!atEnd && RegExp(r'[A-Za-z0-9_]').hasMatch(input[index])) {
      index++;
    }
    if (start == index) return null;
    final token = input.substring(start, index);
    final value = int.tryParse(token) ?? int.tryParse(variables[token] ?? '');
    return value == null ? null : sign * value;
  }
}
