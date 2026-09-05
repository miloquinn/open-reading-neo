import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final chapterCount in [24, 101, 654]) {
    test(
      'loads all $chapterCount chapters through the original XPath rules',
      () async {
        final transport = _CatalogTransport(chapterCount);
        final runtime = SourceRuntime(transport: transport);
        addTearDown(runtime.close);
        final source = ReadingSourceConfig.fromJson({
          'bookSourceName': 'XPath catalog regression',
          'bookSourceUrl': 'https://books.test',
          'ruleBookInfo': <String, String>{},
          'ruleToc': {
            'chapterList':
                '//div[@class="card mt20"][2]//ul[@class="dirlist clearfix"]/li',
            'chapterName': '//a/text()',
            'chapterUrl': '//a/@href',
            'nextTocUrl': '',
          },
          'ruleContent': {'content': '//div[@class="content"]/text()'},
        }).toRegisteredSource(enabled: true);

        final chapters = await runtime.getChapters(
          source,
          'https://books.test/book/',
        );

        expect(chapters, hasLength(chapterCount));
        expect(
          chapters.map((chapter) => chapter.order),
          List.generate(chapterCount, (i) => i),
        );
        expect(
          chapters.map((chapter) => chapter.title),
          List.generate(chapterCount, (i) => 'Chapter ${i + 1}'),
        );
        expect(
          chapters.map((chapter) => chapter.id),
          List.generate(
            chapterCount,
            (i) => 'https://books.test/book/read_${i + 1}.html',
          ),
        );
        final content = await runtime.getChapterContent(
          source,
          bookId: 'https://books.test/book/',
          chapterId: chapters.first.id,
        );
        expect(content.content, 'First chapter body');
        expect(transport.requestedPaths, ['/book/', '/book/read_1.html']);
      },
    );
  }
}

class _CatalogTransport implements SourceTransport {
  _CatalogTransport(this.chapterCount);

  final int chapterCount;
  final List<String> requestedPaths = [];

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    requestedPaths.add(request.url.path);
    final body = switch (request.url.path) {
      '/book/' =>
        '''<main>
        <div class="book-info">Book details</div>
        <div class="card mt20"><h2>Latest chapters</h2>
          <ul class="dirlist clearfix">${_entries(List.generate(15, (i) => chapterCount - i))}</ul>
        </div>
        <div class="card mt20"><h2>Full catalog</h2>
          <ul class="dirlist clearfix">${_entries(List.generate(chapterCount, (i) => i + 1))}</ul>
        </div>
      </main>''',
      '/book/read_1.html' => '<div class="content">First chapter body</div>',
      _ => throw StateError('Unexpected request: ${request.url}'),
    };
    return SourceResponse(body: body, finalUri: request.url);
  }

  String _entries(List<int> chapters) => chapters
      .map(
        (chapter) =>
            '<li><a href="/book/read_$chapter.html">Chapter $chapter</a></li>',
      )
      .join();
}
