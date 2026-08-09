import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import 'source_script_contract.dart';

class SourceRuleDocument {
  SourceRuleDocument._({
    required this.value,
    required this.baseUri,
    this.scriptContext,
    Map<String, Object?>? ruleState,
  }) : ruleState = ruleState ?? <String, Object?>{};

  factory SourceRuleDocument.parse(
    String body,
    Uri baseUri, {
    SourceScriptContext? scriptContext,
    Map<String, Object?>? ruleState,
  }) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return SourceRuleDocument._(
          value: jsonDecode(body),
          baseUri: baseUri,
          scriptContext: scriptContext,
          ruleState: ruleState,
        );
      } on FormatException {
        // Some HTML pages begin with text resembling JSON. Parse them as HTML.
      }
    }
    return SourceRuleDocument._(
      value: html_parser.parse(body),
      baseUri: baseUri,
      scriptContext: scriptContext,
      ruleState: ruleState,
    );
  }

  factory SourceRuleDocument.fromValue(
    Object? value,
    Uri baseUri, {
    SourceScriptContext? scriptContext,
    Map<String, Object?>? ruleState,
  }) => SourceRuleDocument._(
    value: value,
    baseUri: baseUri,
    scriptContext: scriptContext,
    ruleState: ruleState,
  );

  final Object? value;
  final Uri baseUri;
  final SourceScriptContext? scriptContext;
  final Map<String, Object?> ruleState;

  SourceRuleDocument withScriptEntities({
    Map<String, Object?>? book,
    Map<String, Object?>? chapter,
    void Function(Map<String, Object?> value)? bookWriter,
    void Function(Map<String, Object?> value)? chapterWriter,
  }) => SourceRuleDocument._(
    value: value,
    baseUri: baseUri,
    scriptContext: scriptContext?.copyWith(
      book: book,
      chapter: chapter,
      bookWriter: bookWriter,
      chapterWriter: chapterWriter,
    ),
    ruleState: ruleState,
  );
}

abstract interface class SourceRuleSelectorPort {
  List<Object?> evaluateList(
    SourceRuleDocument document,
    Object? context,
    String rule,
  );

  Future<List<Object?>> evaluateListAsync(
    SourceRuleDocument document,
    Object? context,
    String rule,
  );

  String evaluateString(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
  });

  Future<String> evaluateStringAsync(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
    String joinSeparator = '',
    bool regexDotAll = true,
  });

  String applyReplaceRule(String input, String rule);
}
