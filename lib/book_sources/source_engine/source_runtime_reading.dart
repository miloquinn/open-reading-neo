import 'dart:convert';

import '../models/registered_book_source.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_runtime_catalog.dart';
import 'source_request_template.dart';
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
    final chapterFallbackUrls = <String, String>{};
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
      var contexts = await _rules.list(
        contextualDocument,
        null,
        _rules.requiredRule(rule, 'chapterList'),
      );
      if (contexts.isEmpty && source.isImageSource) {
        contexts = _fallbackChapterAnchors(contextualDocument.value);
      }
      for (final context in contexts) {
        chapterContext
          ..clear()
          ..addAll({'index': chapterTitles.length, 'url': nextUrl});
        var title = await _rules.value(
          contextualDocument,
          context,
          rule,
          'chapterName',
        );
        if (context is dom.Element &&
            context.localName == 'a' &&
            title.isEmpty) {
          title = context.text.trim();
        }
        chapterContext['title'] = title;
        String originalUrl = '';
        if (context is dom.Element) {
          final anchor = context.localName == 'a'
              ? context
              : context.querySelector('a[href]');
          final href = anchor?.attributes['href']?.trim() ?? '';
          if (href.isNotEmpty) {
            originalUrl = resolveSourceRequestUrl(
              contextualDocument.baseUri,
              href,
            );
          }
        }
        var url = await _rules.url(
          contextualDocument,
          context,
          rule,
          'chapterUrl',
        );
        if (url.isEmpty) url = originalUrl;
        if (title.isEmpty || url.isEmpty) continue;
        if (originalUrl.isNotEmpty && originalUrl != url) {
          chapterFallbackUrls[url] = originalUrl;
        }
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
    if (chapterTitles.isEmpty && source.isImageSource) {
      chapterTitles[bookId] = '全本';
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
        'fallbackUrl': ?chapterFallbackUrls[entry.key],
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
    final rawPages = <String>[];
    final seenPages = <String>{};
    final rememberedChapter = _state.chapterContext(source, bookId, chapterId);
    final fallbackUrl = '${rememberedChapter['fallbackUrl'] ?? ''}'.trim();
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
      rawPages.add(response.body);
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': chapterId},
        book: bookContext,
        ruleState: ruleState,
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
    var joinedContent = parts.join('\n\n');
    final imageHeaders = await _requests.sourceHeaders(source);
    var images = _chapterImages(source, joinedContent, imageHeaders);
    if (images.isEmpty &&
        fallbackUrl.isNotEmpty &&
        !seenPages.contains(fallbackUrl)) {
      final response = await _requests.request(
        source,
        decodeSourceDataTarget(fallbackUrl) ?? fallbackUrl,
        variables: requestVariables(ruleState, {
          'bookUrl': bookId,
          'chapterUrl': fallbackUrl,
        }),
      );
      rawPages.add(response.body);
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': fallbackUrl},
        book: bookContext,
        chapter: rememberedChapter,
        ruleState: ruleState,
      );
      var fallbackContent = await _rules.value(
        document,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      fallbackContent = _rules.replace(
        fallbackContent,
        _rules.optionalRule(rule, 'replaceRegex'),
      );
      if (fallbackContent.trim().isNotEmpty) {
        parts.add(fallbackContent.trim());
        joinedContent = parts.join('\n\n');
        images = _chapterImages(source, joinedContent, imageHeaders);
      }
    }
    if (images.isEmpty && source.isImageSource) {
      final recovered = _fallbackComicImageHtml(rawPages.join('\n'));
      if (recovered.isNotEmpty) {
        joinedContent = joinedContent.isEmpty
            ? recovered
            : '$joinedContent\n$recovered';
        images = _chapterImages(source, joinedContent, imageHeaders);
      }
    }
    if ((parts.isEmpty || parts.every(_looksLikePlaceholderContent)) &&
        images.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    _state.rememberRuleState(source, bookId, ruleState);
    await _sessions.flush(source);
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

  List<Object?> _fallbackChapterAnchors(Object? value) {
    final candidates = switch (value) {
      dom.Document document => document.querySelectorAll('a[href]'),
      dom.Element element => element.querySelectorAll('a[href]'),
      _ => const <dom.Element>[],
    };
    final anchors = <dom.Element>[];
    final seen = <String>{};
    for (final anchor in candidates) {
      final href = anchor.attributes['href']?.trim() ?? '';
      final text = anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (href.isEmpty || text.isEmpty) continue;
      final lower = href.toLowerCase();
      final chapterLikeUrl =
          lower.contains('chapter') ||
          lower.contains('chapter_slot=') ||
          lower.contains('section_slot=') ||
          lower.contains('/read/') ||
          lower.contains('/viewer/');
      final chapterLikeText = RegExp(
        r'(?:第\s*\d+\s*(?:话|話|章|回)|\d+\s*(?:话|話|章|回)|番外|全本)',
        caseSensitive: false,
      ).hasMatch(text);
      if (!chapterLikeUrl || !chapterLikeText) continue;
      final key = '$href\u0000$text';
      if (seen.add(key)) anchors.add(anchor);
    }
    return anchors;
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
    try {
      final resolved = await _rules.evaluateUrl(
        contextualDocument,
        context,
        tocRule,
      );
      return resolved.isEmpty ? bookId : resolved;
    } on FormatException {
      // A selector may yield transformed page HTML or an obsolete non-URL
      // value. The common compatible-source behavior is to keep using the
      // detail page as the catalog page in that case.
      return bookId;
    } on BookSourceProtocolException catch (error) {
      if (error.message.contains('non-HTTP URL')) return bookId;
      rethrow;
    }
  }

  String _fallbackComicImageHtml(String body) {
    if (body.trim().isEmpty) return '';
    final fragment = html_parser.parse(body);
    final scoped = <dom.Element>[];
    for (final selector in const [
      '.comic-contain',
      '#imgsec',
      '#images',
      '.reading-content',
      '.chapter-content',
      '.comic-content',
      '.page-content',
    ]) {
      scoped.addAll(fragment.querySelectorAll(selector));
    }
    if (scoped.isEmpty) return '';
    final tags = <String>[];
    final seen = <String>{};
    for (final root in scoped) {
      final elements = <dom.Element>[
        if (root.localName == 'img' ||
            root.localName == 'amp-img' ||
            root.localName == 'source')
          root,
        ...root.querySelectorAll('img,amp-img,source'),
      ];
      for (final element in elements) {
        String value = '';
        for (final name in const [
          'data-src',
          'data-original',
          'data-lazy-src',
          'src',
          'srcset',
        ]) {
          value = element.attributes[name]?.trim() ?? '';
          if (value.isNotEmpty && !value.startsWith('data:')) break;
          value = '';
        }
        if (value.isEmpty || !seen.add(value)) continue;
        tags.add('<img src="${htmlEscape.convert(value)}">');
      }
    }
    return tags.join('\n');
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
