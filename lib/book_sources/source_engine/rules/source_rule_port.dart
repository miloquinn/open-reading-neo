import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import 'package:xxread/book_sources/source_engine/scripting/source_script_contract.dart';

class SourceRuleDocument {
  SourceRuleDocument._({
    required this.value,
    required this.baseUri,
    this.scriptContext,
    this.rawText,
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
      // Reading-source script rules receive the raw fetched string, not a
      // parsed DOM;
      // CSS/XPath selectors still get `value` (the parsed document) via
      // on-demand traversal. Keeping both lets a top-level `<js>` rule (no
      // preceding selector) see the protocol-compatible `result` instead of a
      // DOM object's meaningless toString().
      rawText: body,
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
  final String? rawText;

  /// What a top-level `<js>` rule (no preceding selector) should see as
  /// `result`: the raw fetched text when [value] is a parsed HTML document,
  /// or [value] itself for JSON documents and script-produced sub-documents.
  Object? get scriptResultValue => rawText ?? value;

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
    rawText: rawText,
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
    String joinSeparator = '',
    bool regexDotAll = true,
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
