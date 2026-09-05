import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_session.dart';
import 'package:xxread/book_sources/source_engine/source_request_template.dart';
import 'package:xxread/book_sources/source_engine/source_response.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';
import 'package:xxread/book_sources/source_engine/source_transport.dart';

void main() {
  for (final mutation
      in <String, Future<void> Function(SourceRuntime, RegisteredBookSource)>{
        'saving a login session': (runtime, source) => runtime.saveLoginSession(
          source,
          loginHeaders: const {'Authorization': 'Bearer current'},
        ),
        'logging in': (runtime, source) =>
            runtime.login(source, const {'account': 'current'}),
        'clearing a login session': (runtime, source) =>
            runtime.clearLoginSession(source),
      }.entries) {
    test('${mutation.key} invalidates the source detail response', () async {
      final transport = _QueuedTransport({
        'https://books.test/book/1': [_detail('old'), _detail('current')],
      });
      final source = _source().toRegisteredSource(enabled: true);
      final runtime = SourceRuntime(
        transport: transport,
        loginSessionStore: _MemoryLoginSessionStore(),
      );
      addTearDown(runtime.close);

      await runtime.getBook(source, 'https://books.test/book/1');
      await mutation.value(runtime, source);
      final chapters = await runtime.getChapters(
        source,
        'https://books.test/book/1',
      );

      expect(chapters.single.title, 'current chapter');
      expect(transport.requestCount('https://books.test/book/1'), 2);
    });
  }

  test('login failure invalidates the reusable detail response', () async {
    final transport = _QueuedTransport({
      'https://books.test/book/1': [_detail('old'), _detail('current')],
    });
    final raw = Map<String, dynamic>.from(_source().raw)
      ..['loginUrl'] = 'function login() { throw new Error("rejected"); }';
    final source = ReadingSourceConfig.fromJson(
      raw,
    ).toRegisteredSource(enabled: true);
    final runtime = SourceRuntime(
      transport: transport,
      loginSessionStore: _MemoryLoginSessionStore(),
    );
    addTearDown(runtime.close);

    await runtime.getBook(source, 'https://books.test/book/1');
    await expectLater(
      runtime.login(source, const {'account': 'rejected'}),
      throwsA(
        isA<Exception>().having(
          (error) => '$error',
          'message',
          contains('rejected'),
        ),
      ),
    );
    final chapters = await runtime.getChapters(
      source,
      'https://books.test/book/1',
    );

    expect(chapters.single.title, 'current chapter');
    expect(transport.requestCount('https://books.test/book/1'), 2);
  });

  test('session save failure still invalidates the reusable detail', () async {
    await _expectFailedSessionMutationInvalidates(
      store: _MemoryLoginSessionStore(failWrites: true),
      mutation: (runtime, source) => runtime.saveLoginSession(
        source,
        loginHeaders: const {'Authorization': 'Bearer changed'},
      ),
      expectedError: 'session write rejected',
    );
  });

  test('session clear failure still invalidates the reusable detail', () async {
    await _expectFailedSessionMutationInvalidates(
      store: _MemoryLoginSessionStore(failClears: true),
      mutation: (runtime, source) => runtime.clearLoginSession(source),
      expectedError: 'session clear rejected',
    );
  });

  test('login invalidation leaves another source state intact', () async {
    final transport = _QueuedTransport({
      'https://one.test/book/1': [_detail('old'), _detail('current')],
      'https://two.test/book/1': [_detail('other')],
    });
    final first = _source(
      baseUrl: 'https://one.test',
    ).toRegisteredSource(enabled: true);
    final second = _source(
      baseUrl: 'https://two.test',
    ).toRegisteredSource(enabled: true);
    final runtime = SourceRuntime(
      transport: transport,
      loginSessionStore: _MemoryLoginSessionStore(),
    );
    addTearDown(runtime.close);

    await runtime.getBook(first, 'https://one.test/book/1');
    await runtime.getBook(second, 'https://two.test/book/1');
    await runtime.saveLoginSession(first, loginInfo: const {'user': 'new'});

    final firstChapters = await runtime.getChapters(
      first,
      'https://one.test/book/1',
    );
    final secondChapters = await runtime.getChapters(
      second,
      'https://two.test/book/1',
    );

    expect(firstChapters.single.title, 'current chapter');
    expect(secondChapters.single.title, 'other chapter');
    expect(transport.requestCount('https://one.test/book/1'), 2);
    expect(transport.requestCount('https://two.test/book/1'), 1);
  });
}

Future<void> _expectFailedSessionMutationInvalidates({
  required _MemoryLoginSessionStore store,
  required Future<void> Function(SourceRuntime, RegisteredBookSource) mutation,
  required String expectedError,
}) async {
  final transport = _QueuedTransport({
    'https://books.test/book/1': [_detail('old'), _detail('current')],
  });
  final source = _source().toRegisteredSource(enabled: true);
  final runtime = SourceRuntime(transport: transport, loginSessionStore: store);
  addTearDown(runtime.close);

  await runtime.getBook(source, 'https://books.test/book/1');
  await expectLater(
    mutation(runtime, source),
    throwsA(
      isA<StateError>().having(
        (error) => error.message,
        'message',
        expectedError,
      ),
    ),
  );
  final chapters = await runtime.getChapters(
    source,
    'https://books.test/book/1',
  );

  expect(chapters.single.title, 'current chapter');
  expect(transport.requestCount('https://books.test/book/1'), 2);
}

ReadingSourceConfig _source({String baseUrl = 'https://books.test'}) =>
    ReadingSourceConfig.fromJson({
      'bookSourceName': 'Login invalidation source',
      'bookSourceUrl': baseUrl,
      'loginUrl': 'function login() {}',
      'ruleBookInfo': {'name': 'h1@text'},
      'ruleToc': {
        'chapterList': '#chapters@li',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      },
      'ruleContent': {'content': 'article@html'},
    });

String _detail(String identity) =>
    '''
  <h1>$identity book</h1>
  <ul id="chapters">
    <li><a href="/chapter/$identity">$identity chapter</a></li>
  </ul>
''';

class _QueuedTransport implements SourceTransport {
  _QueuedTransport(this.responses);

  final Map<String, List<String>> responses;
  final List<String> requests = [];

  int requestCount(String url) =>
      requests.where((value) => value == url).length;

  @override
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  }) async {
    final url = request.url.toString();
    requests.add(url);
    final queued = responses[url];
    if (queued == null || queued.isEmpty) {
      throw StateError('Missing fake response for $url');
    }
    return SourceResponse(body: queued.removeAt(0), finalUri: request.url);
  }
}

class _MemoryLoginSessionStore implements SourceLoginSessionStore {
  _MemoryLoginSessionStore({this.failWrites = false, this.failClears = false});

  final bool failWrites;
  final bool failClears;
  final Map<String, SourceLoginSession> values = {};

  @override
  Future<void> clear(String sourceId) async {
    values.remove(sourceId);
    if (failClears) throw StateError('session clear rejected');
  }

  @override
  Future<SourceLoginSession> read(String sourceId) async =>
      values[sourceId] ?? const SourceLoginSession();

  @override
  Future<void> write(String sourceId, SourceLoginSession session) async {
    values[sourceId] = session;
    if (failWrites) throw StateError('session write rejected');
  }
}
