import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_explore.dart';
import 'source_request.dart';
import 'source_rule_engine.dart';
import 'source_script_engine_platform.dart';
import 'source_login_session.dart';
import 'source_login_ui.dart';
import 'source_interaction_coordinator.dart';
import '../services/book_download_cancellation.dart';

class SourceRuntime {
  SourceRuntime({
    SourceTransport? transport,
    SourceScriptEvaluator? scriptEvaluator,
    SourceLoginSessionStore? loginSessionStore,
  }) : _transport = transport ?? SourceHttpTransport() {
    _scriptEvaluator = scriptEvaluator;
    _loginSessionStore = loginSessionStore ?? SecureSourceLoginSessionStore();
  }

  static const int _maxSearchItems = 100;
  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;
  static const int _maxRememberedBookStates = 1024;

  final SourceTransport _transport;
  late final SourceRuleEngine _rules = SourceRuleEngine(
    scriptEvaluatorProvider: () => _scripts,
  );
  SourceScriptEvaluator? _scriptEvaluator;
  late final SourceLoginSessionStore _loginSessionStore;
  final Map<String, Map<String, Object?>> _bookRuleStates = {};
  final Map<String, Map<String, Object?>> _bookEntityContexts = {};
  final Map<String, Map<String, Object?>> _chapterRuleContexts = {};
  final Map<String, SourceLoginSession> _loginSessions = {};
  final Set<String> _dirtyLoginSessions = {};

  SourceScriptEvaluator get _scripts =>
      _scriptEvaluator ??= QuickJsSourceScriptEvaluator();

  void close({bool force = true}) {
    _bookRuleStates.clear();
    _bookEntityContexts.clear();
    _chapterRuleContexts.clear();
    _loginSessions.clear();
    _dirtyLoginSessions.clear();
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
    await _flushLoginSession(source);
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
    await _flushLoginSession(source);
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
    await _flushLoginSession(source);
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
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final bookContext = _bookContext(source, bookId, ruleState);
    final requestTarget = _decodeSourceDataTarget(bookId) ?? bookId;
    final response = await _request(
      source,
      requestTarget,
      variables: _requestVariables(ruleState, {'bookUrl': bookId}),
    );
    final document = _document(
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
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateListAsync(
            contextualDocument,
            null,
            init,
          )).firstOrNull;
    final title = await _value(contextualDocument, context, rule, 'name');
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
    _seedBookMetadata(bookContext, source: source, bookId: bookId, name: title);
    final author = await _value(contextualDocument, context, rule, 'author');
    bookContext['author'] = author;
    final book = BookSourceBook(
      id: bookId,
      title: title,
      author: author,
      description: await _value(contextualDocument, context, rule, 'intro'),
      type: _bookType(source),
      coverUrl: cover?.url,
      coverHeaders: cover?.headers ?? const {},
      categories: _splitCategories(
        await _value(contextualDocument, context, rule, 'kind'),
      ),
      status: _nullable(
        await _value(contextualDocument, context, rule, 'status'),
      ),
      latestChapter: _nullable(
        await _value(contextualDocument, context, rule, 'lastChapter'),
      ),
      sourceVariables: _bookSourceVariables(
        source,
        ruleState,
        name: title,
        author: author,
        type: _bookType(source),
      ),
    );
    _rememberBookContext(source, bookId, bookContext);
    _rememberRuleState(source, bookId, document.ruleState);
    _rememberRuleState(source, book.id, document.ruleState);
    await _flushLoginSession(source);
    return book;
  }

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = _source(registered);
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final bookContext = _bookContext(source, bookId, ruleState);
    final tocUrl = await _tocUrl(source, bookId, ruleState, bookContext);
    final rule = source.rule('ruleToc');
    final chapters = <BookSourceChapter>[];
    final seenPages = <String>{};
    final seenChapters = <String>{};
    var nextUrl = tocUrl;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final requestTarget = _decodeSourceDataTarget(nextUrl) ?? nextUrl;
      final response = await _request(
        source,
        requestTarget,
        variables: _requestVariables(ruleState, {'bookUrl': bookId}),
      );
      final document = _document(
        source,
        response,
        variables: {'bookUrl': bookId},
        book: bookContext,
        ruleState: ruleState,
      );
      final chapterContext = <String, Object?>{};
      final contextualDocument = document.withScriptEntities(
        book: bookContext,
        chapter: chapterContext,
        bookWriter: (value) => bookContext.addAll(value),
        chapterWriter: (value) => chapterContext.addAll(value),
      );
      final contexts = await _rules.evaluateListAsync(
        contextualDocument,
        null,
        _requiredRule(rule, 'chapterList'),
      );
      for (final context in contexts) {
        chapterContext
          ..clear()
          ..addAll({'index': chapters.length, 'url': nextUrl});
        final title = await _value(
          contextualDocument,
          context,
          rule,
          'chapterName',
        );
        chapterContext['title'] = title;
        final url = await _url(contextualDocument, context, rule, 'chapterUrl');
        if (title.isEmpty || url.isEmpty || !seenChapters.add(url)) continue;
        if (chapters.length >= _maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        chapters.add(
          BookSourceChapter(id: url, title: title, order: chapters.length),
        );
        _rememberChapterContext(source, bookId, url, {
          'index': chapters.length - 1,
          'title': title,
          'url': url,
          'chapterUrl': url,
        });
      }
      nextUrl = await _url(contextualDocument, null, rule, 'nextTocUrl');
    }
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    _rememberBookContext(source, bookId, bookContext);
    _rememberRuleState(source, bookId, ruleState);
    await _flushLoginSession(source);
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = _source(registered);
    final rule = source.rule('ruleContent');
    final ruleState = _ruleStateFor(source, bookId, sourceVariables);
    final bookContext = _bookContext(source, bookId, ruleState);
    final parts = <String>[];
    final seenPages = <String>{};
    var nextUrl = chapterId;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final requestTarget = _decodeSourceDataTarget(nextUrl) ?? nextUrl;
      final response = await _request(
        source,
        requestTarget,
        variables: _requestVariables(ruleState, {
          'bookUrl': bookId,
          'chapterUrl': chapterId,
        }),
      );
      if (response.statusCode >= 400) {
        throw BookSourceProtocolException(
          'Chapter request failed with HTTP ${response.statusCode}.',
        );
      }
      final document = _document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': chapterId},
        book: bookContext,
        ruleState: ruleState,
      );
      final rememberedChapter =
          _chapterRuleContexts[_chapterStateKey(source, bookId, chapterId)] ??
          const <String, Object?>{};
      final chapterContext = <String, Object?>{
        ...rememberedChapter,
        'url': nextUrl,
        'chapterUrl': chapterId,
        'index':
            int.tryParse(sourceVariables['chapterIndex'] ?? '') ??
            rememberedChapter['index'] ??
            hop,
        'title':
            sourceVariables['chapterTitle'] ?? rememberedChapter['title'] ?? '',
      };
      final contextualDocument = document.withScriptEntities(
        book: bookContext,
        chapter: chapterContext,
        bookWriter: (value) => bookContext.addAll(value),
        chapterWriter: (value) => chapterContext.addAll(value),
      );
      var content = await _value(
        contextualDocument,
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
      nextUrl = await _url(contextualDocument, null, rule, 'nextContentUrl');
    }
    if (parts.isEmpty || parts.every(_looksLikePlaceholderContent)) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    _rememberRuleState(source, bookId, ruleState);
    await _flushLoginSession(source);
    final joinedContent = parts.join('\n\n');
    final imageHeaders = await _sourceHeaders(source);
    final rememberedChapter =
        _chapterRuleContexts[_chapterStateKey(source, bookId, chapterId)] ??
        const <String, Object?>{};
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title:
          sourceVariables['chapterTitle'] ??
          '${rememberedChapter['title'] ?? ''}',
      content: joinedContent,
      contentType: 'text/html',
      images: _chapterImages(source, joinedContent, imageHeaders),
    );
  }

  Future<String> _tocUrl(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> ruleState,
    Map<String, Object?> bookContext,
  ) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final response = await _request(
      source,
      _decodeSourceDataTarget(bookId) ?? bookId,
      variables: _requestVariables(ruleState, {'bookUrl': bookId}),
    );
    final document = _document(
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
    final init = _optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.evaluateListAsync(
            contextualDocument,
            null,
            init,
          )).firstOrNull;
    return _rules.evaluateStringAsync(
      contextualDocument,
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
    final bookContext = _bookContext(source, '', document.ruleState);
    final contextualDocument = document.withScriptEntities(
      book: bookContext,
      bookWriter: (value) => bookContext.addAll(value),
    );
    final title = await _value(contextualDocument, context, rule, 'name');
    final url = await _url(contextualDocument, context, rule, 'bookUrl');
    if (title.isEmpty || url.isEmpty) return null;
    _seedBookMetadata(bookContext, source: source, bookId: url, name: title);
    final cover = await _remoteAssetValue(
      contextualDocument,
      context,
      rule,
      'coverUrl',
    );
    final author = await _value(contextualDocument, context, rule, 'author');
    bookContext['author'] = author;
    final book = BookSourceBook(
      id: url,
      title: title,
      author: author,
      description: await _value(contextualDocument, context, rule, 'intro'),
      type: _bookType(source),
      coverUrl: cover?.url,
      coverHeaders: cover?.headers ?? const {},
      categories: _splitCategories(
        await _value(contextualDocument, context, rule, 'kind'),
      ),
      latestChapter: _nullable(
        await _value(contextualDocument, context, rule, 'lastChapter'),
      ),
      sourceVariables: _bookSourceVariables(
        source,
        document.ruleState,
        name: title,
        author: author,
        type: _bookType(source),
      ),
    );
    _rememberBookContext(source, book.id, bookContext);
    _rememberRuleState(source, book.id, document.ruleState);
    return book;
  }

  Future<SourceResponse> _request(
    ReadingSourceConfig source,
    String template, {
    Map<String, String> variables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    await _ensureLoginSession(source);
    final expandedTemplate = await _expandScriptTemplate(
      source,
      template,
      variables,
    );
    final response = await _transport.send(
      SourceRequestTemplate.parse(
        expandedTemplate,
        baseUri: source.baseUri,
        variables: variables,
        sourceHeaders: await _sourceHeaders(source),
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      ),
      cancellation: cancellation,
    );
    return _applyLoginCheck(source, response);
  }

  Future<void> _ensureLoginSession(ReadingSourceConfig source) async {
    if (_loginSessions.containsKey(source.stableId)) return;
    try {
      _loginSessions[source.stableId] = await _loginSessionStore.read(
        source.stableId,
      );
    } on Object {
      // Platform secure storage can be unavailable before the host platform
      // initializes. Keep only an in-memory empty session in that case.
      _loginSessions[source.stableId] = const SourceLoginSession();
    }
  }

  SourceLoginSession _loginSession(ReadingSourceConfig source) =>
      _loginSessions[source.stableId] ?? const SourceLoginSession();

  Future<void> saveLoginSession(
    RegisteredBookSource registered, {
    Map<String, String> loginInfo = const {},
    Map<String, String> loginHeaders = const {},
  }) async {
    final source = _source(registered);
    final session = SourceLoginSession(
      loginInfo: Map.unmodifiable(loginInfo),
      loginHeaders: Map.unmodifiable(loginHeaders),
    );
    _loginSessions[source.stableId] = session;
    await _loginSessionStore.write(source.stableId, session);
  }

  Future<void> clearLoginSession(RegisteredBookSource registered) async {
    final source = _source(registered);
    _loginSessions.remove(source.stableId);
    await _loginSessionStore.clear(source.stableId);
    final transport = _transport;
    if (transport is SourceHttpTransport) {
      transport.removeScriptCookies(source.stableId, source.baseUri);
    }
  }

  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource registered,
  ) async {
    final source = _source(registered);
    await _ensureLoginSession(source);
    final raw = source.raw['loginUi'];
    if (raw is! String || raw.trim().isEmpty) return const [];
    final body = _scriptBody(raw);
    if (body == null) return parseSourceLoginFields(raw);
    final loginSource = '${source.raw['loginUrl'] ?? ''}';
    final loginScript = _scriptBody(loginSource) ?? loginSource;
    final value = await _scripts.evaluateAsync(
      '$loginScript\n$body',
      _scriptContext(source, result: _loginSession(source).loginInfo),
    );
    return parseSourceLoginFields(value);
  }

  Future<void> login(
    RegisteredBookSource registered,
    Map<String, String> values,
  ) async {
    final source = _source(registered);
    await _ensureLoginSession(source);
    final fields = await loadLoginFields(registered);
    final loginInfo = <String, String>{
      ..._loginSession(source).loginInfo,
      for (final field in fields)
        if (!field.isButton)
          field.name: values[field.name] ?? field.defaultValue ?? '',
      ...values,
    };
    await saveLoginSession(registered, loginInfo: loginInfo);
    final loginSource = '${source.raw['loginUrl'] ?? ''}';
    final loginScript = _scriptBody(loginSource) ?? loginSource;
    if (loginScript.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'This source does not define a login script.',
      );
    }
    await _scripts.evaluateAsync(
      '$loginScript\nif (typeof login === \'function\') login();',
      _scriptContext(source, result: loginInfo),
    );
    await _flushLoginSession(source);
  }

  void _updateLoginInfo(
    ReadingSourceConfig source,
    Map<String, String> loginInfo,
  ) {
    final previous = _loginSession(source);
    if (_sameStringMap(previous.loginInfo, loginInfo)) return;
    final next = SourceLoginSession(
      loginInfo: Map.unmodifiable(loginInfo),
      loginHeaders: previous.loginHeaders,
    );
    _loginSessions[source.stableId] = next;
    _dirtyLoginSessions.add(source.stableId);
  }

  void _updateLoginHeaders(
    ReadingSourceConfig source,
    Map<String, String> loginHeaders,
  ) {
    final previous = _loginSession(source);
    if (_sameStringMap(previous.loginHeaders, loginHeaders)) return;
    final next = SourceLoginSession(
      loginInfo: previous.loginInfo,
      loginHeaders: Map.unmodifiable(loginHeaders),
    );
    _loginSessions[source.stableId] = next;
    final cookie = loginHeaders.entries
        .where((entry) => entry.key.toLowerCase() == 'cookie')
        .map((entry) => entry.value)
        .firstOrNull;
    if (cookie != null && source.enabledCookieJar) {
      final transport = _transport;
      if (transport is SourceHttpTransport) {
        transport.setScriptCookies(source.stableId, source.baseUri, cookie);
      }
    }
    _dirtyLoginSessions.add(source.stableId);
  }

  Future<void> _flushLoginSession(ReadingSourceConfig source) async {
    if (!_dirtyLoginSessions.remove(source.stableId)) return;
    try {
      await _loginSessionStore.write(source.stableId, _loginSession(source));
    } on Object {
      _dirtyLoginSessions.add(source.stableId);
      rethrow;
    }
  }

  SourceScriptContext _scriptContext(
    ReadingSourceConfig source, {
    Object? result,
    Uri? baseUrl,
    Map<String, String> variables = const {},
    Map<String, Object?> book = const {},
    Map<String, Object?> chapter = const {},
    bool includeSourceHeaders = true,
  }) {
    final loginSession = _loginSession(source);
    return SourceScriptContext(
      source: source,
      result: result,
      baseUrl: baseUrl,
      variables: variables,
      book: book,
      chapter: chapter,
      networkHandler: (request) => _sendScriptNetwork(
        source,
        request,
        includeSourceHeaders: includeSourceHeaders,
      ),
      cookieReader: (uri) => _scriptCookieHeader(source, uri),
      cookieWriter: (uri, cookie) => _setScriptCookies(source, uri, cookie),
      cookieRemover: (uri) => _removeScriptCookies(source, uri),
      loginInfo: loginSession.loginInfo,
      loginHeaders: loginSession.loginHeaders,
      loginInfoWriter: (value) => _updateLoginInfo(source, value),
      loginHeaderWriter: (value) => _updateLoginHeaders(source, value),
      interactionHandler: (request) =>
          _handleScriptInteraction(source, request),
    );
  }

  Future<SourceScriptInteractionResult> _handleScriptInteraction(
    ReadingSourceConfig source,
    SourceScriptInteractionRequest request,
  ) async {
    var target = source.baseUri.resolve(request.url);
    var interaction = request;
    if (request.kind != SourceScriptInteractionKind.verificationCode &&
        request.url.startsWith('data:text/html')) {
      final decoded = _decodeInteractionHtml(request.url);
      if (decoded != null) {
        target = source.baseUri;
        interaction = SourceScriptInteractionRequest(
          signature: request.signature,
          kind: request.kind,
          url: target.toString(),
          title: request.title,
          html: decoded,
          refetchAfterSuccess: request.refetchAfterSuccess,
        );
      }
    }
    final headers = await _interactionHeaders(source, target);
    var prepared = interaction.copyWith(headers: headers);
    final transport = _transport;
    if (transport is SourceHttpTransport) {
      await transport.validateInteractionUri(target);
    }
    if (request.kind == SourceScriptInteractionKind.verificationCode) {
      if (transport is! SourceHttpTransport) {
        return const SourceScriptInteractionResult(
          error:
              'Verification images require the reading source network transport.',
        );
      }
      final bytes = await transport.fetchInteractionBytes(
        uri: target,
        headers: headers,
        cookieJarKey: source.enabledCookieJar ? source.stableId : null,
      );
      prepared = prepared.copyWith(imageBytes: bytes);
    }
    final result = await SourceInteractionCoordinator.instance.request(
      sourceId: source.stableId,
      sourceName: source.name,
      interaction: prepared,
    );
    final finalUri = Uri.tryParse(result.finalUrl);
    if (finalUri != null && transport is SourceHttpTransport) {
      await transport.validateInteractionUri(finalUri);
    }
    if (result.cookieHeader?.trim().isNotEmpty == true &&
        source.enabledCookieJar) {
      if (finalUri != null &&
          source.enabledCookieJar &&
          transport is SourceHttpTransport) {
        transport.setScriptCookies(
          source.stableId,
          finalUri,
          result.cookieHeader!,
        );
      }
      _updateLoginHeaders(source, {
        ..._loginSession(source).loginHeaders,
        'Cookie': result.cookieHeader!,
      });
      await _flushLoginSession(source);
    }
    if (request.refetchAfterSuccess &&
        request.kind == SourceScriptInteractionKind.browserAwait &&
        !result.cancelled &&
        result.error == null) {
      final response = await _sendScriptNetwork(
        source,
        SourceScriptNetworkRequest(
          signature: '',
          method: 'GET',
          url: result.finalUrl.isEmpty ? request.url : result.finalUrl,
        ),
      );
      return SourceScriptInteractionResult(
        body: response.body,
        finalUrl: response.finalUrl,
        cookieHeader: result.cookieHeader,
      );
    }
    return result;
  }

  Future<Map<String, String>> _interactionHeaders(
    ReadingSourceConfig source,
    Uri uri,
  ) async {
    await _ensureLoginSession(source);
    final headers = <String, String>{..._loginSession(source).loginHeaders};
    final raw = source.raw['header'];
    Object? decoded = raw;
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = null;
      }
    }
    if (decoded is Map) {
      for (final entry in decoded.entries) {
        if (entry.value is String) {
          headers['${entry.key}'] = _expandSourceHeaderValue(
            entry.value as String,
            source,
          );
        }
      }
    }
    final cookie = _scriptCookieHeader(source, uri);
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return headers;
  }

  Future<SourceResponse> _applyLoginCheck(
    ReadingSourceConfig source,
    SourceResponse response,
  ) async {
    final script = _scriptBody(source.loginCheckJs) ?? source.loginCheckJs;
    if (script.isEmpty) return response;
    final result = SourceScriptNetworkResult(
      body: response.body,
      finalUrl: response.finalUri.toString(),
      statusCode: response.statusCode,
      headers: response.headers,
      cookies: response.cookies,
    );
    final checked = await _scripts.evaluateAsync(
      script,
      _scriptContext(source, result: result, baseUrl: response.finalUri),
    );
    await _flushLoginSession(source);
    if (checked is! Map) return response;
    final body = '${checked['body'] ?? response.body}';
    final finalUri = Uri.tryParse('${checked['finalUrl'] ?? ''}');
    final statusCode = checked['statusCode'] is num
        ? (checked['statusCode'] as num).toInt()
        : response.statusCode;
    return SourceResponse(
      body: body,
      finalUri: finalUri ?? response.finalUri,
      statusCode: statusCode,
      headers: _responseStringMap(checked['headers'], response.headers),
      cookies: _responseStringMap(checked['cookies'], response.cookies),
    );
  }

  SourceRuleDocument _document(
    ReadingSourceConfig source,
    SourceResponse response, {
    Map<String, String> variables = const {},
    Map<String, Object?> book = const {},
    Map<String, Object?> chapter = const {},
    Map<String, Object?>? ruleState,
  }) {
    final state = ruleState ?? <String, Object?>{};
    return SourceRuleDocument.parse(
      response.body,
      response.finalUri,
      ruleState: state,
      scriptContext: _scriptContext(
        source,
        baseUrl: response.finalUri,
        variables: _requestVariables(state, variables),
        book: book,
        chapter: chapter,
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

  Map<String, String> _bookSourceVariables(
    ReadingSourceConfig source,
    Map<String, Object?> state, {
    required String name,
    required String author,
    required int type,
  }) {
    final variables = <String, String>{..._requestVariables(state, const {})};
    if (_sourceUsesEntityContext(source)) {
      variables.addAll({
        'bookName': name,
        'bookAuthor': author,
        'bookType': '$type',
      });
    }
    return Map.unmodifiable(variables);
  }

  bool _sourceUsesEntityContext(ReadingSourceConfig source) {
    final rules = <Object?>[
      source.rule('ruleSearch'),
      source.rule('ruleExplore'),
      source.rule('ruleBookInfo'),
      source.rule('ruleToc'),
      source.rule('ruleContent'),
    ];
    return rules.any(
      (rule) => '$rule'.contains(RegExp(r'\b(?:book|chapter)\s*\.')),
    );
  }

  Map<String, Object?> _bookContext(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> state,
  ) {
    final context = <String, Object?>{
      ...?_bookEntityContexts[_bookStateKey(source, bookId)],
      ...state,
    };
    context['bookUrl'] = bookId;
    context['name'] ??= state['bookName'];
    context['author'] ??= state['bookAuthor'];
    context['type'] =
        int.tryParse('${state['bookType'] ?? ''}') ??
        context['type'] ??
        _bookType(source);
    context['durChapterIndex'] ??= 0;
    context['durChapterTitle'] ??= '';
    return context;
  }

  int _bookType(ReadingSourceConfig source) => switch (source.type) {
    1 => 32,
    2 => 64,
    3 => 136,
    4 => 4,
    _ => 8,
  };

  void _seedBookMetadata(
    Map<String, Object?> state, {
    required ReadingSourceConfig source,
    required String bookId,
    required String name,
  }) {
    state['bookUrl'] = bookId;
    state['name'] ??= name;
    state['type'] ??= _bookType(source);
    state['durChapterIndex'] ??= 0;
    state['durChapterTitle'] ??= '';
  }

  void _rememberBookContext(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> context,
  ) {
    final key = _bookStateKey(source, bookId);
    _bookEntityContexts.remove(key);
    _bookEntityContexts[key] = Map<String, Object?>.from(context);
    while (_bookEntityContexts.length > _maxRememberedBookStates) {
      _bookEntityContexts.remove(_bookEntityContexts.keys.first);
    }
  }

  String _chapterStateKey(
    ReadingSourceConfig source,
    String bookId,
    String chapterId,
  ) => '${source.stableId}\u0000$bookId\u0000$chapterId';

  void _rememberChapterContext(
    ReadingSourceConfig source,
    String bookId,
    String chapterId,
    Map<String, Object?> context,
  ) {
    _chapterRuleContexts[_chapterStateKey(source, bookId, chapterId)] =
        Map<String, Object?>.from(context);
    while (_chapterRuleContexts.length > _maxChapters) {
      _chapterRuleContexts.remove(_chapterRuleContexts.keys.first);
    }
  }

  Future<Map<String, String>> _sourceHeaders(ReadingSourceConfig source) async {
    await _ensureLoginSession(source);
    final raw = source.raw['header'];
    final loginHeaders = _loginSession(source).loginHeaders;
    if (raw == null || '$raw'.trim().isEmpty) return loginHeaders;
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        final script = _scriptBody(raw) ?? 'JSON.stringify(($raw))';
        decoded = await _scripts.evaluateAsync(
          script,
          _scriptContext(
            source,
            baseUrl: source.baseUri,
            includeSourceHeaders: false,
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
    headers.addAll(loginHeaders);
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
    await _ensureLoginSession(source);
    SourceScriptContext context() =>
        _scriptContext(source, baseUrl: source.baseUri, variables: variables);

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

  String _scriptCookieHeader(ReadingSourceConfig source, Uri uri) {
    if (!source.enabledCookieJar) return '';
    final transport = _transport;
    return transport is SourceHttpTransport
        ? transport.scriptCookieHeader(source.stableId, uri)
        : '';
  }

  void _setScriptCookies(ReadingSourceConfig source, Uri uri, String cookie) {
    if (!source.enabledCookieJar) return;
    final transport = _transport;
    if (transport is SourceHttpTransport) {
      transport.setScriptCookies(source.stableId, uri, cookie);
    }
  }

  void _removeScriptCookies(ReadingSourceConfig source, Uri uri) {
    if (!source.enabledCookieJar) return;
    final transport = _transport;
    if (transport is SourceHttpTransport) {
      transport.removeScriptCookies(source.stableId, uri);
    }
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

  Future<_SourceRemoteAsset?> _remoteAssetValue(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    final value = await _url(document, context, rules, key);
    if (value.isEmpty) return null;
    final source = document.scriptContext?.source;
    final asset = _parseRemoteAsset(
      value,
      document.baseUri,
      source == null ? const {} : await _sourceHeaders(source),
    );
    if (asset == null || source == null) return asset;
    final headers = <String, String>{...asset.headers};
    final cookie = _scriptCookieHeader(source, asset.url);
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    return _SourceRemoteAsset(
      url: asset.url,
      headers: Map.unmodifiable(headers),
    );
  }

  List<BookSourceRemoteImage> _chapterImages(
    ReadingSourceConfig source,
    String content,
    Map<String, String> sourceHeaders,
  ) {
    final images = <BookSourceRemoteImage>[];
    final seen = <String>{};
    final pattern = RegExp(
      r'''(?:src|data-src|data-original)\s*=\s*(["'])(.*?)\1(?=\s*(?:/?>|[A-Za-z_:][\w:.-]*\s*=))''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in pattern.allMatches(content)) {
      final asset = _parseRemoteAsset(
        match.group(2)!,
        source.baseUri,
        sourceHeaders,
      );
      if (asset == null || !seen.add(asset.url.toString())) continue;
      final headers = <String, String>{...asset.headers};
      final cookie = _scriptCookieHeader(source, asset.url);
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
      images.add(
        BookSourceRemoteImage(
          url: asset.url,
          headers: Map.unmodifiable(headers),
        ),
      );
    }
    return images;
  }

  Future<SourceScriptNetworkResult> _sendScriptNetwork(
    ReadingSourceConfig source,
    SourceScriptNetworkRequest request, {
    bool includeSourceHeaders = true,
  }) async {
    final method = request.method.toUpperCase();
    if (method != 'GET' &&
        method != 'HEAD' &&
        method != 'POST' &&
        method != 'WEBVIEW') {
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
        statusCode: response.statusCode,
        headers: response.headers,
        cookies: response.cookies,
      );
    }
    var template = request.url;
    if (method == 'POST') {
      template =
          '$template,${jsonEncode({'method': 'POST', 'body': request.body ?? '', if (headers.isNotEmpty) 'headers': headers})}';
      headers.clear();
    } else if (method == 'HEAD') {
      template =
          '$template,${jsonEncode({'method': 'HEAD', if (headers.isNotEmpty) 'headers': headers})}';
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
      statusCode: response.statusCode,
      headers: response.headers,
      cookies: response.cookies,
    );
  }
}

String? _decodeInteractionHtml(String value) {
  final comma = value.indexOf(',');
  if (comma < 0) return null;
  final metadata = value.substring(0, comma).toLowerCase();
  final payload = value.substring(comma + 1);
  try {
    if (metadata.contains(';base64')) {
      return utf8.decode(base64Decode(payload), allowMalformed: true);
    }
    return Uri.decodeComponent(payload);
  } on Object {
    return null;
  }
}

String? _decodeSourceDataTarget(String value) {
  final optionsStart = value.lastIndexOf(RegExp(r',\s*\{'));
  final dataPart = optionsStart < 0 ? value : value.substring(0, optionsStart);
  if (!dataPart.startsWith('data:')) return null;
  final comma = dataPart.indexOf(',');
  if (comma < 0) return null;
  final metadata = dataPart.substring(0, comma).toLowerCase();
  final payload = dataPart.substring(comma + 1);
  try {
    final decoded = metadata.contains(';base64')
        ? utf8.decode(base64Decode(payload), allowMalformed: true)
        : Uri.decodeComponent(payload);
    final uri = Uri.tryParse(decoded.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return optionsStart < 0
        ? decoded.trim()
        : '$decoded${value.substring(optionsStart)}';
  } on Object {
    return null;
  }
}

_SourceRemoteAsset? _parseRemoteAsset(
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
    final decoded = _decodeRemoteAssetOptions(optionsText);
    final optionHeaders = decoded?['headers'];
    if (optionHeaders is Map) {
      for (final entry in optionHeaders.entries) {
        final name = '${entry.key}'.trim();
        final headerValue = entry.value;
        if (name.isNotEmpty && headerValue is String) {
          headers[name] = headerValue;
        }
      }
    }
  }
  if (urlText.startsWith('//')) urlText = '${baseUri.scheme}:$urlText';
  final uri = baseUri.resolve(urlText);
  if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return _SourceRemoteAsset(url: uri, headers: Map.unmodifiable(headers));
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

class _SourceRemoteAsset {
  const _SourceRemoteAsset({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}

Map<String, String> _responseStringMap(
  Object? value,
  Map<String, String> fallback,
) {
  if (value is! Map) return fallback;
  return {
    for (final entry in value.entries) '${entry.key}': '${entry.value ?? ''}',
  };
}

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
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

bool _looksLikePlaceholderContent(String value) {
  if (RegExp(r'<img\b', caseSensitive: false).hasMatch(value)) return false;
  final plain = value
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (plain.isEmpty) return true;
  if (plain.length <= 180 &&
      RegExp(
        r'(?:请先登录|请登录|登录后阅读|验证码|人机验证|安全验证|访问频繁|请求频繁|加载中|正在加载|请稍候|内容获取失败|章节不存在)',
        caseSensitive: false,
      ).hasMatch(plain)) {
    return true;
  }
  if (plain.startsWith('{') &&
      RegExp(
        r'"(?:error|message|code)"\s*:',
        caseSensitive: false,
      ).hasMatch(plain)) {
    return true;
  }
  return false;
}

List<String> _splitCategories(String value) => value
    .split(RegExp(r'[,/|\s]+'))
    .map((item) => item.trim())
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList(growable: false);

String stableSourceResourceId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 24);
