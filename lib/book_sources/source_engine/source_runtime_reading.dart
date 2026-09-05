import '../models/registered_book_source.dart';
import 'package:html/dom.dart' as dom;
import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_content_images.dart';
import 'source_remote_asset.dart';
import 'source_response.dart';
import 'source_runtime_catalog.dart';
import 'source_request_template.dart';
import 'rules/source_rule_engine.dart' show SourceRuleDocument;
import 'source_runtime_login.dart';
import 'source_runtime_requests.dart';
import 'source_runtime_rules.dart';
import 'source_runtime_state.dart';
import 'source_text_replacement.dart';

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
  static const _imageExtractor = SourceContentImageExtractor();

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
        var url = await _optionalResolvedUrl(
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
      nextUrl = await _optionalResolvedUrl(
        contextualDocument,
        null,
        rule,
        'nextTocUrl',
      );
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
    final chapterEntries = chapterTitles.entries.toList(growable: false);
    for (final entry in chapterEntries) {
      final nextChapterUrl = order + 1 < chapterEntries.length
          ? chapterEntries[order + 1].key
          : '';
      chapters.add(
        BookSourceChapter(id: entry.key, title: entry.value, order: order),
      );
      _state.rememberChapterContext(source, bookId, entry.key, {
        'index': order,
        'title': entry.value,
        'url': entry.key,
        'chapterUrl': entry.key,
        'nextChapterUrl': nextChapterUrl,
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
    final textImagePages = <SourceContentImagePage>[];
    var selectedImages = SourceContentImageAccumulator();
    final recoveredImages = SourceContentImageAccumulator();
    final recoveredContentParts = <String>[];
    final seenPages = <String>{};
    var replaceRemovedImages = false;
    final replaceRule = _rules.optionalRule(rule, 'replaceRegex');
    final rememberedChapter = _state.chapterContext(source, bookId, chapterId);
    var chapterTitle =
        sourceVariables['chapterTitle'] ??
        '${rememberedChapter['title'] ?? ''}';
    final fallbackUrl = '${rememberedChapter['fallbackUrl'] ?? ''}'.trim();
    final nextChapterTarget = _networkTarget(
      '${rememberedChapter['nextChapterUrl'] ?? ''}',
    );
    final pendingUrls = <String>[chapterId];
    final prefetched = <String, Future<_PrefetchedPage>>{};
    var fixedUrlsToSchedule = <String>[];
    var fixedScheduleIndex = 0;
    Future<SourceResponse> requestPage(String pageUrl) => _requests.request(
      source,
      decodeSourceDataTarget(pageUrl) ?? pageUrl,
      variables: requestVariables(ruleState, {
        'bookUrl': bookId,
        'chapterUrl': chapterId,
      }),
    );
    void scheduleFixedPages() {
      while (prefetched.length < 4 &&
          fixedScheduleIndex < fixedUrlsToSchedule.length) {
        final url = fixedUrlsToSchedule[fixedScheduleIndex++];
        prefetched[url] = requestPage(url).then(
          (response) => _PrefetchedPage(response: response),
          onError: (Object error, StackTrace stackTrace) =>
              _PrefetchedPage(error: error, stackTrace: stackTrace),
        );
      }
    }

    SourceRuleDocument? firstDocument;
    var fixedPageList = false;
    for (var hop = 0; hop < _maxPageHops && pendingUrls.isNotEmpty; hop++) {
      final pageUrl = pendingUrls.removeAt(0);
      final requestedUrl = _networkTarget(pageUrl);
      if (!seenPages.add(requestedUrl)) continue;
      final prefetchedResult = await prefetched.remove(pageUrl);
      final response = prefetchedResult == null
          ? await requestPage(pageUrl)
          : prefetchedResult.unwrap();
      scheduleFixedPages();
      _ensureChapterRequestSucceeded(response);
      if (!seenPages.add(response.finalUri.toString()) &&
          response.finalUri.toString() != requestedUrl) {
        continue;
      }
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': chapterId},
        book: bookContext,
        ruleState: ruleState,
      );
      final chapterContext = <String, Object?>{
        ...rememberedChapter,
        'url': pageUrl,
        'chapterUrl': chapterId,
        'index':
            int.tryParse(sourceVariables['chapterIndex'] ?? '') ??
            rememberedChapter['index'] ??
            hop,
        'title': chapterTitle,
      };
      final contextualDocument = document.withScriptEntities(
        book: bookContext,
        chapter: chapterContext,
        bookWriter: (value) => bookContext.addAll(value),
        chapterWriter: (value) => chapterContext.addAll(value),
      );
      firstDocument ??= contextualDocument;
      final rawContent = await _rules.value(
        contextualDocument,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      final content = source.isImageSource
          ? _rules.replace(rawContent, replaceRule)
          : rawContent;
      var pageHasSelectedImages = false;
      if (content.trim().isNotEmpty) {
        final trimmed = content.trim();
        parts.add(trimmed);
        if (!source.isImageSource) {
          textImagePages.add((
            content: rawContent.trim(),
            baseUri: contextualDocument.baseUri,
          ));
        }
        final pageImages = _imageExtractor.extract([
          (content: trimmed, baseUri: contextualDocument.baseUri),
        ], allowPlainValues: source.isImageSource);
        selectedImages.addAll(pageImages);
        pageHasSelectedImages = pageImages.isNotEmpty;
      }
      if (rawContent != content && !pageHasSelectedImages) {
        replaceRemovedImages =
            replaceRemovedImages ||
            _imageExtractor.extract([
              (content: rawContent, baseUri: contextualDocument.baseUri),
            ], allowPlainValues: source.isImageSource).isNotEmpty;
      }
      if (source.isImageSource &&
          selectedImages.isEmpty &&
          !replaceRemovedImages &&
          !pageHasSelectedImages) {
        final recoveredPages = _imageExtractor.recoverComicContainers([
          (content: response.body, baseUri: response.finalUri),
        ]);
        recoveredImages.addAll(_imageExtractor.extract(recoveredPages));
        recoveredContentParts.addAll(
          recoveredPages.map((page) => page.content),
        );
      }
      if (!fixedPageList) {
        final nextUrls = await _optionalResolvedUrls(
          contextualDocument,
          null,
          rule,
          'nextContentUrl',
        );
        if (hop == 0 && nextUrls.length > 1) fixedPageList = true;
        final candidates = fixedPageList ? nextUrls : nextUrls.take(1);
        for (final candidate in candidates) {
          final target = _networkTarget(candidate);
          if (target.isEmpty || target == nextChapterTarget) continue;
          if (!seenPages.contains(target) && !pendingUrls.contains(candidate)) {
            pendingUrls.add(candidate);
          }
        }
        if (fixedPageList) {
          fixedUrlsToSchedule = pendingUrls
              .take(_maxPageHops - 1)
              .toList(growable: false);
          scheduleFixedPages();
        }
      }
    }
    var joinedContent = parts.join('\n\n');
    if (selectedImages.isEmpty &&
        !replaceRemovedImages &&
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
      _ensureChapterRequestSucceeded(response);
      final document = _requests.document(
        source,
        response,
        variables: {'bookUrl': bookId, 'chapterUrl': fallbackUrl},
        book: bookContext,
        chapter: rememberedChapter,
        ruleState: ruleState,
      );
      final rawFallbackContent = await _rules.value(
        document,
        null,
        rule,
        'content',
        required: true,
        joinSeparator: '\n',
        regexDotAll: false,
      );
      final fallbackContent = source.isImageSource
          ? _rules.replace(rawFallbackContent, replaceRule)
          : rawFallbackContent;
      var fallbackHasSelectedImages = false;
      if (fallbackContent.trim().isNotEmpty) {
        final trimmed = fallbackContent.trim();
        parts.add(trimmed);
        if (!source.isImageSource) {
          textImagePages.add((
            content: rawFallbackContent.trim(),
            baseUri: document.baseUri,
          ));
        }
        final fallbackPageImages = _imageExtractor.extract([
          (content: trimmed, baseUri: document.baseUri),
        ], allowPlainValues: source.isImageSource);
        selectedImages.addAll(fallbackPageImages);
        fallbackHasSelectedImages = fallbackPageImages.isNotEmpty;
        joinedContent = parts.join('\n\n');
      }
      if (rawFallbackContent != fallbackContent && !fallbackHasSelectedImages) {
        replaceRemovedImages = _imageExtractor.extract([
          (content: rawFallbackContent, baseUri: document.baseUri),
        ], allowPlainValues: source.isImageSource).isNotEmpty;
      }
      if (source.isImageSource &&
          selectedImages.isEmpty &&
          !replaceRemovedImages &&
          !fallbackHasSelectedImages) {
        final recoveredPages = _imageExtractor.recoverComicContainers([
          (content: response.body, baseUri: response.finalUri),
        ]);
        recoveredImages.addAll(_imageExtractor.extract(recoveredPages));
        recoveredContentParts.addAll(
          recoveredPages.map((page) => page.content),
        );
      }
    }
    if (firstDocument != null) {
      final subContentRule = _rules.optionalRule(rule, 'subContent');
      if (subContentRule.isNotEmpty) {
        final rawSubContent = await _rules.value(
          firstDocument,
          null,
          rule,
          'subContent',
          joinSeparator: '\n',
          regexDotAll: false,
        );
        var subContent = rawSubContent.trim();
        var subContentBaseUri = firstDocument.baseUri;
        if (subContent.toLowerCase().startsWith('http')) {
          final response = await _requests.request(
            source,
            subContent,
            variables: requestVariables(ruleState, {
              'bookUrl': bookId,
              'chapterUrl': chapterId,
            }),
          );
          _ensureChapterRequestSucceeded(response);
          subContent = response.body.trim();
          subContentBaseUri = response.finalUri;
        }
        if (!source.isImageSource && subContent.isNotEmpty) {
          parts.add(subContent);
          textImagePages.add((content: subContent, baseUri: subContentBaseUri));
        }
      }
      final titleRule = _rules.optionalRule(rule, 'title');
      if (titleRule.isNotEmpty) {
        try {
          final resolvedTitle = await _rules.value(
            firstDocument,
            null,
            rule,
            'title',
            regexDotAll: false,
          );
          if (resolvedTitle.trim().isNotEmpty) {
            final titleParts = RegExp(
              r'(.*)((?:data|https?):[\s\S]+)$',
            ).firstMatch(resolvedTitle.trim());
            if (titleParts != null) {
              final visibleTitle = titleParts.group(1)!.trim();
              if (visibleTitle.isNotEmpty) chapterTitle = visibleTitle;
              rememberedChapter['reviewImg'] = titleParts.group(2);
            } else {
              chapterTitle = resolvedTitle.trim();
            }
            rememberedChapter['title'] = chapterTitle;
          }
        } catch (_) {
          // Reading-source compatibility treats ruleContent.title as optional
          // metadata. Its failure must not discard content that has already
          // been read successfully.
        }
      }
    }
    joinedContent = parts.join('\n\n');
    if (!source.isImageSource) {
      final replacement = replaceTextPages(textImagePages, replaceRule);
      joinedContent = replacement.content;
      selectedImages = SourceContentImageAccumulator();
      selectedImages.addAll(_imageExtractor.extract(replacement.pages));
    }
    final imageHeaders = await _requests.sourceHeaders(source);
    final assets =
        selectedImages.isEmpty && source.isImageSource && !replaceRemovedImages
        ? recoveredImages.values
        : selectedImages.values;
    var images = _remoteImages(source, assets, imageHeaders);
    if (selectedImages.isEmpty && images.isNotEmpty) {
      final recoveredContent = recoveredContentParts.join('\n');
      if (recoveredContent.isNotEmpty) {
        joinedContent = joinedContent.isEmpty
            ? recoveredContent
            : '$joinedContent\n$recoveredContent';
      }
    }
    final contentIsEmpty = source.isImageSource
        ? parts.isEmpty || parts.every(_looksLikePlaceholderContent)
        : _looksLikePlaceholderContent(joinedContent);
    if (contentIsEmpty && images.isEmpty) {
      throw const BookSourceProtocolException(
        'Compatible source did not return chapter content.',
      );
    }
    _state.rememberRuleState(source, bookId, ruleState);
    rememberedChapter
      ..['url'] = chapterId
      ..['chapterUrl'] = chapterId
      ..['title'] = chapterTitle;
    _state.rememberChapterContext(source, bookId, chapterId, rememberedChapter);
    await _sessions.flush(source);
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: chapterTitle,
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

  void _ensureChapterRequestSucceeded(SourceResponse response) {
    if (response.statusCode < 400) return;
    throw BookSourceProtocolException(
      'Chapter request failed with HTTP ${response.statusCode}.',
    );
  }

  Future<String> _optionalResolvedUrl(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    try {
      return await _rules.url(document, context, rules, key);
    } on FormatException {
      return '';
    } on BookSourceProtocolException catch (error) {
      if (_isNonNetworkUrlError(error)) return '';
      rethrow;
    }
  }

  Future<List<String>> _optionalResolvedUrls(
    SourceRuleDocument document,
    Object? context,
    Map<String, dynamic> rules,
    String key,
  ) async {
    try {
      return await _rules.urls(document, context, rules, key);
    } on FormatException {
      return const [];
    } on BookSourceProtocolException catch (error) {
      if (_isNonNetworkUrlError(error)) return const [];
      rethrow;
    }
  }

  List<BookSourceRemoteImage> _remoteImages(
    ReadingSourceConfig source,
    Iterable<SourceRuntimeRemoteAsset> assets,
    Map<String, String> sourceHeaders,
  ) {
    return assets
        .map((asset) {
          final headers = <String, String>{...sourceHeaders, ...asset.headers};
          final cookie = _requests.cookieHeader(source, asset.url);
          if (cookie.isNotEmpty) headers['Cookie'] = cookie;
          return BookSourceRemoteImage(
            url: asset.url,
            headers: Map.unmodifiable(headers),
          );
        })
        .toList(growable: false);
  }
}

class _PrefetchedPage {
  const _PrefetchedPage({this.response, this.error, this.stackTrace});

  final SourceResponse? response;
  final Object? error;
  final StackTrace? stackTrace;

  SourceResponse unwrap() {
    if (error != null) Error.throwWithStackTrace(error!, stackTrace!);
    return response!;
  }
}

bool _isNonNetworkUrlError(BookSourceProtocolException error) {
  final message = error.message.toLowerCase();
  return message.contains('non-http url') ||
      message.contains('must use http or https') ||
      message.contains('targets must use http or https');
}

String _networkTarget(String value) {
  final decoded = decodeSourceDataTarget(value.trim()) ?? value.trim();
  return decoded.split(RegExp(r',\s*\{')).first.trim();
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
