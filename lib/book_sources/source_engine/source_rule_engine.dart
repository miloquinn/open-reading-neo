import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:json_path/json_path.dart';

import '../protocol/book_source_protocol.dart';
import 'source_request.dart';
import 'source_script_engine_platform.dart';

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

class SourceRuleEngine {
  const SourceRuleEngine({this.scriptEvaluatorProvider});

  final SourceScriptEvaluator Function()? scriptEvaluatorProvider;

  List<Object?> evaluateList(
    SourceRuleDocument document,
    Object? context,
    String rule,
  ) {
    final putRule = _splitPutRule(rule);
    if (putRule != null) {
      return _evaluatePutList(document, context, putRule);
    }
    final scripted = _splitScriptRule(rule);
    if (scripted != null) {
      return _evaluateScriptedList(document, context, scripted);
    }
    final transformed = _splitTransform(rule);
    if (transformed.selector.trimLeft().startsWith(':')) {
      return _evaluateRegexList(document, context, transformed.selector);
    }
    final values = _evaluateAlternatives(
      document,
      context,
      transformed.selector,
      listMode: true,
    );
    return values.where((value) => value != null).toList(growable: false);
  }

  Future<List<Object?>> evaluateListAsync(
    SourceRuleDocument document,
    Object? context,
    String rule,
  ) async {
    final putRule = _splitPutRule(rule);
    if (putRule != null) {
      return _evaluatePutListAsync(document, context, putRule);
    }
    final scripted = _splitScriptRule(rule);
    if (scripted != null) {
      return _evaluateScriptedListAsync(document, context, scripted);
    }
    final transformed = _splitTransform(rule);
    if (transformed.selector.trimLeft().startsWith(':')) {
      return _evaluateRegexList(document, context, transformed.selector);
    }
    final values = await _evaluateAlternativesAsync(
      document,
      context,
      transformed.selector,
      listMode: true,
    );
    return values.where((value) => value != null).toList(growable: false);
  }

  List<Object?> _evaluateRegexList(
    SourceRuleDocument document,
    Object? context,
    String selector,
  ) {
    final stages = selector.trimLeft().substring(1).split('&&');
    var inputs = <String>[_rawString(context ?? document.value)];
    List<_RegexRuleContext> matches = const [];
    try {
      for (final stage in stages) {
        final pattern = RegExp(stage, multiLine: true, dotAll: true);
        matches = [
          for (final input in inputs)
            for (final match in pattern.allMatches(input))
              _RegexRuleContext(match),
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

  String evaluateString(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
  }) {
    final putRule = _splitPutRule(rule);
    if (putRule != null) {
      return _evaluatePutString(
        document,
        context,
        putRule,
        resolveUrl: resolveUrl,
      );
    }
    final scripted = _splitScriptRule(rule);
    if (scripted != null) {
      return _evaluateScriptedString(
        document,
        context,
        scripted,
        resolveUrl: resolveUrl,
      );
    }
    final transformed = _splitTransform(rule);
    final selected = transformed.selector.trim().isEmpty
        ? _rawValues(document, context)
        : _evaluateAlternatives(
            document,
            context,
            transformed.selector,
            listMode: false,
          );
    final values = selected
        .map(_stringValue)
        .where((value) => value.isNotEmpty)
        .toList();
    var result = values.join();
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: true,
        );
        result =
            transformed.selector.trim().isEmpty &&
                transformed.replacement.isNotEmpty
            ? _extractRegex(result, pattern, transformed.replacement)
            : _replaceRegex(result, pattern, transformed.replacement);
      } on FormatException {
        throw const BookSourceProtocolException(
          'reading source rule contains an invalid regular expression.',
        );
      }
    }
    result = result.trim();
    if (resolveUrl && result.isNotEmpty) {
      return _resolveRuleRequestUrl(
        document.baseUri,
        result,
        'reading source rule produced a non-HTTP URL.',
      );
    }
    return result;
  }

  Future<String> evaluateStringAsync(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    bool resolveUrl = false,
    String joinSeparator = '',
    bool regexDotAll = true,
  }) async {
    final putRule = _splitPutRule(rule);
    if (putRule != null) {
      return _evaluatePutStringAsync(
        document,
        context,
        putRule,
        resolveUrl: resolveUrl,
        joinSeparator: joinSeparator,
        regexDotAll: regexDotAll,
      );
    }
    final scripted = _splitScriptRule(rule);
    if (scripted != null) {
      return _evaluateScriptedStringAsync(
        document,
        context,
        scripted,
        resolveUrl: resolveUrl,
        joinSeparator: joinSeparator,
        regexDotAll: regexDotAll,
      );
    }
    final transformed = _splitTransform(rule);
    final selected = transformed.selector.trim().isEmpty
        ? _rawValues(document, context)
        : await _evaluateAlternativesAsync(
            document,
            context,
            transformed.selector,
            listMode: false,
          );
    final values = selected
        .map(_stringValue)
        .where((value) => value.isNotEmpty)
        .toList();
    var result = values.join(joinSeparator);
    if (transformed.pattern != null) {
      try {
        final pattern = RegExp(
          transformed.pattern!,
          multiLine: true,
          dotAll: regexDotAll,
        );
        result =
            transformed.selector.trim().isEmpty &&
                transformed.replacement.isNotEmpty
            ? _extractRegex(result, pattern, transformed.replacement)
            : _replaceRegex(result, pattern, transformed.replacement);
      } on FormatException {
        throw const BookSourceProtocolException(
          'Source rule contains an invalid regular expression.',
        );
      }
    }
    result = result.trim();
    if (resolveUrl && result.isNotEmpty) {
      return _resolveRuleRequestUrl(
        document.baseUri,
        result,
        'Source rule produced a non-HTTP URL.',
      );
    }
    return result;
  }

  List<Object?> _evaluatePutList(
    SourceRuleDocument document,
    Object? context,
    _PutRule putRule,
  ) {
    final values = putRule.selector.trim().isEmpty
        ? <Object?>[context ?? document.value]
        : evaluateList(document, context, putRule.selector);
    _storePutMappings(document, context, putRule.mappings);
    return values;
  }

  Future<List<Object?>> _evaluatePutListAsync(
    SourceRuleDocument document,
    Object? context,
    _PutRule putRule,
  ) async {
    final values = putRule.selector.trim().isEmpty
        ? <Object?>[context ?? document.value]
        : await evaluateListAsync(document, context, putRule.selector);
    await _storePutMappingsAsync(document, context, putRule.mappings);
    return values;
  }

  String _evaluatePutString(
    SourceRuleDocument document,
    Object? context,
    _PutRule putRule, {
    required bool resolveUrl,
  }) {
    final value = putRule.selector.trim().isEmpty
        ? _stringValue(context ?? document.value)
        : evaluateString(
            document,
            context,
            putRule.selector,
            resolveUrl: resolveUrl,
          );
    _storePutMappings(document, context, putRule.mappings);
    return value;
  }

  Future<String> _evaluatePutStringAsync(
    SourceRuleDocument document,
    Object? context,
    _PutRule putRule, {
    required bool resolveUrl,
    required String joinSeparator,
    required bool regexDotAll,
  }) async {
    final value = putRule.selector.trim().isEmpty
        ? _stringValue(context ?? document.value)
        : await evaluateStringAsync(
            document,
            context,
            putRule.selector,
            resolveUrl: resolveUrl,
            joinSeparator: joinSeparator,
            regexDotAll: regexDotAll,
          );
    await _storePutMappingsAsync(document, context, putRule.mappings);
    return value;
  }

  void _storePutMappings(
    SourceRuleDocument document,
    Object? context,
    Map<String, String> mappings,
  ) {
    for (final entry in mappings.entries) {
      document.ruleState[entry.key] = evaluateString(
        document,
        context,
        entry.value,
      );
    }
  }

  Future<void> _storePutMappingsAsync(
    SourceRuleDocument document,
    Object? context,
    Map<String, String> mappings,
  ) async {
    for (final entry in mappings.entries) {
      document.ruleState[entry.key] = await evaluateStringAsync(
        document,
        context,
        entry.value,
      );
    }
  }

  List<Object?> _evaluateScriptedList(
    SourceRuleDocument document,
    Object? context,
    _ScriptRule scripted,
  ) {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : evaluateList(document, context, scripted.selector);
    final output = _evaluateScript(document, input, scripted.script);
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _scriptOutputDocument(document, output);
      return evaluateList(nextDocument, nextDocument.value, scripted.suffix);
    }
    if (output is Iterable) return output.toList(growable: false);
    return output == null ? const [] : [output];
  }

  Future<List<Object?>> _evaluateScriptedListAsync(
    SourceRuleDocument document,
    Object? context,
    _ScriptRule scripted,
  ) async {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : await evaluateListAsync(document, context, scripted.selector);
    final output = await _evaluateScriptAsync(document, input, scripted.script);
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _scriptOutputDocument(document, output);
      return evaluateListAsync(
        nextDocument,
        nextDocument.value,
        scripted.suffix,
      );
    }
    if (output is Iterable) return output.toList(growable: false);
    return output == null ? const [] : [output];
  }

  String _evaluateScriptedString(
    SourceRuleDocument document,
    Object? context,
    _ScriptRule scripted, {
    required bool resolveUrl,
  }) {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : evaluateString(document, context, scripted.selector);
    final output = _evaluateScript(document, input, scripted.script);
    var value = '';
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _scriptOutputDocument(document, output);
      value = evaluateString(nextDocument, nextDocument.value, scripted.suffix);
    } else if (output is Iterable && output is! String) {
      value = output.map(_stringValue).join();
    } else {
      value = _stringValue(output);
    }
    value = value.trim();
    if (resolveUrl && value.isNotEmpty) {
      return _resolveRuleRequestUrl(
        document.baseUri,
        value,
        'reading source script produced a non-HTTP URL.',
      );
    }
    return value;
  }

  Future<String> _evaluateScriptedStringAsync(
    SourceRuleDocument document,
    Object? context,
    _ScriptRule scripted, {
    required bool resolveUrl,
    required String joinSeparator,
    required bool regexDotAll,
  }) async {
    final input = scripted.selector.trim().isEmpty
        ? context ?? document.value
        : await evaluateStringAsync(
            document,
            context,
            scripted.selector,
            joinSeparator: joinSeparator,
            regexDotAll: regexDotAll,
          );
    final output = await _evaluateScriptAsync(document, input, scripted.script);
    var value = '';
    if (scripted.suffix.trim().isNotEmpty) {
      final nextDocument = _scriptOutputDocument(document, output);
      value = await evaluateStringAsync(
        nextDocument,
        nextDocument.value,
        scripted.suffix,
        joinSeparator: joinSeparator,
        regexDotAll: regexDotAll,
      );
    } else if (output is Iterable && output is! String) {
      value = output.map(_stringValue).join(joinSeparator);
    } else {
      value = _stringValue(output);
    }
    value = value.trim();
    if (resolveUrl && value.isNotEmpty) {
      return _resolveRuleRequestUrl(
        document.baseUri,
        value,
        'Source script produced a non-HTTP URL.',
      );
    }
    return value;
  }

  Object? _evaluateScript(
    SourceRuleDocument document,
    Object? result,
    String script,
  ) {
    final evaluator = scriptEvaluatorProvider?.call();
    final context = document.scriptContext;
    if (evaluator == null || context == null) {
      throw const BookSourceProtocolException(
        'This reading source needs JavaScript execution.',
      );
    }
    return evaluator.evaluate(
      script,
      SourceScriptContext(
        source: context.source,
        result: _scriptInput(result),
        baseUrl: document.baseUri,
        variables: context.variables,
        book: context.book,
        chapter: context.chapter,
        bookWriter: context.bookWriter,
        chapterWriter: context.chapterWriter,
        loginInfo: context.loginInfo,
        loginHeaders: context.loginHeaders,
        loginInfoWriter: context.loginInfoWriter,
        loginHeaderWriter: context.loginHeaderWriter,
        interactionHandler: context.interactionHandler,
        cookieReader: context.cookieReader,
        cookieWriter: context.cookieWriter,
        cookieRemover: context.cookieRemover,
      ),
    );
  }

  Future<Object?> _evaluateScriptAsync(
    SourceRuleDocument document,
    Object? result,
    String script,
  ) {
    final evaluator = scriptEvaluatorProvider?.call();
    final context = document.scriptContext;
    if (evaluator == null || context == null) {
      throw const BookSourceProtocolException(
        'This reading source needs JavaScript execution.',
      );
    }
    return evaluator.evaluateAsync(
      script,
      SourceScriptContext(
        source: context.source,
        result: _scriptInput(result),
        baseUrl: document.baseUri,
        variables: context.variables,
        book: context.book,
        chapter: context.chapter,
        bookWriter: context.bookWriter,
        chapterWriter: context.chapterWriter,
        networkHandler: context.networkHandler,
        cookieReader: context.cookieReader,
        cookieWriter: context.cookieWriter,
        cookieRemover: context.cookieRemover,
        loginInfo: context.loginInfo,
        loginHeaders: context.loginHeaders,
        loginInfoWriter: context.loginInfoWriter,
        loginHeaderWriter: context.loginHeaderWriter,
        interactionHandler: context.interactionHandler,
      ),
    );
  }

  SourceRuleDocument _scriptOutputDocument(
    SourceRuleDocument previous,
    Object? output,
  ) {
    if (output is String) {
      return SourceRuleDocument.parse(
        output,
        previous.baseUri,
        scriptContext: previous.scriptContext,
        ruleState: previous.ruleState,
      );
    }
    return SourceRuleDocument._(
      value: output,
      baseUri: previous.baseUri,
      scriptContext: previous.scriptContext,
      ruleState: previous.ruleState,
    );
  }

  String applyReplaceRule(String input, String rule) {
    if (rule.trim().isEmpty) return input;
    final transformed = _splitTransform(
      rule.trim().startsWith('##') ? rule : '##$rule',
    );
    if (transformed.pattern == null) return input;
    try {
      return _replaceRegex(
        input,
        RegExp(transformed.pattern!, multiLine: true, dotAll: true),
        transformed.replacement,
      );
    } on FormatException {
      throw const BookSourceProtocolException(
        'reading source replacement contains an invalid regular expression.',
      );
    }
  }

  List<Object?> _evaluateAlternatives(
    SourceRuleDocument document,
    Object? context,
    String selector, {
    required bool listMode,
  }) {
    for (final fallback in _splitTopLevel(selector, '||')) {
      final interleaved = _splitTopLevel(fallback, '%%');
      if (interleaved.length > 1) {
        final groups = <List<Object?>>[];
        for (final part in interleaved) {
          final values = _evaluateConcatenated(
            document,
            context,
            part,
            listMode: listMode,
          );
          if (values.isNotEmpty) groups.add(values);
        }
        if (groups.isNotEmpty) return _interleave(groups);
        continue;
      }
      final concatenated = _evaluateConcatenated(
        document,
        context,
        fallback,
        listMode: listMode,
      );
      if (concatenated.any((value) => _stringValue(value).isNotEmpty)) {
        return concatenated;
      }
    }
    return const [];
  }

  List<Object?> _evaluateConcatenated(
    SourceRuleDocument document,
    Object? context,
    String selector, {
    required bool listMode,
  }) {
    final concatenated = <Object?>[];
    for (final part in _splitTopLevel(selector, '&&')) {
      concatenated.addAll(
        _evaluateSingle(document, context, part.trim(), listMode: listMode),
      );
    }
    return concatenated;
  }

  Future<List<Object?>> _evaluateAlternativesAsync(
    SourceRuleDocument document,
    Object? context,
    String selector, {
    required bool listMode,
  }) async {
    for (final fallback in _splitTopLevel(selector, '||')) {
      final interleaved = _splitTopLevel(fallback, '%%');
      if (interleaved.length > 1) {
        final groups = <List<Object?>>[];
        for (final part in interleaved) {
          final values = await _evaluateConcatenatedAsync(
            document,
            context,
            part,
            listMode: listMode,
          );
          if (values.isNotEmpty) groups.add(values);
        }
        if (groups.isNotEmpty) return _interleave(groups);
        continue;
      }
      final concatenated = await _evaluateConcatenatedAsync(
        document,
        context,
        fallback,
        listMode: listMode,
      );
      if (concatenated.any((value) => _stringValue(value).isNotEmpty)) {
        return concatenated;
      }
    }
    return const [];
  }

  Future<List<Object?>> _evaluateConcatenatedAsync(
    SourceRuleDocument document,
    Object? context,
    String selector, {
    required bool listMode,
  }) async {
    final concatenated = <Object?>[];
    for (final part in _splitTopLevel(selector, '&&')) {
      concatenated.addAll(
        await _evaluateSingleAsync(
          document,
          context,
          part.trim(),
          listMode: listMode,
        ),
      );
    }
    return concatenated;
  }

  List<Object?> _evaluateSingle(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
  }) {
    var normalized = rule.trim();
    if (normalized.startsWith('+')) {
      normalized = normalized.substring(1).trimLeft();
    }
    if (normalized.toLowerCase().startsWith('@css:')) {
      normalized = normalized.substring(5).trimLeft();
    }
    if (normalized.isEmpty) return const [];
    final expandedState = _expandStateGets(normalized, document.ruleState);
    final usedState = expandedState != normalized;
    normalized = expandedState;
    final root = context ?? document.value;
    if (root is _RegexRuleContext) {
      return [root.expand(normalized)];
    }
    if (normalized.contains('{{')) {
      return [_interpolate(normalized, root, document)];
    }
    if (usedState) return [normalized];
    if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
        (normalized.startsWith("'") && normalized.endsWith("'"))) {
      return [normalized.substring(1, normalized.length - 1)];
    }
    if (_looksLikeProtocolRelativeUrl(normalized)) return [normalized];
    if (_looksLikeXPathRule(normalized)) {
      return _evaluateXPath(root, normalized, listMode: listMode);
    }
    final normalizedRule = normalized.toLowerCase().startsWith('@json:')
        ? normalized.substring(6)
        : normalized;
    if (root is Map || root is List || normalizedRule.startsWith(r'$.')) {
      return _jsonPath(root, normalizedRule);
    }
    final nodes = <Element>[];
    if (root is Document) {
      nodes.add(root.documentElement!);
    } else if (root is Element) {
      nodes.add(root);
    } else {
      return [root];
    }
    return _htmlRule(nodes, normalized, listMode: listMode);
  }

  Future<List<Object?>> _evaluateSingleAsync(
    SourceRuleDocument document,
    Object? context,
    String rule, {
    required bool listMode,
  }) async {
    var normalized = rule.trim();
    if (normalized.startsWith('+')) {
      normalized = normalized.substring(1).trimLeft();
    }
    if (normalized.toLowerCase().startsWith('@css:')) {
      normalized = normalized.substring(5).trimLeft();
    }
    if (normalized.isEmpty) return const [];
    final expandedState = _expandStateGets(normalized, document.ruleState);
    final usedState = expandedState != normalized;
    normalized = expandedState;
    final root = context ?? document.value;
    if (root is _RegexRuleContext) return [root.expand(normalized)];
    if (normalized.contains('{{')) {
      return [await _interpolateAsync(normalized, root, document)];
    }
    if (usedState) return [normalized];
    if ((normalized.startsWith('"') && normalized.endsWith('"')) ||
        (normalized.startsWith("'") && normalized.endsWith("'"))) {
      return [normalized.substring(1, normalized.length - 1)];
    }
    if (_looksLikeProtocolRelativeUrl(normalized)) return [normalized];
    if (_looksLikeXPathRule(normalized)) {
      return _evaluateXPath(root, normalized, listMode: listMode);
    }
    final normalizedRule = normalized.toLowerCase().startsWith('@json:')
        ? normalized.substring(6)
        : normalized;
    if (root is Map || root is List || normalizedRule.startsWith(r'$.')) {
      return _jsonPath(root, normalizedRule);
    }
    final nodes = <Element>[];
    if (root is Document) {
      nodes.add(root.documentElement!);
    } else if (root is Element) {
      nodes.add(root);
    } else {
      return [root];
    }
    return _htmlRule(nodes, normalized, listMode: listMode);
  }

  List<Object?> _evaluateXPath(
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
    final steps = _parseXPathSteps(expression);
    if (steps.isEmpty) return const [];
    var current = roots;
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      if (step.test == 'text()') {
        if (index != steps.length - 1) return const [];
        return current.map(_ownText).toList(growable: false);
      }
      if (step.test.startsWith('@')) {
        if (index != steps.length - 1) return const [];
        final attribute = step.test.substring(1);
        final targets = step.axis == _XPathAxis.descendant
            ? <Element>[
                for (final element in current)
                  ...element.querySelectorAll('[$attribute]'),
              ]
            : current;
        return targets
            .map((element) => element.attributes[attribute] ?? '')
            .toList(growable: false);
      }
      if (step.axis == _XPathAxis.followingSibling) {
        current = [
          for (final element in current)
            ..._followingSiblings(
              element,
            ).where((candidate) => _xpathMatches(candidate, step)),
        ];
        continue;
      }
      final next = <Element>[];
      for (final element in current) {
        final candidates = step.axis == _XPathAxis.descendant
            ? element.querySelectorAll('*')
            : element.children;
        next.addAll(
          candidates.where((candidate) => _xpathMatches(candidate, step)),
        );
      }
      current = next.toSet().toList(growable: false);
      if (current.isEmpty) break;
    }
    return listMode ? current : current.map((node) => node.text).toList();
  }

  List<Object?> _htmlRule(
    List<Element> roots,
    String rule, {
    required bool listMode,
  }) {
    final segments = rule.split('@').where((part) => part.isNotEmpty).toList();
    if (segments.isEmpty) return roots;
    var current = roots;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index].trim();
      final terminal = _terminalValue(current, segment);
      if (terminal != null && index == segments.length - 1) return terminal;
      current = _select(current, segment, includeRoots: index == 0);
      if (current.isEmpty) return const [];
    }
    return listMode ? current : current.map((node) => node.text).toList();
  }

  List<Object?>? _terminalValue(List<Element> nodes, String segment) {
    return switch (segment) {
      'text' => nodes.map((node) => node.text).toList(),
      'ownText' => nodes.map(_ownText).toList(),
      'textNodes' => nodes.map(_directTextNodes).toList(),
      'html' => nodes.map((node) => node.innerHtml).toList(),
      'all' => [nodes.map((node) => node.outerHtml).join()],
      _
          when _htmlAttributeNames.contains(segment.toLowerCase()) ||
              nodes.any((node) => node.attributes.containsKey(segment)) =>
        nodes.map((node) => node.attributes[segment] ?? '').toList(),
      _ => null,
    };
  }

  List<Element> _select(
    List<Element> roots,
    String raw, {
    required bool includeRoots,
  }) {
    final parsed = _legacySelector(raw);
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
          if (includeRoots && _matches(root, parsed.css)) selected.add(root);
          selected.addAll(root.querySelectorAll(parsed.css));
        } on FormatException {
          final compatible = _selectWithJsoupAttributeRegex(
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
      final excluded = _normalizedIndex(parsed.exclude!, deduped.length);
      if (excluded >= 0 && excluded < deduped.length) {
        deduped.removeAt(excluded);
      }
    }
    if (deduped.isEmpty) return const [];
    if (parsed.excludedSelection != null) {
      final excluded = _selectionIndexes(
        parsed.excludedSelection!,
        deduped.length,
      ).toSet();
      return [
        for (var index = 0; index < deduped.length; index++)
          if (!excluded.contains(index)) deduped[index],
      ];
    }
    if (parsed.selection == null) return deduped;
    return _selectionIndexes(parsed.selection!, deduped.length)
        .where((value) => value >= 0 && value < deduped.length)
        .map((value) => deduped[value])
        .toList();
  }

  List<Element>? _selectWithJsoupAttributeRegex(
    Element root,
    String selector, {
    required bool includeRoot,
  }) {
    // Jsoup-based reading sources use [attr~=pattern] for regex matching.
    // Mark matching elements temporarily so package:html can evaluate the rest.
    final matches = _jsoupAttributeRegexSelector.allMatches(selector).toList();
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
                (patternSource.startsWith("'") &&
                    patternSource.endsWith("'")))) {
          patternSource = patternSource.substring(1, patternSource.length - 1);
        }
        final pattern = _jsoupAttributeRegExp(patternSource);
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
        if (includeRoot && _matches(root, rewritten)) root,
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

  _LegacySelector _legacySelector(String input) {
    var selector = input.trim();
    int? exclude;
    final exclusion = RegExp(r'!(-?\d+)$').firstMatch(selector);
    if (exclusion != null) {
      exclude = int.parse(exclusion.group(1)!);
      selector = selector.substring(0, exclusion.start);
    }
    List<_IndexSpec>? selection;
    final bracketMatch = RegExp(
      r'\[\s*(!?)([-\d:,\s]+)\s*\]$',
    ).firstMatch(selector);
    if (bracketMatch != null) {
      final excludes = bracketMatch.group(1) == '!';
      selection = _parseIndexSelection(bracketMatch.group(2)!);
      selector = selector.substring(0, bracketMatch.start);
      if (excludes) {
        return _LegacySelector(
          css: _legacyCss(selector),
          excludedSelection: selection,
        );
      }
    } else {
      final indexMatch = RegExp(r'\.(-?\d+(?::-?\d+)*)$').firstMatch(selector);
      if (indexMatch != null) {
        selection = indexMatch
            .group(1)!
            .split(':')
            .map((value) => _IndexSpec.single(int.parse(value)))
            .toList(growable: false);
        selector = selector.substring(0, indexMatch.start);
      }
    }
    String? text;
    if (selector.startsWith('text.')) {
      text = selector.substring(5);
      selector = '*';
    } else {
      selector = _legacyCss(selector);
    }
    if (selector.isEmpty) selector = '*';
    return _LegacySelector(
      css: selector,
      selection: selection,
      exclude: exclude,
      text: text,
    );
  }

  List<Object?> _jsonPath(Object? root, String path) {
    var normalized = path.trim();
    if (normalized == r'$') return [root];
    if (normalized.startsWith(r'$')) {
      try {
        return JsonPath(
          _normalizeLegacyJsonPath(normalized),
        ).read(root).map((match) => match.value).toList(growable: false);
      } on Object catch (error) {
        throw BookSourceProtocolException(
          'reading source JSONPath could not be evaluated: $error',
        );
      }
    }
    if (normalized.startsWith(r'$.')) normalized = normalized.substring(2);
    final tokens = RegExp(r'([^.\[\]]+)|\[(-?\d+|\*)\]')
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
            final index = _normalizedIndex(rawIndex, value.length);
            if (index >= 0 && index < value.length) next.add(value[index]);
          }
        }
      }
      values = next;
    }
    return values;
  }

  String _interpolate(
    String template,
    Object? context,
    SourceRuleDocument doc,
  ) {
    return template.replaceAllMapped(RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'), (
      match,
    ) {
      final expression = match.group(1)!;
      if ((expression.startsWith('"') && expression.endsWith('"')) ||
          (expression.startsWith("'") && expression.endsWith("'"))) {
        return expression.substring(1, expression.length - 1);
      }
      final selected = _jsonPath(context, expression).map(_stringValue).join();
      if (selected.isNotEmpty || !_looksLikeScriptExpression(expression)) {
        return selected;
      }
      return _stringValue(_evaluateScript(doc, context, expression));
    });
  }

  Future<String> _interpolateAsync(
    String template,
    Object? context,
    SourceRuleDocument document,
  ) async {
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
        final selected = _jsonPath(
          context,
          expression,
        ).map(_stringValue).join();
        if (selected.isNotEmpty || !_looksLikeScriptExpression(expression)) {
          output.write(selected);
        } else {
          output.write(
            _stringValue(
              await _evaluateScriptAsync(document, context, expression),
            ),
          );
        }
      }
      offset = match.end;
    }
    output.write(template.substring(offset));
    return output.toString();
  }

  List<Object?> _rawValues(SourceRuleDocument document, Object? context) {
    final value = context ?? document.value;
    return switch (value) {
      Document document => [document.outerHtml],
      Element element => [element.outerHtml],
      _ => [value],
    };
  }
}

String _normalizeLegacyJsonPath(String input) {
  // Some source files wrap filter expressions in `?(`...`)`, while
  // RFC 9535 uses `?` followed directly by the logical expression.
  return input.replaceAllMapped(RegExp(r'\[\?\((.*?)\)\]'), (match) {
    return '[?${match.group(1)}]';
  });
}

const _htmlAttributeNames = {
  'href',
  'src',
  'content',
  'value',
  'title',
  'alt',
  'data',
  'action',
};

class _RuleTransform {
  const _RuleTransform({
    required this.selector,
    this.pattern,
    this.replacement = '',
  });

  final String selector;
  final String? pattern;
  final String replacement;
}

RegExp _jsoupAttributeRegExp(String source) {
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

final _jsoupAttributeRegexSelector = RegExp(
  r'\[\s*([A-Za-z_][A-Za-z0-9_.:-]*)\s*~=\s*([^\]\r\n]+?)\s*\]',
);

class _ScriptRule {
  const _ScriptRule({
    required this.selector,
    required this.script,
    required this.suffix,
  });

  final String selector;
  final String script;
  final String suffix;
}

class _PutRule {
  const _PutRule({required this.selector, required this.mappings});

  final String selector;
  final Map<String, String> mappings;
}

_PutRule? _splitPutRule(String rule) {
  final match = RegExp(
    r'@put:\s*\{([\s\S]*)\}\s*$',
    caseSensitive: false,
  ).firstMatch(rule);
  if (match == null) return null;
  final mappings = <String, String>{};
  for (final entry in _splitTopLevel(match.group(1)!, ',')) {
    final parts = _splitTopLevel(entry, ':', limit: 2);
    if (parts.length != 2) continue;
    final key = _stripRuleQuotes(parts.first.trim());
    final value = _stripRuleQuotes(parts.last.trim());
    if (key.isNotEmpty && value.isNotEmpty) mappings[key] = value;
  }
  if (mappings.isEmpty) return null;
  return _PutRule(
    selector: rule.substring(0, match.start),
    mappings: Map.unmodifiable(mappings),
  );
}

String _expandStateGets(String rule, Map<String, Object?> state) {
  return rule.replaceAllMapped(
    RegExp(r'@get:\s*\{\s*([^{}]+?)\s*\}', caseSensitive: false),
    (match) => '${state[_stripRuleQuotes(match.group(1)!.trim())] ?? ''}',
  );
}

List<String> _splitTopLevel(String input, String separator, {int? limit}) {
  final parts = <String>[];
  var start = 0;
  var depth = 0;
  String? quote;
  var escaped = false;
  for (var index = 0; index < input.length; index++) {
    final char = input[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == '\\') {
      escaped = true;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == '"' || char == "'" || char == '`') {
      quote = char;
      continue;
    }
    if (char == '{' || char == '[' || char == '(') depth++;
    if (char == '}' || char == ']' || char == ')') depth--;
    if (depth == 0 && input.startsWith(separator, index)) {
      parts.add(input.substring(start, index));
      index += separator.length - 1;
      start = index + 1;
      if (limit != null && parts.length == limit - 1) break;
    }
  }
  parts.add(input.substring(start));
  return parts;
}

String _stripRuleQuotes(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('`') && value.endsWith('`')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

_ScriptRule? _splitScriptRule(String rule) {
  final lowered = rule.toLowerCase();
  final atIndex = lowered.indexOf('@js:');
  final tag = RegExp(
    r'<js>(.*?)</js>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(rule);
  if (atIndex < 0 && tag == null) return null;
  if (atIndex >= 0 && (tag == null || atIndex < tag.start)) {
    return _ScriptRule(
      selector: rule.substring(0, atIndex),
      script: rule.substring(atIndex + 4),
      suffix: '',
    );
  }
  return _ScriptRule(
    selector: rule.substring(0, tag!.start),
    script: tag.group(1)!,
    suffix: rule.substring(tag.end),
  );
}

_RuleTransform _splitTransform(String rule) {
  final parts = rule.split('##');
  if (parts.length == 1) return _RuleTransform(selector: rule);
  return _RuleTransform(
    selector: parts.first,
    pattern: parts.length > 1 ? parts[1] : null,
    replacement: parts.length > 2
        ? parts[2].replaceFirst(RegExp(r'###$'), '')
        : '',
  );
}

class _LegacySelector {
  const _LegacySelector({
    required this.css,
    this.selection,
    this.excludedSelection,
    this.exclude,
    this.text,
  });

  final String css;
  final List<_IndexSpec>? selection;
  final List<_IndexSpec>? excludedSelection;
  final int? exclude;
  final String? text;
}

class _IndexSpec {
  const _IndexSpec.single(int value) : start = value, end = value, step = 1;

  const _IndexSpec.range(this.start, this.end, this.step);

  final int? start;
  final int? end;
  final int step;
}

List<_IndexSpec> _parseIndexSelection(String input) {
  final specs = <_IndexSpec>[];
  for (final raw in input.split(',')) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    final parts = value.split(':').map((part) => part.trim()).toList();
    if (parts.length == 1) {
      final index = int.tryParse(parts.single);
      if (index != null) specs.add(_IndexSpec.single(index));
      continue;
    }
    final start = parts.first.isEmpty ? null : int.tryParse(parts.first);
    final end = parts[1].isEmpty ? null : int.tryParse(parts[1]);
    final step = parts.length > 2 ? int.tryParse(parts[2]) ?? 1 : 1;
    specs.add(_IndexSpec.range(start, end, step));
  }
  return specs;
}

Iterable<int> _selectionIndexes(List<_IndexSpec> specs, int length) sync* {
  final seen = <int>{};
  for (final spec in specs) {
    var start = spec.start ?? 0;
    var end = spec.end ?? length - 1;
    start = _normalizedIndex(start, length).clamp(0, length - 1);
    end = _normalizedIndex(end, length).clamp(0, length - 1);
    final distance = (end - start).abs();
    var step = spec.step.abs();
    if (step == 0 || (spec.step < 0 && step < length)) {
      step = spec.step < 0 ? length - step : 1;
    }
    if (distance == 0 || step > distance) {
      if (seen.add(start)) yield start;
      continue;
    }
    if (start <= end) {
      for (var index = start; index <= end; index += step) {
        if (seen.add(index)) yield index;
      }
    } else {
      for (var index = start; index >= end; index -= step) {
        if (seen.add(index)) yield index;
      }
    }
  }
}

String _legacyCss(String selector) {
  if (selector.startsWith('class.')) {
    final classNames = selector
        .substring(6)
        .trim()
        .split(RegExp(r'\s+'))
        .where((name) => name.isNotEmpty);
    return classNames.map((name) => '.$name').join();
  }
  if (selector.startsWith('id.')) return '#${selector.substring(3)}';
  if (selector.startsWith('tag.')) return selector.substring(4);
  return selector.isEmpty ? '*' : selector;
}

List<Object?> _interleave(List<List<Object?>> groups) {
  final values = <Object?>[];
  final length = groups.fold<int>(
    0,
    (maximum, group) => group.length > maximum ? group.length : maximum,
  );
  for (var index = 0; index < length; index++) {
    for (final group in groups) {
      if (index < group.length) values.add(group[index]);
    }
  }
  return values;
}

enum _XPathAxis { child, descendant, followingSibling }

class _XPathStep {
  const _XPathStep({
    required this.axis,
    required this.test,
    this.predicates = const [],
  });

  final _XPathAxis axis;
  final String test;
  final List<String> predicates;
}

List<_XPathStep> _parseXPathSteps(String input) {
  final steps = <_XPathStep>[];
  var index = 0;
  var axis = _XPathAxis.child;
  while (index < input.length) {
    if (input.startsWith('//', index)) {
      axis = _XPathAxis.descendant;
      index += 2;
    } else if (input[index] == '/') {
      axis = _XPathAxis.child;
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
      stepAxis = _XPathAxis.followingSibling;
      raw = raw.substring('following-sibling::'.length);
    }
    final test = raw.split('[').first.trim();
    final predicates = RegExp(r'\[([^\]]+)\]')
        .allMatches(raw)
        .map((match) => match.group(1)!.trim())
        .toList(growable: false);
    steps.add(_XPathStep(axis: stepAxis, test: test, predicates: predicates));
    axis = _XPathAxis.child;
  }
  return steps;
}

bool _xpathMatches(Element element, _XPathStep step) {
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
      if (_ownText(element).trim() != textEquals.group(2)) return false;
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
      if (_xpathSiblingPosition(element, step.test) != position) return false;
      continue;
    }
    final greaterThan = RegExp(
      r'^position\(\)\s*>\s*(\d+)$',
    ).firstMatch(predicate);
    if (greaterThan != null) {
      if (_xpathSiblingPosition(element, step.test) <=
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

int _xpathSiblingPosition(Element element, String test) {
  final siblings = element.parent?.children ?? const <Element>[];
  var position = 0;
  for (final sibling in siblings) {
    if (test == '*' || sibling.localName == test.toLowerCase()) position++;
    if (identical(sibling, element)) return position;
  }
  return -1;
}

Iterable<Element> _followingSiblings(Element element) sync* {
  final siblings = element.parent?.children ?? const <Element>[];
  var found = false;
  for (final sibling in siblings) {
    if (found) yield sibling;
    if (identical(sibling, element)) found = true;
  }
}

int _normalizedIndex(int index, int length) =>
    index < 0 ? length + index : index;

String _ownText(Element element) =>
    element.nodes.whereType<Text>().map((node) => node.data).join().trim();

String _directTextNodes(Element element) => element.nodes
    .whereType<Text>()
    .map((node) => node.data.trim())
    .where((value) => value.isNotEmpty)
    .join('\n');

bool _matches(Element element, String selector) {
  final parent = element.parent;
  if (parent != null) {
    return parent.querySelectorAll(selector).contains(element);
  }
  return selector == '*' || selector == element.localName;
}

String _resolveRuleRequestUrl(Uri baseUri, String value, String errorMessage) {
  final urlText = value.split(RegExp(r',\s*\{')).first.trim();
  final directUri = Uri.tryParse(urlText);
  if (directUri?.scheme == 'data') {
    return value;
  }
  final resolved = resolveSourceRequestUrl(baseUri, value);
  final uri = Uri.tryParse(resolved.split(RegExp(r',\s*\{')).first);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw BookSourceProtocolException(errorMessage);
  }
  return resolved;
}

String _stringValue(Object? value) => switch (value) {
  null => '',
  String text => text,
  num number => '$number',
  bool boolean => '$boolean',
  Element element => element.text,
  _RegexRuleContext match => match.fullMatch,
  _ => '$value',
};

String _rawString(Object? value) => switch (value) {
  Document document => document.outerHtml,
  Element element => element.outerHtml,
  _RegexRuleContext match => match.fullMatch,
  null => '',
  _ => '$value',
};

Object? _scriptInput(Object? value) => switch (value) {
  Document document => document.outerHtml,
  Element element => element.outerHtml,
  Iterable values => values.map(_scriptInput).toList(growable: false),
  _ => value,
};

bool _looksLikeScriptExpression(String value) => RegExp(
  r'\b(?:source|java|result|book|chapter)\b|[=;]|\b(?:if|let|var|const|function)\b',
).hasMatch(value);

bool _looksLikeProtocolRelativeUrl(String value) => RegExp(
  r'^//[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?::\d+)?(?:[/#?]|$)',
).hasMatch(value.trimLeft());

bool _looksLikeXPathRule(String value) {
  final text = value.trimLeft();
  if (text.toLowerCase().startsWith('@xpath:')) return true;
  return text.startsWith('//') && !_looksLikeProtocolRelativeUrl(text);
}

class _RegexRuleContext {
  _RegexRuleContext(RegExpMatch match)
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

String _replaceRegex(String input, RegExp pattern, String replacement) {
  return input.replaceAllMapped(pattern, (match) {
    return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
      final index = int.tryParse(capture.group(1)!);
      if (index == null || index > match.groupCount) return capture.group(0)!;
      return match.group(index) ?? '';
    });
  });
}

String _extractRegex(String input, RegExp pattern, String replacement) {
  final match = pattern.firstMatch(input);
  if (match == null) return '';
  return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (capture) {
    final index = int.tryParse(capture.group(1)!);
    if (index == null || index > match.groupCount) return capture.group(0)!;
    return match.group(index) ?? '';
  });
}
