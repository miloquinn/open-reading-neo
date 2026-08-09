import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'source_rule_engine.dart';
import 'source_script_contract.dart';
import 'source_script_state.dart';

class SourceScriptDomApi {
  const SourceScriptDomApi(this._selectors);

  final SourceRuleSelectorPort _selectors;

  Object? handle(
    String operation,
    List arguments,
    SourceScriptContext? context,
  ) => switch (operation) {
    'getString' => _selectWithRule(arguments, context, listMode: false),
    'getStringList' => _selectWithRule(arguments, context, listMode: true),
    'getElements' => _selectElements(arguments, context),
    'removeElements' => _removeElements(arguments),
    _ => null,
  };

  Object? _selectWithRule(
    List arguments,
    SourceScriptContext? context, {
    required bool listMode,
  }) {
    if (context == null || arguments.isEmpty) return listMode ? const [] : '';
    final rule = '${arguments.first ?? ''}';
    final content = arguments.length > 1 ? arguments[1] : context.result;
    final document = _document(content, context);
    if (!listMode) {
      return _selectors.evaluateString(document, document.value, rule);
    }
    return _selectors
        .evaluateList(document, document.value, rule)
        .map((item) {
          if (item is String || item is num || item is bool) return '$item';
          if (item is Map || item is List) return jsonEncode(item);
          return '$item';
        })
        .toList(growable: false);
  }

  List<Object?> _selectElements(List arguments, SourceScriptContext? context) {
    if (context == null || arguments.isEmpty) return const [];
    final rule = '${arguments.first ?? ''}';
    final content = arguments.length > 1 ? arguments[1] : context.result;
    final document = _document(content, context);
    return _selectors
        .evaluateList(document, document.value, rule)
        .map((item) {
          if (item is Element) {
            return <String, Object?>{
              '__element': true,
              'text': item.text,
              'html': item.innerHtml,
              'outerHtml': item.outerHtml,
              'attributes': item.attributes.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            };
          }
          return sourceScriptJsonSafe(item);
        })
        .toList(growable: false);
  }

  Map<String, String> _removeElements(List arguments) {
    if (arguments.length < 2) return const {};
    final body = '${arguments.first ?? ''}';
    final selector = '${arguments[1] ?? ''}'.trim();
    if (body.isEmpty || selector.isEmpty) return const {};
    final document = html_parser.parse(body);
    for (final element in document.querySelectorAll(selector)) {
      element.remove();
    }
    final root = document.documentElement;
    return {
      'text': document.body?.text ?? document.text ?? '',
      'html': document.body?.innerHtml ?? root?.innerHtml ?? '',
      'outerHtml': root?.outerHtml ?? '',
    };
  }

  SourceRuleDocument _document(Object? content, SourceScriptContext context) {
    final body = switch (content) {
      String text => text,
      Map _ || List _ => jsonEncode(content),
      null => '',
      _ => '$content',
    };
    return SourceRuleDocument.parse(
      body,
      context.baseUrl ?? context.source.baseUri,
    );
  }
}
