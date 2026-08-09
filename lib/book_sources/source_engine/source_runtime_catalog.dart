import 'dart:convert';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import 'source_config.dart';
import 'source_explore.dart';
import 'source_request_template.dart';
import 'source_rule_engine.dart';
import 'source_runtime_login.dart';
import 'source_runtime_requests.dart';
import 'source_runtime_rules.dart';
import 'source_runtime_state.dart';

class SourceRuntimeCatalog {
  SourceRuntimeCatalog({
    required SourceRuntimeRequestPort requests,
    required SourceRuntimeRulePort rules,
    required SourceRuntimeState state,
    required SourceRuntimeSessionPort sessions,
  }) : this._(requests, rules, state, sessions);

  SourceRuntimeCatalog._(
    this._requests,
    this._rules,
    this._state,
    this._sessions,
  );

  static const int _maxSearchItems = 100;

  final SourceRuntimeRequestPort _requests;
  final SourceRuntimeRulePort _rules;
  final SourceRuntimeState _state;
  final SourceRuntimeSessionPort _sessions;

  Future<BookSourceSearchPage> search(
    RegisteredBookSource registered,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    final source = sourceFromRegistered(registered);
    final response = await _requests.request(
      source,
      source.searchUrl,
      variables: {'key': query.trim(), 'page': '$page'},
      cancellation: cancellation,
    );
    final document = _requests.document(
      source,
      response,
      variables: {'key': query, 'page': '$page'},
    );
    final rule = source.rule('ruleSearch');
    final contexts = await _rules.list(
      document,
      null,
      _rules.requiredRule(rule, 'bookList'),
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
    await _sessions.flush(source);
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
    final source = sourceFromRegistered(registered);
    final catalog = await _exploreCatalog(source);
    if (!catalog.canBrowse) {
      throw BookSourceProtocolException(
        catalog.error ?? 'This compatible source has no discovery channels.',
      );
    }
    await _sessions.flush(source);
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
    final source = sourceFromRegistered(registered);
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
    final response = await _requests.request(
      source,
      entry.url,
      variables: {'page': '$page'},
    );
    final document = _requests.document(
      source,
      response,
      variables: {'page': '$page'},
    );
    final exploreRule = source.rule('ruleExplore');
    final rule = _rules.optionalRule(exploreRule, 'bookList').isEmpty
        ? source.rule('ruleSearch')
        : exploreRule;
    final contexts = await _rules.list(
      document,
      null,
      _rules.requiredRule(rule, 'bookList'),
    );
    final books = <BookSourceBook>[];
    for (final context in contexts.take(_maxSearchItems)) {
      final book = await _bookFromRules(source, document, context, rule);
      if (book != null) books.add(book);
    }
    await _sessions.flush(source);
    return BookSourceSearchPage(
      items: books,
      page: page,
      pageSize: books.isEmpty ? pageSize : books.length,
      hasMore: books.isNotEmpty,
    );
  }

  Future<BookSourceBook> getBook(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = sourceFromRegistered(registered);
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final bookContext = _state.bookContext(
      source,
      bookId,
      ruleState,
      bookType: bookType(source),
    );
    final response = await _requests.request(
      source,
      decodeSourceDataTarget(bookId) ?? bookId,
      variables: requestVariables(ruleState, {'bookUrl': bookId}),
    );
    _state.rememberBookInfoResponse(source, bookId, response);
    final document = _requests.document(
      source,
      response,
      variables: {'bookUrl': bookId},
      book: bookContext,
      ruleState: ruleState,
    );
    final contextualDocument = document.withScriptEntities(
      book: bookContext,
      bookWriter: (value) => bookContext.addAll(value),
    );
    final rule = source.rule('ruleBookInfo');
    final init = _rules.optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.list(contextualDocument, null, init)).firstOrNull;
    final title = await _rules.value(contextualDocument, context, rule, 'name');
    if (title.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return a book title.',
      );
    }
    final cover = await _remoteAssetValue(
      contextualDocument,
      context,
      rule,
      'coverUrl',
    );
    seedBookMetadata(bookContext, source: source, bookId: bookId, name: title);
    final author = await _rules.value(
      contextualDocument,
      context,
      rule,
      'author',
    );
    bookContext['author'] = author;
    final book = BookSourceBook(
      id: bookId,
      title: title,
      author: author,
      description: await _rules.value(
        contextualDocument,
        context,
        rule,
        'intro',
      ),
      type: bookType(source),
      coverUrl: cover?.url,
      coverHeaders: cover?.headers ?? const {},
      categories: splitCategories(
        await _rules.value(contextualDocument, context, rule, 'kind'),
      ),
      status: nullable(
        await _rules.value(contextualDocument, context, rule, 'status'),
      ),
      latestChapter: nullable(
        await _rules.value(contextualDocument, context, rule, 'lastChapter'),
      ),
      sourceVariables: _bookSourceVariables(
        source,
        ruleState,
        name: title,
        author: author,
        type: bookType(source),
      ),
    );
    _state.rememberBookContext(source, bookId, bookContext);
    _state.rememberRuleState(source, bookId, document.ruleState);
    _state.rememberRuleState(source, book.id, document.ruleState);
    await _sessions.flush(source);
    return book;
  }

  Future<BookSourceBook?> _bookFromRules(
    ReadingSourceConfig source,
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rule,
  ) async {
    final bookContext = _state.bookContext(
      source,
      '',
      document.ruleState,
      bookType: bookType(source),
    );
    final contextualDocument = document.withScriptEntities(
      book: bookContext,
      bookWriter: (value) => bookContext.addAll(value),
    );
    final title = await _rules.value(contextualDocument, context, rule, 'name');
    final url = await _rules.url(contextualDocument, context, rule, 'bookUrl');
    if (title.isEmpty || url.isEmpty) return null;
    seedBookMetadata(bookContext, source: source, bookId: url, name: title);
    final cover = await _remoteAssetValue(
      contextualDocument,
      context,
      rule,
      'coverUrl',
    );
    final author = await _rules.value(
      contextualDocument,
      context,
      rule,
      'author',
    );
    bookContext['author'] = author;
    final book = BookSourceBook(
      id: url,
      title: title,
      author: author,
      description: await _rules.value(
        contextualDocument,
        context,
        rule,
        'intro',
      ),
      type: bookType(source),
      coverUrl: cover?.url,
      coverHeaders: cover?.headers ?? const {},
      categories: splitCategories(
        await _rules.value(contextualDocument, context, rule, 'kind'),
      ),
      latestChapter: nullable(
        await _rules.value(contextualDocument, context, rule, 'lastChapter'),
      ),
      sourceVariables: _bookSourceVariables(
        source,
        document.ruleState,
        name: title,
        author: author,
        type: bookType(source),
      ),
    );
    _state.rememberBookContext(source, book.id, bookContext);
    _state.rememberRuleState(source, book.id, document.ruleState);
    return book;
  }

  Future<SourceExploreCatalog> _exploreCatalog(
    ReadingSourceConfig source,
  ) async {
    final staticCatalog = source.exploreCatalog;
    if (staticCatalog.canBrowse || source.exploreUrl.trim().isEmpty) {
      return staticCatalog;
    }
    final expanded = await _requests.expandScriptTemplate(
      source,
      source.exploreUrl,
      const {'page': '1'},
    );
    return parseSourceExploreCatalog({...source.raw, 'exploreUrl': expanded});
  }

  Map<String, Object?> _ruleStateFor(
    ReadingSourceConfig source,
    String bookId,
    Map<String, String> sourceVariables,
  ) {
    final state = _state.ruleStateFor(source, bookId, sourceVariables);
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
      final bookUrlRule = _rules.optionalRule(rule, 'bookUrl');
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

  Map<String, String> _bookSourceVariables(
    ReadingSourceConfig source,
    Map<String, Object?> state, {
    required String name,
    required String author,
    required int type,
  }) {
    final variables = <String, String>{...requestVariables(state, const {})};
    if (_sourceUsesEntityContext(source)) {
      variables.addAll({
        'bookName': name,
        'bookAuthor': author,
        'bookType': '$type',
      });
    }
    return Map.unmodifiable(variables);
  }

  bool _sourceUsesEntityContext(ReadingSourceConfig source) => <Object?>[
    source.rule('ruleSearch'),
    source.rule('ruleExplore'),
    source.rule('ruleBookInfo'),
    source.rule('ruleToc'),
    source.rule('ruleContent'),
  ].any((rule) => '$rule'.contains(RegExp(r'\b(?:book|chapter)\s*\.')));

  Future<SourceRuntimeRemoteAsset?> _remoteAssetValue(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final value = await _rules.url(document, context, rules, key);
    if (value.isEmpty) return null;
    final source = document.scriptContext?.source;
    final asset = parseRemoteAsset(
      value,
      document.baseUri,
      source == null ? const {} : await _requests.sourceHeaders(source),
    );
    if (asset == null || source == null) return asset;
    final headers = <String, String>{...asset.headers};
    final cookie = _requests.cookieHeader(source, asset.url);
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return SourceRuntimeRemoteAsset(
      url: asset.url,
      headers: Map.unmodifiable(headers),
    );
  }
}

int bookType(ReadingSourceConfig source) => switch (source.type) {
  1 => 32,
  2 => 64,
  3 => 136,
  4 => 4,
  _ => 8,
};

Map<String, Object?> runtimeRuleStateFor(
  SourceRuntimeState stateStore,
  SourceRuntimeRulePort rules,
  ReadingSourceConfig source,
  String bookId,
  Map<String, String> sourceVariables,
) {
  final state = stateStore.ruleStateFor(source, bookId, sourceVariables);
  final actualUrl = bookId.split(RegExp(r',\s*\{')).first;
  for (final groupName in const ['ruleSearch', 'ruleExplore']) {
    final rule = source.rule(groupName);
    final bookUrlRule = rules.optionalRule(rule, 'bookUrl');
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
      bookUrlRule.replaceRange(templateMatch.start, templateMatch.end, marker),
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
          state.putIfAbsent(
            mapping.group(1)!,
            () => Uri.decodeComponent(captured),
          );
        }
      }
    }
  }
  return state;
}

void seedBookMetadata(
  Map<String, Object?> state, {
  required ReadingSourceConfig source,
  required String bookId,
  required String name,
}) {
  state['bookUrl'] = bookId;
  state['name'] ??= name;
  state['type'] ??= bookType(source);
  state['durChapterIndex'] ??= 0;
  state['durChapterTitle'] ??= '';
}

String? nullable(String value) => value.trim().isEmpty ? null : value.trim();

List<String> splitCategories(String value) => value
    .split(RegExp(r'[,/|\s]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

SourceRuntimeRemoteAsset? parseRemoteAsset(
  String value,
  Uri baseUri, [
  Map<String, String> fallbackHeaders = const {},
]) {
  var urlText = value.trim();
  final headers = <String, String>{...fallbackHeaders};
  final optionsStart = urlText.lastIndexOf(RegExp(r',\s*\{'));
  if (optionsStart >= 0) {
    final optionsText = urlText.substring(optionsStart + 1).trim();
    urlText = urlText.substring(0, optionsStart).trim();
    final optionHeaders = _decodeRemoteAssetOptions(optionsText)?['headers'];
    if (optionHeaders is Map) {
      for (final entry in optionHeaders.entries) {
        if ('${entry.key}'.trim().isNotEmpty && entry.value is String) {
          headers['${entry.key}'.trim()] = entry.value as String;
        }
      }
    }
  }
  if (urlText.startsWith('//')) urlText = '${baseUri.scheme}:$urlText';
  final uri = baseUri.resolve(urlText);
  if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return SourceRuntimeRemoteAsset(url: uri, headers: Map.unmodifiable(headers));
}

Map<String, dynamic>? _decodeRemoteAssetOptions(String value) {
  try {
    final decoded = jsonDecode(value);
    return decoded is Map
        ? decoded.map((key, value) => MapEntry('$key', value))
        : null;
  } on FormatException {
    try {
      final normalized = value
          .replaceAllMapped(
            RegExp(r'''([,{]\s*)([A-Za-z_$][\w$-]*)(\s*:)'''),
            (match) => '${match.group(1)}"${match.group(2)}"${match.group(3)}',
          )
          .replaceAllMapped(
            RegExp(r'''(['"])(.*?)\1'''),
            (match) => jsonEncode(match.group(2) ?? ''),
          );
      final decoded = jsonDecode(normalized);
      return decoded is Map
          ? decoded.map((key, value) => MapEntry('$key', value))
          : null;
    } on FormatException {
      return null;
    }
  }
}

class SourceRuntimeRemoteAsset {
  const SourceRuntimeRemoteAsset({required this.url, required this.headers});
  final Uri url;
  final Map<String, String> headers;
}
