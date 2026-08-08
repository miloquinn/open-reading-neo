import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_debug.dart';
import 'package:xxread/book_sources/source_engine/source_debug_session.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';

void main() {
  group('SourceDebugSession', () {
    test(
      'runs the full search chain and emits ordered stage and network events',
      () async {
        final transport = _FakeTransport({
          'https://books.test/search?q=%E5%89%91%E6%9D%A5&page=1': '''
          <div class="book">
            <a href="/book/1"><span class="name">剑来</span></a>
            <span class="author">烽火</span>
          </div>
        ''',
          'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <a class="toc" href="/book/1/toc">目录</a>
        ''',
          'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
          'https://books.test/chapter/1':
              '<article id="content"><p>正文</p></article>',
        });
        final session = SourceDebugSession(_htmlSource(), runtime: SourceRuntime(transport: transport));
        addTearDown(session.dispose);
        final events = <SourceDebugEvent>[];
        session.events.listen(events.add);

        await session.run('剑来');
        await Future<void>.delayed(Duration.zero);

        expect(events.where((e) => e.isError), isEmpty);
        final stages = events
            .where(
              (e) =>
                  e.kind == SourceDebugEventKind.stageStart ||
                  e.kind == SourceDebugEventKind.stageSuccess,
            )
            .map((e) => (e.kind, e.stage))
            .toList();
        expect(stages, [
          (SourceDebugEventKind.stageStart, 'search'),
          (SourceDebugEventKind.stageSuccess, 'search'),
          (SourceDebugEventKind.stageStart, 'info'),
          (SourceDebugEventKind.stageSuccess, 'info'),
          (SourceDebugEventKind.stageStart, 'toc'),
          (SourceDebugEventKind.stageSuccess, 'toc'),
          (SourceDebugEventKind.stageStart, 'content'),
          (SourceDebugEventKind.stageSuccess, 'content'),
        ]);
        final networkStages = events
            .where((e) => e.kind == SourceDebugEventKind.network)
            .map((e) => e.stage)
            .toList();
        expect(networkStages, ['search', 'info', 'toc', 'content']);
        expect(
          events
              .firstWhere(
                (e) =>
                    e.kind == SourceDebugEventKind.stageSuccess &&
                    e.stage == 'toc',
              )
              .message,
          '1 chapter(s)',
        );
      },
    );

    test('starting from a book URL skips the search stage', () async {
      final transport = _FakeTransport({
        'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <a class="toc" href="/book/1/toc">目录</a>
        ''',
        'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
        'https://books.test/chapter/1':
            '<article id="content"><p>正文</p></article>',
      });
      final session = SourceDebugSession(_htmlSource(), runtime: SourceRuntime(transport: transport));
      addTearDown(session.dispose);
      final events = <SourceDebugEvent>[];
      session.events.listen(events.add);

      await session.run('https://books.test/book/1');
      await Future<void>.delayed(Duration.zero);

      expect(events.where((e) => e.stage == 'search'), isEmpty);
      expect(
        events.where((e) => e.kind == SourceDebugEventKind.stageSuccess).map(
          (e) => e.stage,
        ),
        ['info', 'toc', 'content'],
      );
    });

    test('a failing stage stops the chain and is reported as an error', () async {
      final transport = _FakeTransport({
        'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <a class="toc" href="/book/1/toc">目录</a>
        ''',
        // No response registered for the toc page: the fake transport throws,
        // which should surface as a failed 'toc' stage and stop the chain.
      });
      final session = SourceDebugSession(_htmlSource(), runtime: SourceRuntime(transport: transport));
      addTearDown(session.dispose);
      final events = <SourceDebugEvent>[];
      session.events.listen(events.add);

      await session.run('https://books.test/book/1');
      await Future<void>.delayed(Duration.zero);

      final tocFailure = events.firstWhere(
        (e) =>
            e.kind == SourceDebugEventKind.stageError && e.stage == 'toc',
      );
      expect(tocFailure.isError, isTrue);
      expect(events.where((e) => e.stage == 'content'), isEmpty);
    });

    test('run() is a no-op while a session is already running', () async {
      final transport = _FakeTransport({
        'https://books.test/book/1': '''
          <h1>剑来</h1><p class="author">烽火</p>
          <a class="toc" href="/book/1/toc">目录</a>
        ''',
        'https://books.test/book/1/toc': '''
          <ul id="chapters"><li><a href="/chapter/1">第一章</a></li></ul>
        ''',
        'https://books.test/chapter/1':
            '<article id="content"><p>正文</p></article>',
      });
      final session = SourceDebugSession(_htmlSource(), runtime: SourceRuntime(transport: transport));
      addTearDown(session.dispose);

      final first = session.run('https://books.test/book/1');
      expect(session.isRunning, isTrue);
      await session.run('https://books.test/book/1');
      await first;
      expect(session.isRunning, isFalse);
    });
  });
}

RegisteredBookSource _htmlSource() {
  final config = ReadingSourceConfig.fromJson({
    'bookSourceName': 'HTML test',
    'bookSourceUrl': 'https://books.test',
    'searchUrl': '/search?q={{key}}&page={{page}}',
    'ruleSearch': {
      'bookList': 'class.book',
      'name': 'class.name@text',
      'author': 'class.author@text',
      'bookUrl': 'tag.a@href',
    },
    'ruleBookInfo': {
      'name': 'h1@text',
      'author': 'class.author@text',
      'tocUrl': 'class.toc@href',
    },
    'ruleToc': {
      'chapterList': '#chapters@li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
    'ruleContent': {'content': '#content@html'},
  });
  return config.toRegisteredSource(enabled: true);
}

class _FakeTransport implements SourceTransport {
  _FakeTransport(this.responses);

  final Map<String, String> responses;

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    final body = responses[request.url.toString()];
    if (body == null) {
      throw StateError('Missing fake response for ${request.url}');
    }
    return SourceResponse(body: body, finalUri: request.url);
  }
}
