import '../models/registered_book_source.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_runtime_catalog.dart';
import 'source_runtime_login.dart';
import 'source_runtime_requests.dart';
import 'source_runtime_rules.dart';
import 'source_runtime_state.dart';

class SourceRuntimeReading {
  SourceRuntimeReading({
    required SourceRuntimeRequestPort requests,
    required SourceRuntimeRulePort rules,
    required SourceRuntimeState state,
    required SourceRuntimeSessionPort sessions,
  }) : this._(requests, rules, state, sessions);

  SourceRuntimeReading._(
    this._requests,
    this._rules,
    this._state,
    this._sessions,
  );

  static const int _maxChapters = 30000;
  static const int _maxPageHops = 20;

  final SourceRuntimeRequestPort _requests;
  final SourceRuntimeRulePort _rules;
  final SourceRuntimeState _state;
  final SourceRuntimeSessionPort _sessions;

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = sourceFromRegistered(registered);
    final ruleState = runtimeRuleStateFor(
      _state,
      _rules,
      source,
      bookId,
      sourceVariables,
    );
    final bookContext = _state.bookContext(
      source,
      bookId,
      ruleState,
      bookType: bookType(source),
    );
    final tocUrl = await _tocUrl(source, bookId, ruleState, bookContext);
    final rule = source.rule('ruleToc');
    // Keyed by chapter URL; re-inserting a duplicate moves it to the end of
    // iteration order, so the *last* occurrence of a URL wins and takes its
    // natural position. Some sources render a small "latest chapters" widget
    // above the full catalog on the same TOC page — both match the same
    // `chapterList` rule, so without this the widget's entries (e.g. the
    // final chapters, newest-first) would win and land at the front.
    final chapterTitles = <String, String>{};
    final seenPages = <String>{};
    var nextUrl = tocUrl;
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _requests.requestReusingBookInfo(
        source,
        bookId,
        decodeSourceDataTarget(nextUrl) ?? nextUrl,
        variables: requestVariables(ruleState, {'bookUrl': bookId}),
      );
      final document = _requests.document(
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
      final contexts = await _rules.list(
        contextualDocument,
        null,
        _rules.requiredRule(rule, 'chapterList'),
      );
      for (final context in contexts) {
        chapterContext
          ..clear()
          ..addAll({'index': chapterTitles.length, 'url': nextUrl});
        final title = await _rules.value(
          contextualDocument,
          context,
          rule,
          'chapterName',
        );
        chapterContext['title'] = title;
        final url = await _rules.url(
          contextualDocument,
          context,
          rule,
          'chapterUrl',
        );
        if (title.isEmpty || url.isEmpty) continue;
        if (!chapterTitles.containsKey(url) &&
            chapterTitles.length >= _maxChapters) {
          throw const BookSourceProtocolException(
            'Compatible source chapter catalog exceeds the supported limit.',
          );
        }
        chapterTitles
          ..remove(url)
          ..[url] = title;
      }
      nextUrl = await _rules.url(contextualDocument, null, rule, 'nextTocUrl');
    }
    if (chapterTitles.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return any chapters.',
      );
    }
    final chapters = <BookSourceChapter>[];
    var order = 0;
    for (final entry in chapterTitles.entries) {
      chapters.add(
        BookSourceChapter(id: entry.key, title: entry.value, order: order),
      );
      _state.rememberChapterContext(source, bookId, entry.key, {
        'index': order,
        'title': entry.value,
        'url': entry.key,
        'chapterUrl': entry.key,
      });
      order++;
    }
    _state.rememberBookContext(source, bookId, bookContext);
    _state.rememberRuleState(source, bookId, ruleState);
    await _sessions.flush(source);
    return chapters;
  }

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    final source = sourceFromRegistered(registered);
    final rule = source.rule('ruleContent');
    final ruleState = runtimeRuleStateFor(
      _state,
      _rules,
      source,
      bookId,
      sourceVariables,
    );
    final bookContext = _state.bookContext(
      source,
      bookId,
      ruleState,
      bookType: bookType(source),
    );
    final parts = <String>[];
    final seenPages = <String>{};
    var nextUrl = chapterId;
    var previousUrl = '';
    for (var hop = 0; hop < _maxPageHops && nextUrl.isNotEmpty; hop++) {
      if (!seenPages.add(nextUrl)) break;
      final response = await _requests.request(
        source,
        decodeSourceDataTarget(nextUrl) ?? nextUrl,
        variables: requestVariables(ruleState, {
          'bookUrl': bookId,
          'chapterUrl': chapterId,
        }),
      );
      if (response.statusCode >= 400) {
        throw BookSourceProtocolException(
          'Chapter request failed with HTTP ${response.statusCode}.',
        );
      }
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': chapterId},
        book: bookContext,
        ruleState: ruleState,
      );
      final rememberedChapter = _state.chapterContext(
        source,
        bookId,
        chapterId,
      );
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
      var content = await _rules.value(
        contextualDocument,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      content = _rules.replace(
        content,
        _rules.optionalRule(rule, 'replaceRegex'),
      );
      if (content.trim().isNotEmpty) parts.add(content.trim());
      nextUrl = await _rules.url(
        contextualDocument,
        null,
        rule,
        'nextContentUrl',
      );
      if (nextUrl == previousUrl) nextUrl = '';
      previousUrl = nextUrl;
    }
    final joinedContent = parts.join('\n\n');
    final imageHeaders = await _requests.sourceHeaders(source);
    final images = _chapterImages(source, joinedContent, imageHeaders);
    if ((parts.isEmpty || parts.every(_looksLikePlaceholderContent)) &&
        images.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    _state.rememberRuleState(source, bookId, ruleState);
    await _sessions.flush(source);
    final rememberedChapter = _state.chapterContext(source, bookId, chapterId);
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title:
          sourceVariables['chapterTitle'] ??
          '${rememberedChapter['title'] ?? ''}',
      content: joinedContent,
      contentType: 'text/html',
      images: images,
    );
  }

  Future<String> _tocUrl(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> ruleState,
    Map<String, Object?> bookContext,
  ) async {
    final rule = source.rule('ruleBookInfo');
    final tocRule = _rules.optionalRule(rule, 'tocUrl');
    if (tocRule.isEmpty) return bookId;
    final response = await _requests.requestReusingBookInfo(
      source,
      bookId,
      decodeSourceDataTarget(bookId) ?? bookId,
      variables: requestVariables(ruleState, {'bookUrl': bookId}),
    );
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
    final init = _rules.optionalRule(rule, 'init');
    final context = init.isEmpty
        ? null
        : (await _rules.list(contextualDocument, null, init)).firstOrNull;
    return _rules.evaluateUrl(contextualDocument, context, tocRule);
  }

  List<BookSourceRemoteImage> _chapterImages(
    ReadingSourceConfig source,
    String content,
    Map<String, String> sourceHeaders,
  ) {
    final images = <BookSourceRemoteImage>[];
    final seen = <String>{};
    void addAsset(SourceRuntimeRemoteAsset asset) {
      final key = asset.url.toString();
      final headers = <String, String>{...asset.headers};
      final cookie = _requests.cookieHeader(source, asset.url);
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
      if (!seen.add(key)) {
        if (headers.isEmpty) return;
        final index = images.indexWhere((image) => image.url == asset.url);
        if (index < 0) return;
        images[index] = BookSourceRemoteImage(
          url: asset.url,
          headers: Map.unmodifiable({...images[index].headers, ...headers}),
        );
        return;
      }
      images.add(
        BookSourceRemoteImage(
          url: asset.url,
          headers: Map.unmodifiable(headers),
        ),
      );
    }

    final fragment = html_parser.parseFragment(content);
    const attributeNames = [
      'src',
      'data-src',
      'data-original',
      'data-original-src',
      'data-lazy',
      'data-lazy-src',
      'data-url',
      'data-image',
      'data-srcset',
      'srcset',
    ];
    void visit(Iterable<dom.Node> nodes) {
      for (final node in nodes) {
        if (node is dom.Element) {
          for (final name in attributeNames) {
            final raw = node.attributes[name];
            if (raw == null || raw.trim().isEmpty) continue;
            final value = _firstSrcSetValue(raw);
            final asset = parseRemoteAsset(
              value,
              source.baseUri,
              sourceHeaders,
            );
            if (asset == null) continue;
            addAsset(asset);
            break;
          }
          visit(node.nodes);
        }
      }
    }

    visit(fragment.nodes);
    // Legado asset options use a non-HTML suffix such as
    // `url,{headers:{Referer:'...'}}`; nested quotes make some HTML parsers
    // truncate the attribute. Recover that narrow legacy shape from the raw
    // payload after the standards-compliant DOM pass.
    final legacyPattern = RegExp(
      r'''(?:src|data-src|data-original|data-original-src|data-lazy|data-lazy-src|data-url|data-image)\s*=\s*(["'])(.*?)\1''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in legacyPattern.allMatches(content)) {
      final raw = match.group(2)!;
      if (!raw.contains(RegExp(r',\s*\{'))) continue;
      final asset = parseRemoteAsset(raw, source.baseUri, sourceHeaders);
      if (asset == null) continue;
      addAsset(asset);
    }
    final legacyOptionsPattern = RegExp(
      r'''(?:src|data-src|data-original|data-original-src|data-lazy|data-lazy-src|data-url|data-image)\s*=\s*["'](.*?,\s*\{headers:.*?\}\})["']''',
      caseSensitive: false,
      dotAll: true,
    );
    for (final match in legacyOptionsPattern.allMatches(content)) {
      final asset = parseRemoteAsset(
        match.group(1)!,
        source.baseUri,
        sourceHeaders,
      );
      if (asset == null) continue;
      addAsset(asset);
    }
    return images;
  }

  String _firstSrcSetValue(String raw) {
    final first = raw.split(',').first.trim();
    final whitespace = first.indexOf(RegExp(r'\s'));
    return whitespace < 0 ? first : first.substring(0, whitespace);
  }
}

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
  return plain.startsWith('{') &&
      RegExp(
        r'"(?:error|message|code)"\s*:',
        caseSensitive: false,
      ).hasMatch(plain);
}
