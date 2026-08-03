import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_explore.dart';
import 'source_request.dart';
import 'source_rule_engine.dart';
import 'source_script_engine.dart';
import '../services/book_download_cancellation.dart';

class SourceRuntime {
  // Public parameter name intentionally differs from the private mutable field.
  SourceRuntime({
    SourceTransport? transport,
    SourceScriptEvaluator? scriptEvaluator,
  }) : _transport = transport ?? SourceHttpTransport(),
       // ignore: prefer_initializing_formals
       _scriptEvaluator = scriptEvaluator;

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;
  static const int _maxRememberedBookStates = 1024;

  final SourceTransport _transport;
  late final SourceRuleEngine _rules = SourceRuleEngine(
    scriptEvaluatorProvider: () => _scripts,
  );
  SourceScriptEvaluator? _scriptEvaluator;
  final Map<String, Map<String, Object?>> _bookRuleStates = {};

  SourceScriptEvaluator get _scripts =>
      _scriptEvaluator ??= QuickJsSourceScriptEvaluator();

  void close({bool force = true}) {
    _bookRuleStates.clear();
    _scriptEvaluator?.dispose();
    _scriptEvaluator = null;
    final transport = _transport;
    if (transport is SourceHttpTransport) transport.close(force: force);
  }

  Future<BookSourceSearchPage> search(
    RegisteredBookSource registered,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    final source = _source(registered);
    _ensureRulesSupported(source, const ['ruleSearch']);
    final response = await _request(
      source,
      source.searchUrl,
      variables: {'key': query.trim(), 'page': '$page'},
      cancellation: cancellation,
    );
    final document = _document(
      source,
      response,
      variables: {'key': query, 'page': '$page'},
    );
    final rule = source.rule('ruleSearch');
    final contexts = await _rules.evaluateListAsync(
      document,
      null,
      _requiredRule(rule, 'bookList'),
    );
    if (page == 1 && contexts.isEmpty) {
      throw const BookSourceProtocolException(
        'The channel page opened, but its bookList rule matched no items. '
        'The source rule may be outdated.',
      );
    }
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(source, document, context, rule);
      if (book != null) books.add(book);
    }
    if (page == 1 && books.isEmpty) {
      throw const BookSourceProtocolException(
        'The channel list matched elements, but none contained both a book '
        'name and URL. The source rule may be outdated.',
      );
    }
    return BookSourceSearchPage(
      items: books.take(pageSize).toList(growable: false),
      page: page,
      pageSize: pageSize,
      hasMore: books.length > pageSize,
    );
  }

  Future<List<BookSourceCategory>> getExploreCategories(
    RegisteredBookSource registered,
  ) async {
    final source = _source(registered);
    final catalog = await _exploreCatalog(source);
    if (!catalog.canBrowse) {
      throw BookSourceProtocolException(
        catalog.error ?? 'This compatible source has no discovery channels.',
      );
    }
    return catalog.entries
        .map((entry) => BookSourceCategory(id: entry.url, name: entry.title))
        .toList(growable: false);
  }

  Future<BookSourceSearchPage> browse(
    RegisteredBookSource registered, {
    required String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    final source = _source(registered);
    final catalog = await _exploreCatalog(source);
    if (!catalog.canBrowse) {
      throw BookSourceProtocolException(
        catalog.error ?? 'This compatible source has no discovery channels.',
      );
    }
    final entry = catalog.entries
        .where((entry) => entry.url == category)
        .firstOrNull;
    if (entry == null) {
      throw const BookSourceProtocolException(
        'Choose a discovery channel before browsing this source.',
      );
    }
    final response = await _request(
      source,
      entry.url,
      variables: {'page': '$page'},
    );
    final document = _document(source, response, variables: {'page': '$page'});
    final exploreRule = source.rule('ruleExplore');
    final rule = _optionalRule(exploreRule, 'bookList').isEmpty
        ? source.rule('ruleSearch')
        : exploreRule;
    _ensureRulesSupported(
      source,
      _optionalRule(exploreRule, 'bookList').isEmpty
          ? const ['ruleSearch']
          : const ['ruleExplore'],
    );
    final contexts = await _rules.evaluateListAsync(
      document,
      null,
      _requiredRule(rule, 'bookList'),
    );
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(source, document, context, rule);
      if (book != null) books.add(book);
    }
    return BookSourceSearchPage(
      items: books,
      page: page,
      pageSize: books.isEmpty ? pageSize : books.length,
      // Imported source pages do not carry a hasMore envelope. Probe the next
      // page after a non-empty result; stop when the page is empty or adds no
      // new source/book identities.
      hasMore: books.isNotEmpty,
    );
  }

  Future<BookSourceBook> getBook(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = _source(registered);
    _ensureRulesSupported(source, const ['ruleBookInfo']);
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final response = await _request(
      source,
      bookId,
      variables: _requestVariables(ruleState, {'bookUrl': bookId}),
    );
    final document = _document(
      source,
      response,
      variables: {'bookUrl': bookId},
      ruleState: ruleState,
    );
    final rule = source.rule('ruleBookInfo');
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateListAsync(document, null, init)).firstOrNull;
    final title = await _value(document, context, rule, 'name');
    if (title.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return a book title.',
      );
    }
    final book = BookSourceBook(
      id: response.finalUri.toString(),
      title: title,
      author: await _value(document, context, rule, 'author'),
      description: await _value(document, context, rule, 'intro'),
      coverUrl: await _uriValue(document, context, rule, 'coverUrl'),
      categories: _splitCategories(
        await _value(document, context, rule, 'kind'),
      ),
      status: _nullable(await _value(document, context, rule, 'status')),
      latestChapter: _nullable(
        await _value(document, context, rule, 'lastChapter'),
      ),
      sourceVariables: _sourceVariables(document.ruleState),
    );
    _rememberRuleState(source, bookId, document.ruleState);
    _rememberRuleState(source, book.id, document.ruleState);
    return book;
  }

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = _source(registered);
    _ensureRulesSupported(source, const ['ruleBookInfo', 'ruleToc']);
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final tocUrl = await _tocUrl(source, bookId, ruleState);
    final rule = source.rule('ruleToc');
    final chapters = <BookSourceChapter>[];
    final seenPages = <String>{};
    final seenChapters = <String>{};
    var nextUrl = tocUrl;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(
        source,
        nextUrl,
        variables: _requestVariables(ruleState, {'bookUrl': bookId}),
      );
      final document = _document(
        source,
        response,
        variables: {'bookUrl': bookId},
        ruleState: ruleState,
      );
      final contexts = await _rules.evaluateListAsync(
        document,
        null,
        _requiredRule(rule, 'chapterList'),
      );
      for (final context in contexts) {
        final title = await _value(document, context, rule, 'chapterName');
        final url = await _url(document, context, rule, 'chapterUrl');
        if (title.isEmpty || url.isEmpty || !seenChapters.add(url)) continue;
        if (chapters.length >= _maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        chapters.add(
          BookSourceChapter(id: url, title: title, order: chapters.length),
        );
      }
      nextUrl = await _url(document, null, rule, 'nextTocUrl');
    }
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    _rememberRuleState(source, bookId, ruleState);
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = _source(registered);
    _ensureRulesSupported(source, const ['ruleContent']);
    final rule = source.rule('ruleContent');
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final parts = <String>[];
    final seenPages = <String>{};
    var nextUrl = chapterId;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _request(
        source,
        nextUrl,
        variables: _requestVariables(ruleState, {
          'bookUrl': bookId,
          'chapterUrl': chapterId,
        }),
      );
      final document = _document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': chapterId},
        ruleState: ruleState,
      );
      var content = await _value(
        document,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      content = _rules.applyReplaceRule(
        content,
        _optionalRule(rule, 'replaceRegex'),
      );
      if (content.trim().isNotEmpty) parts.add(content.trim());
      nextUrl = await _url(document, null, rule, 'nextContentUrl');
    }
    if (parts.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    _rememberRuleState(source, bookId, ruleState);
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: '',
      content: parts.join('\n\n'),
      contentType: 'text/html',
    );
  }

  Future<String> _tocUrl(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> ruleState,
  ) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final response = await _request(
      source,
      bookId,
      variables: _requestVariables(ruleState, {'bookUrl': bookId}),
    );
    final document = _document(
      source,
      response,
      variables: {'bookUrl': bookId},
      ruleState: ruleState,
    );
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateListAsync(document, null, init)).firstOrNull;
    return _rules.evaluateStringAsync(
      document,
      context,
      tocRule,
      resolveUrl: true,
    );
  }

  Future<BookSourceBook?> _bookFromRules(
    ReadingSourceConfig source,
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rule,
  ) async {
    final title = await _value(document, context, rule, 'name');
    final url = await _url(document, context, rule, 'bookUrl');
    if (title.isEmpty || url.isEmpty) return null;
    final book = BookSourceBook(
      id: url,
      title: title,
      author: await _value(document, context, rule, 'author'),
      description: await _value(document, context, rule, 'intro'),
      coverUrl: await _uriValue(document, context, rule, 'coverUrl'),
      categories: _splitCategories(
        await _value(document, context, rule, 'kind'),
      ),
      latestChapter: _nullable(
        await _value(document, context, rule, 'lastChapter'),
      ),
      sourceVariables: _sourceVariables(document.ruleState),
    );
    _rememberRuleState(source, book.id, document.ruleState);
    return book;
  }

  Future<SourceResponse> _request(
    ReadingSourceConfig source,
    String template, {
    Map<String, String> variables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    final expandedTemplate = await _expandScriptTemplate(
      source,
      template,
      variables,
    );
    return _transport.send(
      SourceRequestTemplate.parse(
        expandedTemplate,
        baseUri: source.baseUri,
        variables: variables,
        sourceHeaders: await _sourceHeaders(source),
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      ),
      cancellation: cancellation,
    );
  }

  SourceRuleDocument _document(
    ReadingSourceConfig source,
    SourceResponse response, {
    Map<String, String> variables = const {},
    Map<String, Object?>? ruleState,
  }) {
    final state = ruleState ?? <String, Object?>{};
    return SourceRuleDocument.parse(
      response.body,
      response.finalUri,
      ruleState: state,
      scriptContext: SourceScriptContext(
        source: source,
        baseUrl: response.finalUri,
        variables: _requestVariables(state, variables),
        networkHandler: (request) => _sendScriptNetwork(source, request),
      ),
    );
  }

  Map<String, Object?> _ruleStateFor(
    ReadingSourceConfig source,
    String bookId,
    Map<String, String> sourceVariables,
  ) {
    final state = <String, Object?>{
      ...?_bookRuleStates[_bookStateKey(source, bookId)],
      ...sourceVariables,
    };
    for (final entry in _inferRuleState(source, bookId).entries) {
      state.putIfAbsent(entry.key, () => entry.value);
    }
    return state;
  }

  Map<String, String> _inferRuleState(
    ReadingSourceConfig source,
    String bookId,
  ) {
    final actualUrl = bookId.split(RegExp(r',\s*\{')).first;
    for (final groupName in const ['ruleSearch', 'ruleExplore']) {
      final rule = source.rule(groupName);
      final bookUrlRule = _optionalRule(rule, 'bookUrl');
      final templateMatch = RegExp(
        r'\{\{\s*\$\.\.?([A-Za-z_]\w*)\s*\}\}',
      ).firstMatch(bookUrlRule);
      if (templateMatch == null ||
          RegExp(
                r'\{\{\s*\$\.\.?[A-Za-z_]\w*\s*\}\}',
              ).allMatches(bookUrlRule).length !=
              1) {
        continue;
      }
      const marker = 'OPEN_READING_BOOK_VARIABLE_MARKER';
      final resolvedPattern = resolveSourceRequestUrl(
        source.baseUri,
        bookUrlRule.replaceRange(
          templateMatch.start,
          templateMatch.end,
          marker,
        ),
      ).split(RegExp(r',\s*\{')).first;
      final markerIndex = resolvedPattern.indexOf(marker);
      if (markerIndex < 0) continue;
      final prefix = resolvedPattern.substring(0, markerIndex);
      final suffix = resolvedPattern.substring(markerIndex + marker.length);
      if (!actualUrl.startsWith(prefix) ||
          !actualUrl.endsWith(suffix) ||
          actualUrl.length < prefix.length + suffix.length) {
        continue;
      }
      final captured = actualUrl.substring(
        prefix.length,
        actualUrl.length - suffix.length,
      );
      if (captured.isEmpty) continue;
      final property = templateMatch.group(1)!;
      for (final value in rule.values.whereType<String>()) {
        final putMatch = RegExp(
          r'@put:\s*\{([\s\S]*)\}\s*$',
          caseSensitive: false,
        ).firstMatch(value);
        if (putMatch == null) continue;
        for (final mapping in RegExp(
          r'''["']?([A-Za-z_]\w*)["']?\s*:\s*(?:\$\.\.?)?([A-Za-z_]\w*)''',
        ).allMatches(putMatch.group(1)!)) {
          if (mapping.group(2) == property) {
            return {mapping.group(1)!: Uri.decodeComponent(captured)};
          }
        }
      }
    }
    return const {};
  }

  void _rememberRuleState(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> state,
  ) {
    if (bookId.trim().isEmpty || state.isEmpty) return;
    final key = _bookStateKey(source, bookId);
    _bookRuleStates.remove(key);
    _bookRuleStates[key] = Map<String, Object?>.from(state);
    while (_bookRuleStates.length > _maxRememberedBookStates) {
      _bookRuleStates.remove(_bookRuleStates.keys.first);
    }
  }

  String _bookStateKey(ReadingSourceConfig source, String bookId) =>
      '${source.stableId}\u0000$bookId';

  Map<String, String> _requestVariables(
    Map<String, Object?> state,
    Map<String, String> variables,
  ) => <String, String>{
    for (final entry in state.entries)
      if (entry.value != null) entry.key: '${entry.value}',
    ...variables,
  };

  Map<String, String> _sourceVariables(Map<String, Object?> state) =>
      Map.unmodifiable(_requestVariables(state, const {}));

  Future<Map<String, String>> _sourceHeaders(ReadingSourceConfig source) async {
    final raw = source.raw['header'];
    if (raw == null || '$raw'.trim().isEmpty) return const {};
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        final script = _scriptBody(raw) ?? 'JSON.stringify(($raw))';
        decoded = await _scripts.evaluateAsync(
          script,
          SourceScriptContext(
            source: source,
            baseUrl: source.baseUri,
            networkHandler: (request) => _sendScriptNetwork(
              source,
              request,
              includeSourceHeaders: false,
            ),
          ),
        );
        if (decoded is String) {
          try {
            decoded = jsonDecode(decoded);
          } on FormatException {
            throw const BookSourceProtocolException(
              'Reading source header script must return a JSON object.',
            );
          }
        }
      }
    }
    if (decoded is! Map) {
      throw const BookSourceProtocolException(
        'Compatible source headers must be an object.',
      );
    }
    final headers = <String, String>{};
    for (final entry in decoded.entries) {
      final name = '${entry.key}'.trim();
      if (name.isEmpty || entry.value is! String) {
        throw const BookSourceProtocolException(
          'Compatible source headers must contain text values.',
        );
      }
      headers[name] = _expandSourceHeaderValue(entry.value as String, source);
    }
    return headers;
  }

  String _expandSourceHeaderValue(String value, ReadingSourceConfig source) {
    final key = source.url;
    final baseKey = key.split('#').first;
    return value
        .replaceAll('{{source.getKey()}}', key)
        .replaceAll('{{source.bookSourceUrl}}', key)
        .replaceAll('{{bookSourceUrl}}', key)
        .replaceAllMapped(
          RegExp(r'\{\{source\.getKey\(\)\.match\([^}]+\}\}'),
          (_) => baseKey,
        )
        .replaceAllMapped(
          RegExp(r'\{\{source\.getVariable\(\).*?\}\}', dotAll: true),
          (_) => key,
        );
  }

  Future<String> _expandScriptTemplate(
    ReadingSourceConfig source,
    String template,
    Map<String, String> variables,
  ) async {
    SourceScriptContext context() => SourceScriptContext(
      source: source,
      baseUrl: source.baseUri,
      variables: variables,
      networkHandler: (request) => _sendScriptNetwork(source, request),
    );
    final trimmed = template.trimLeft();
    final directScript = _scriptBody(template);
    if (directScript != null &&
        (trimmed.startsWith('@js:') || trimmed.startsWith('<js>'))) {
      return _scriptText(await _scripts.evaluateAsync(directScript, context()));
    }
    var expanded = await _replaceAsync(
      template,
      RegExp(r'<js>(.*?)</js>', caseSensitive: false, dotAll: true),
      (match) async =>
          _scriptText(await _scripts.evaluateAsync(match.group(1)!, context())),
    );
    expanded = await _replaceAsync(
      expanded,
      RegExp(r'\{\{\s*([^{}]+?)\s*\}\}'),
      (match) async {
        final expression = match.group(1)!.trim();
        if (_isDeclarativeVariable(expression, variables)) {
          return match.group(0)!;
        }
        return _scriptText(await _scripts.evaluateAsync(expression, context()));
      },
    );
    return expanded;
  }

  Future<SourceExploreCatalog> _exploreCatalog(
    ReadingSourceConfig source,
  ) async {
    final staticCatalog = source.exploreCatalog;
    if (staticCatalog.canBrowse || source.exploreUrl.trim().isEmpty) {
      return staticCatalog;
    }
    final expanded = await _expandScriptTemplate(
      source,
      source.exploreUrl,
      const {'page': '1'},
    );
    return parseSourceExploreCatalog({...source.raw, 'exploreUrl': expanded});
  }

  ReadingSourceConfig _source(RegisteredBookSource registered) {
    if (registered.sourceProtocol != BookSourceProtocolKind.readingSource ||
        registered.sourceConfig == null) {
      throw const BookSourceProtocolException(
        'This is not a compatible source configuration.',
      );
    }
    return ReadingSourceConfig.fromJson(registered.sourceConfig!);
  }

  void _ensureRulesSupported(
    ReadingSourceConfig source,
    Iterable<String> groupNames,
  ) {
    for (final groupName in groupNames) {
      for (final entry in source.rule(groupName).entries) {
        if (entry.value is String) {
          SourceRuleEngine.ensureSupported(
            entry.value as String,
            field: '$groupName.${entry.key}',
          );
        }
      }
    }
  }

  Future<String> _value(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key, {
    bool required = false,
    String joinSeparator = '',
    bool regexDotAll = true,
  }) async {
    final rule = required
        ? _requiredRule(rules, key)
        : _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateStringAsync(
      document,
      context,
      rule,
      joinSeparator: joinSeparator,
      regexDotAll: regexDotAll,
    );
  }

  Future<String> _url(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final rule = _optionalRule(rules, key);
    if (rule.isEmpty) return '';
    return _rules.evaluateStringAsync(
      document,
      context,
      rule,
      resolveUrl: true,
    );
  }

  Future<Uri?> _uriValue(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final value = await _url(document, context, rules, key);
    return value.isEmpty ? null : Uri.tryParse(value);
  }

  Future<SourceScriptNetworkResult> _sendScriptNetwork(
    ReadingSourceConfig source,
    SourceScriptNetworkRequest request, {
    bool includeSourceHeaders = true,
  }) async {
    final method = request.method.toUpperCase();
    if (method != 'GET' && method != 'POST' && method != 'WEBVIEW') {
      throw BookSourceProtocolException(
        'Source script requested unsupported HTTP method $method.',
      );
    }
    final headers = <String, String>{
      if (includeSourceHeaders) ...await _sourceHeaders(source),
      ...request.headers,
    };
    if (method == 'WEBVIEW') {
      final baseRequest = SourceRequestTemplate.parse(
        request.url,
        baseUri: source.baseUri,
        sourceHeaders: headers,
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      );
      final response = await _transport.send(
        SourceRequestTemplate(
          url: baseRequest.url,
          method: SourceRequestMethod.get,
          headers: baseRequest.headers,
          charset: baseRequest.charset,
          useWebView: true,
          webJs: request.webJs,
          webViewHtml: request.body,
          cookieJarKey: baseRequest.cookieJarKey,
        ),
      );
      return SourceScriptNetworkResult(
        body: response.body,
        finalUrl: response.finalUri.toString(),
      );
    }
    var template = request.url;
    if (method == 'POST') {
      template =
          '$template,${jsonEncode({'method': 'POST', 'body': request.body ?? '', if (headers.isNotEmpty) 'headers': headers})}';
      headers.clear();
    }
    final response = await _transport.send(
      SourceRequestTemplate.parse(
        template,
        baseUri: source.baseUri,
        sourceHeaders: headers,
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      ),
    );
    return SourceScriptNetworkResult(
      body: response.body,
      finalUrl: response.finalUri.toString(),
    );
  }
}

Future<String> _replaceAsync(
  String input,
  RegExp pattern,
  Future<String> Function(RegExpMatch match) replacement,
) async {
  final output = StringBuffer();
  var offset = 0;
  for (final match in pattern.allMatches(input)) {
    output.write(input.substring(offset, match.start));
    output.write(await replacement(match));
    offset = match.end;
  }
  output.write(input.substring(offset));
  return output.toString();
}

String? _scriptBody(String value) {
  final trimmed = value.trim();
  if (trimmed.toLowerCase().startsWith('@js:')) {
    return trimmed.substring(4).trimLeft();
  }
  final match = RegExp(
    r'^<js>(.*?)</js>$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(trimmed);
  return match?.group(1);
}

bool _isDeclarativeVariable(String expression, Map<String, String> variables) {
  if (variables.containsKey(expression)) return true;
  final arithmetic = RegExp(
    r'^([A-Za-z_]\w*)\s*[+-]\s*\d+$',
  ).firstMatch(expression);
  return arithmetic != null && variables.containsKey(arithmetic.group(1));
}

String _scriptText(Object? value) => switch (value) {
  null => '',
  String text => text,
  Map _ || List _ => jsonEncode(value),
  _ => '$value',
};

String _requiredRule(Map<String, dynamic> rules, String key) {
  final rule = _optionalRule(rules, key);
  if (rule.isEmpty) {
    throw BookSourceProtocolException(
      'Compatible source is missing the $key rule.',
    );
  }
  return rule;
}

String _optionalRule(Map<String, dynamic> rules, String key) {
  final value = rules[key];
  return value is String ? value.trim() : '';
}

String? _nullable(String value) => value.trim().isEmpty ? null : value.trim();

List<String> _splitCategories(String value) => value
    .split(RegExp(r'[,/|\s]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

String stableSourceResourceId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 24);
