import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request_template.dart';
import 'package:xxread/book_sources/source_engine/source_response.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_transport.dart';

void main() {
  test(
    '4020 imported rules preserve URLs through discovery and reading',
    () async {
      final source = ReadingSourceConfig.fromJson(
        jsonDecode(
              File(
                'test/fixtures/book_sources/4020_bybk.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      ).toRegisteredSource(enabled: true);
      final transport = _FixtureTransport();
      final runtime = SourceRuntime(
        transport: transport,
        loginSessionStore: _EmptySessionStore(),
      );
      addTearDown(runtime.close);

      final categories = await runtime.getExploreCategories(source);
      final discovery = await runtime.browse(
        source,
        category: categories.single.id,
      );
      expect(discovery.items, hasLength(2));
      expect(discovery.items.map((book) => book.id), [
        'http://www.xwurexs.com/read/123456/',
        'http://www.xwurexs.com/read/123457/',
      ]);
      expect(discovery.items.first.title, '测试图书');
      expect(discovery.items.first.description, '列表里的简介');
      expect(
        discovery.items.first.coverUrl.toString(),
        'http://www.xwurexs.com/headimgs/123/123456/s123456.jpg',
      );

      final book = await runtime.getBook(source, discovery.items.first.id);
      expect(book.title, '测试图书');
      expect(book.author, '测试作者');
      expect(book.description, '详情里的完整简介');

      final chapters = await runtime.getChapters(source, book.id);
      expect(chapters.map((chapter) => chapter.title), ['第1章 起步', '第2章 继续']);
      expect(chapters.map((chapter) => chapter.id), [
        'http://www.4020xs.com/read/123456/1.html',
        'http://www.4020xs.com/read/123456/2.html',
      ]);
      for (final chapter in chapters) {
        final content = await runtime.getChapterContent(
          source,
          bookId: book.id,
          chapterId: chapter.id,
        );
        expect(content.content, contains('这是一段用于回归验证的原创测试正文。'));
        expect(content.content, contains('第二段正文必须保留。'));
        expect(content.content, isNot(contains('请记住本书首发域名')));
      }

      // Verify real outgoing targets, not merely a successful parsed book list.
      // The detail response is reused for the catalog, including its final URL.
      expect(transport.requests.map((request) => request.url.toString()), [
        'http://www.xwurexs.com/new/',
        'http://www.xwurexs.com/read/123456/',
        'http://www.4020xs.com/read/123456/1.html',
        'http://www.4020xs.com/read/123456/2.html',
      ]);
      for (final request in transport.requests) {
        expect(request.headers['User-Agent'], contains('Chrome/116.0.0.0'));
        expect(request.cookieJarKey, source.id);
      }
    },
  );
}

// Rules are imported unchanged; page structure and content below are synthetic.
// This fixture does not access the live site or attest to its availability.
class _FixtureTransport implements SourceTransport {
  final requests = <SourceRequestTemplate>[];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requests.add(request);
    final url = request.url.toString();
    final body = switch (url) {
      'http://www.xwurexs.com/new/' =>
        '''
        <div class="listBox"><ul>
          <li><a href="/down/123456.html">测试图书txt下载</a>
            <span>作者：测试作者</span><div class="u">列表里的简介</div></li>
          <li><a href="/down/123457.html">另一本书txt下载</a>
            <span>作者：另一作者</span><div class="u">另一段简介</div></li>
        </ul></div>
      ''',
      'http://www.xwurexs.com/read/123456/' =>
        '''
        <div class="detail_info"><h1>测试图书</h1><img src="/cover.jpg">
          <div class="small">测试作者</div><div class="small">大小：100</div>
          <div class="small">更新日期：今天</div>
          <div class="small">最新章节：第2章 继续</div>
          <div class="small">简介：详情里的完整简介</div>
        </div>
        <div class="showInfo"><ul><li><a href="2.html">最新章节</a></li></ul></div>
        <div class="showInfo"><ul>
          <li><a href="1.html">第1章 起步</a></li>
          <li><a href="2.html">第2章 继续</a></li>
        </ul></div>
      ''',
      'http://www.4020xs.com/read/123456/1.html' ||
      'http://www.4020xs.com/read/123456/2.html' =>
        '''
        <div id="content">这是一段用于回归验证的原创测试正文。<br>
          第二段正文必须保留。<br>请记住本书首发域名：example.test</div>
      ''',
      _ => throw StateError('Unexpected request: $url'),
    };
    return SourceResponse(
      body: body,
      finalUri: request.url.replace(host: 'www.4020xs.com'),
    );
  }
}

class _EmptySessionStore implements SourceLoginSessionStore {
  @override
  Future<SourceLoginSession> read(String sourceId) async =>
      const SourceLoginSession();

  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {}

  @override
  Future<void> clear(String sourceId) async {}
}
