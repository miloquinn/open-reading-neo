import 'source_rule_json.dart';
import 'source_rule_parser.dart';
import 'source_rule_regex.dart';

typedef SourceSingleRuleEvaluator =
    List<Object?> Function(
      Object? context,
      String rule, {
      required bool listMode,
    });
typedef SourceAsyncSingleRuleEvaluator =
    Future<List<Object?>> Function(
      Object? context,
      String rule, {
      required bool listMode,
    });
typedef SourceInlineScriptEvaluator =
    Object? Function(Object? context, String script);
typedef SourceAsyncInlineScriptEvaluator =
    Future<Object?> Function(Object? context, String script);

class SourceRuleInterpolation {
  const SourceRuleInterpolation({
    required this.evaluateSingle,
    required this.evaluateSingleAsync,
    required this.evaluateScript,
    required this.evaluateScriptAsync,
  });

  final SourceSingleRuleEvaluator evaluateSingle;
  final SourceAsyncSingleRuleEvaluator evaluateSingleAsync;
  final SourceInlineScriptEvaluator evaluateScript;
  final SourceAsyncInlineScriptEvaluator evaluateScriptAsync;

  List<Object?> evaluateAlternatives(
    Object? context,
    String selector, {
    required bool listMode,
  }) {
    for (final fallback in splitSourceRuleTopLevel(selector, '||')) {
      final interleaved = splitSourceRuleTopLevel(fallback, '%%');
      if (interleaved.length > 1) {
        final groups = <List<Object?>>[];
        for (final part in interleaved) {
          final values = evaluateConcatenated(
            context,
            part,
            listMode: listMode,
          );
          if (values.isNotEmpty) groups.add(values);
        }
        if (groups.isNotEmpty) return interleaveSourceRuleValues(groups);
        continue;
      }
      final concatenated = evaluateConcatenated(
        context,
        fallback,
        listMode: listMode,
      );
      if (concatenated.any(
        (value) => sourceRuleStringValue(value).isNotEmpty,
      )) {
        return concatenated;
      }
    }
    return const [];
  }

  List<Object?> evaluateConcatenated(
    Object? context,
    String selector, {
    required bool listMode,
  }) {
    final concatenated = <Object?>[];
    for (final part in splitSourceRuleTopLevel(selector, '&&')) {
      concatenated.addAll(
        evaluateSingle(context, part.trim(), listMode: listMode),
      );
    }
    return concatenated;
  }

  Future<List<Object?>> evaluateAlternativesAsync(
    Object? context,
    String selector, {
    required bool listMode,
  }) async {
    for (final fallback in splitSourceRuleTopLevel(selector, '||')) {
      final interleaved = splitSourceRuleTopLevel(fallback, '%%');
      if (interleaved.length > 1) {
        final groups = <List<Object?>>[];
        for (final part in interleaved) {
          final values = await evaluateConcatenatedAsync(
            context,
            part,
            listMode: listMode,
          );
          if (values.isNotEmpty) groups.add(values);
        }
        if (groups.isNotEmpty) return interleaveSourceRuleValues(groups);
        continue;
      }
      final concatenated = await evaluateConcatenatedAsync(
        context,
        fallback,
        listMode: listMode,
      );
      if (concatenated.any(
        (value) => sourceRuleStringValue(value).isNotEmpty,
      )) {
        return concatenated;
      }
    }
    return const [];
  }

  Future<List<Object?>> evaluateConcatenatedAsync(
    Object? context,
    String selector, {
    required bool listMode,
  }) async {
    final concatenated = <Object?>[];
    for (final part in splitSourceRuleTopLevel(selector, '&&')) {
      concatenated.addAll(
        await evaluateSingleAsync(context, part.trim(), listMode: listMode),
      );
    }
    return concatenated;
  }

  String interpolate(String template, Object? context) {
    return template.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (
      match,
    ) {
      final expression = match.group(1)!;
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        return expression.substring(1, expression.length - 1);
      }
      final selected = evaluateSourceJsonPath(
        context,
        expression,
      ).map(sourceRuleStringValue).join();
      if (selected.isNotEmpty || !looksLikeSourceScriptExpression(expression)) {
        return selected;
      }
      return sourceRuleStringValue(evaluateScript(context, expression));
    });
  }

  Future<String> interpolateAsync(String template, Object? context) async {
    final output = StringBuffer();
    var offset = 0;
    for (final match in RegExp(
      r'\{\{\s*([^{}]+?)\s*\}\}',
    ).allMatches(template)) {
      output.write(template.substring(offset, match.start));
      final expression = match.group(1)!;
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        output.write(expression.substring(1, expression.length - 1));
      } else {
        final selected = evaluateSourceJsonPath(
          context,
          expression,
        ).map(sourceRuleStringValue).join();
        if (selected.isNotEmpty ||
            !looksLikeSourceScriptExpression(expression)) {
          output.write(selected);
        } else {
          output.write(
            sourceRuleStringValue(
              await evaluateScriptAsync(context, expression),
            ),
          );
        }
      }
      offset = match.end;
    }
    output.write(template.substring(offset));
    return output.toString();
  }
}
