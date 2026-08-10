import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_network_policy.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

void main() {
  group('SourceHttpTransport', () {
    HttpServer? server;

    tearDown(() async {
      await server?.close(force: true);
    });

    test('exposes the isolated cookie jar to source scripts', () {
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      final uri = Uri.parse('https://cookies.test/path');

      transport.setScriptCookies('source-1', uri, 'sid=abc; theme=dark');
      expect(
        transport.scriptCookieHeader('source-1', uri),
        'sid=abc; theme=dark',
      );
      expect(transport.scriptCookieHeader('source-2', uri), isEmpty);

      transport.removeScriptCookies('source-1', uri);
      expect(transport.scriptCookieHeader('source-1', uri), isEmpty);
    });

    test(
      'retries safe HTTP 400 responses through the system network',
      () async {
        final pinned = Dio()..httpClientAdapter = _SequenceAdapter([400]);
        final system = Dio()
          ..httpClientAdapter = _SequenceAdapter([200], body: 'books');
        final transport = SourceHttpTransport(
          dio: pinned,
          systemDio: system,
          networkPolicy: BookSourceNetworkPolicy(
            lookup: (_) async => [InternetAddress('93.184.216.34')],
          ),
        );
        addTearDown(transport.close);

        final response = await transport.send(
          SourceRequestTemplate.parse(
            'https://books.test/channel',
            baseUri: Uri.parse('https://books.test'),
          ),
        );

        expect(response.body, 'books');
        expect((pinned.httpClientAdapter as _SequenceAdapter).requests, 1);
        expect((system.httpClientAdapter as _SequenceAdapter).requests, 1);
      },
    );

    test('does not replay POST after HTTP 400', () async {
      final pinned = Dio()..httpClientAdapter = _SequenceAdapter([400]);
      final system = Dio()
        ..httpClientAdapter = _SequenceAdapter([200], body: 'unexpected');
      final transport = SourceHttpTransport(
        dio: pinned,
        systemDio: system,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      addTearDown(transport.close);

      await expectLater(
        transport.send(
          SourceRequestTemplate.parse(
            'https://books.test/submit,{"method":"POST","body":"q=1"}',
            baseUri: Uri.parse('https://books.test'),
          ),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
      expect((pinned.httpClientAdapter as _SequenceAdapter).requests, 1);
      expect((system.httpClientAdapter as _SequenceAdapter).requests, 0);
    });

    test(
      'a redirect loop error names each hop that led to it',
      () async {
        final adapter = _SelfRedirectAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final transport = SourceHttpTransport(
          dio: dio,
          networkPolicy: BookSourceNetworkPolicy(
            lookup: (_) async => [InternetAddress('93.184.216.34')],
          ),
        );
        addTearDown(transport.close);

        await expectLater(
          transport.send(
            SourceRequestTemplate.parse(
              'https://books.test/login,{"method":"POST","body":"a=1"}',
              baseUri: Uri.parse('https://books.test'),
            ),
          ),
          throwsA(
            isA<BookSourceProtocolException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('entered a redirect loop'),
                contains('POST https://books.test/login -> 302'),
                contains('GET https://books.test/login -> 302'),
                contains('anti-bot/challenge'),
              ),
            ),
          ),
        );
      },
    );

    test(
      'a loop between two different URLs is not mislabeled as a challenge',
      () async {
        final adapter = _PingPongRedirectAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final transport = SourceHttpTransport(
          dio: dio,
          networkPolicy: BookSourceNetworkPolicy(
            lookup: (_) async => [InternetAddress('93.184.216.34')],
          ),
        );
        addTearDown(transport.close);

        await expectLater(
          transport.send(
            SourceRequestTemplate.parse(
              'https://books.test/a',
              baseUri: Uri.parse('https://books.test'),
            ),
          ),
          throwsA(
            isA<BookSourceProtocolException>().having(
              (error) => error.message,
              'message',
              allOf(
                contains('entered a redirect loop'),
                isNot(contains('anti-bot/challenge')),
              ),
            ),
          ),
        );
      },
    );

    test('strips authority credentials across redirects', () async {
      final adapter = _RedirectAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final transport = SourceHttpTransport(
        dio: dio,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'https://books.test/start',
          baseUri: Uri.parse('https://books.test'),
          sourceHeaders: const {
            'Authorization': 'Bearer secret',
            'Cookie': 'sid=configured',
            'Host': 'books.test',
          },
        ),
      );

      expect(response.body, 'done');
      expect(adapter.requests, hasLength(2));
      expect(adapter.requests.first.headers['Authorization'], 'Bearer secret');
      expect(
        adapter.requests.last.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        adapter.requests.last.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(
        adapter.requests.last.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('host')),
      );
    });

    test('forwards close force to both injected Dio clients', () {
      final pinnedAdapter = _CloseAdapter();
      final systemAdapter = _CloseAdapter();
      final pinned = Dio()..httpClientAdapter = pinnedAdapter;
      final system = Dio()..httpClientAdapter = systemAdapter;
      final transport = SourceHttpTransport(dio: pinned, systemDio: system);

      transport.close(force: false);

      expect(pinnedAdapter.closedForce, isFalse);
      expect(systemAdapter.closedForce, isFalse);
    });

    test(
      'returns response status headers and cookies to source scripts',
      () async {
        final boundServer = server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        boundServer.listen((request) async {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.set('X-Source-Test', 'ready');
          request.response.cookies.add(Cookie('sid', 'abc')..path = '/');
          request.response.write('body');
          await request.response.close();
        });
        final transport = SourceHttpTransport(
          networkPolicy: const BookSourceNetworkPolicy(
            allowPrivateNetwork: true,
          ),
        );
        addTearDown(transport.close);

        final response = await transport.send(
          SourceRequestTemplate.parse(
            'http://${boundServer.address.address}:${boundServer.port}/metadata',
            baseUri: Uri.parse('https://unused.test'),
            cookieJarKey: 'source-1',
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['x-source-test'], 'ready');
        expect(response.cookies['sid'], 'abc');
      },
    );

    test('sends HEAD and returns metadata without a response body', () async {
      final boundServer = server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final method = Completer<String>();
      boundServer.listen((request) async {
        method.complete(request.method);
        request.response.statusCode = HttpStatus.noContent;
        request.response.headers.set('X-Head', 'ready');
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${boundServer.address.address}:${boundServer.port}/probe,'
          '{"method":"HEAD"}',
          baseUri: Uri.parse('https://unused.test'),
        ),
      );

      expect(await method.future, 'HEAD');
      expect(response.body, isEmpty);
      expect(response.statusCode, HttpStatus.noContent);
      expect(response.headers['x-head'], 'ready');
    });

    test('sends and decodes bounded GBK POST responses', () async {
      final boundServer = server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final received = Completer<List<int>>();
      boundServer.listen((request) async {
        received.complete(
          await request.fold<List<int>>([], (a, b) => a..addAll(b)),
        );
        request.response.headers.contentType = ContentType(
          'text',
          'plain',
          charset: 'gbk',
        );
        request.response.add(gbk_bytes.encode('结果'));
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${boundServer.address.address}:${boundServer.port}/search,'
          '{"method":"POST","body":"关键词=剑来","charset":"gbk"}',
          baseUri: Uri.parse('https://unused.test'),
        ),
      );

      expect(response.body, '结果');
      expect(await received.future, gbk_bytes.encode('关键词=剑来'));
    });

    test('keeps source cookies across same-URL redirects', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server!.listen((request) async {
        requests++;
        final hasSession = request.cookies.any(
          (cookie) => cookie.name == 'session' && cookie.value == 'ready',
        );
        if (!hasSession) {
          request.response.cookies.add(Cookie('session', 'ready')..path = '/');
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/channel');
        } else {
          request.response.write('books');
        }
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${server!.address.address}:${server!.port}/channel',
          baseUri: Uri.parse('https://unused.test'),
          cookieJarKey: 'source-1',
        ),
      );

      expect(response.body, 'books');
      expect(requests, 2);
    });

    test(
      'keeps redirect cookies within a request when persistence is disabled',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final receivedCookies = <String, String?>{};
        server!.listen((request) async {
          final session = request.cookies
              .where((cookie) => cookie.name == 'session')
              .firstOrNull;
          receivedCookies[request.uri.path] = session?.value;
          if (request.uri.path == '/start') {
            request.response.cookies.add(
              Cookie('session', 'redirect-only')..path = '/',
            );
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(
              HttpHeaders.locationHeader,
              '/channel',
            );
          } else {
            request.response.write(
              request.uri.path == '/channel' ? 'books' : 'clean',
            );
          }
          await request.response.close();
        });
        final transport = SourceHttpTransport(
          networkPolicy: const BookSourceNetworkPolicy(
            allowPrivateNetwork: true,
          ),
        );
        addTearDown(transport.close);

        final baseUri = Uri.parse('https://unused.test');
        final response = await transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/start',
            baseUri: baseUri,
          ),
        );
        final nextResponse = await transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/probe',
            baseUri: baseUri,
          ),
        );

        expect(response.body, 'books');
        expect(receivedCookies['/start'], isNull);
        expect(receivedCookies['/channel'], 'redirect-only');
        expect(nextResponse.body, 'clean');
        expect(receivedCookies['/probe'], isNull);
      },
    );

    test('matches browser method semantics for POST redirects', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      server!.listen((request) async {
        methods.add(request.method);
        if (request.uri.path == '/submit') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader, '/result');
        } else {
          request.response.write('ok');
        }
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);

      final response = await transport.send(
        SourceRequestTemplate.parse(
          'http://${server!.address.address}:${server!.port}/submit,'
          '{"method":"POST","body":"q=test"}',
          baseUri: Uri.parse('https://unused.test'),
        ),
      );

      expect(response.body, 'ok');
      expect(methods, ['POST', 'GET']);
    });

    test(
      'decodes malformed GBK responses without initializing codec decoder',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server!.listen((request) async {
          request.response.headers.contentType = ContentType(
            'text',
            'plain',
            charset: 'gbk',
          );
          request.response.add(<int>[0xBD, 0xE1, 0xB9]);
          await request.response.close();
        });
        final transport = SourceHttpTransport(
          networkPolicy: const BookSourceNetworkPolicy(
            allowPrivateNetwork: true,
          ),
        );
        addTearDown(transport.close);

        final response = await transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/',
            baseUri: Uri.parse('https://unused.test'),
          ),
        );

        expect(response.body, startsWith('结'));
        expect(response.body, hasLength(2));
      },
    );

    test('rejects responses over the configured bound', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server!.listen((request) async {
        request.response.add(utf8.encode('12345'));
        await request.response.close();
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
        maxResponseBytes: 4,
      );
      addTearDown(transport.close);

      expect(
        () => transport.send(
          SourceRequestTemplate.parse(
            'http://${server!.address.address}:${server!.port}/',
            baseUri: Uri.parse('https://unused.test'),
          ),
        ),
        throwsA(isA<BookSourceProtocolException>()),
      );
    });

    test('cancels an in-flight HTTP request', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final started = Completer<void>();
      final release = Completer<void>();
      server!.listen((request) async {
        if (!started.isCompleted) started.complete();
        await release.future;
        try {
          request.response.write('late response');
          await request.response.close();
        } catch (_) {
          // The client is expected to close the request before this response.
        }
      });
      final transport = SourceHttpTransport(
        networkPolicy: const BookSourceNetworkPolicy(allowPrivateNetwork: true),
      );
      addTearDown(transport.close);
      final cancellation = BookDownloadCancellation();
      final request = transport.send(
        SourceRequestTemplate.parse(
          'http://${server!.address.address}:${server!.port}/slow',
          baseUri: Uri.parse('https://unused.test'),
        ),
        cancellation: cancellation,
      );
      await started.future;

      cancellation.cancel();
      await expectLater(
        request,
        throwsA(isA<BookDownloadCancelledException>()),
      );
      release.complete();
    });
  });
}

class _SequenceAdapter implements HttpClientAdapter {
  _SequenceAdapter(this.statuses, {this.body = ''});

  final List<int> statuses;
  final String body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = requests++;
    final status = statuses[index.clamp(0, statuses.length - 1)];
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        HttpHeaders.contentTypeHeader: ['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RedirectAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1) {
      return ResponseBody.fromString(
        '',
        HttpStatus.found,
        headers: {
          HttpHeaders.locationHeader: ['https://other.test/final'],
        },
      );
    }
    return ResponseBody.fromString('done', HttpStatus.ok);
  }

  @override
  void close({bool force = false}) {}
}

/// Always redirects back to the exact same URL, the way a bot-challenge edge
/// that never sets a satisfying cookie would.
class _SelfRedirectAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '',
      HttpStatus.found,
      headers: {
        HttpHeaders.locationHeader: ['https://books.test/login'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Alternates redirecting between two different URLs (A -> B -> A -> ...),
/// unlike [_SelfRedirectAdapter]'s single-URL bounce.
class _PingPongRedirectAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final target = options.uri.path.endsWith('/a')
        ? 'https://books.test/b'
        : 'https://books.test/a';
    return ResponseBody.fromString(
      '',
      HttpStatus.found,
      headers: {
        HttpHeaders.locationHeader: [target],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CloseAdapter implements HttpClientAdapter {
  bool? closedForce;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) => throw UnimplementedError();

  @override
  void close({bool force = false}) {
    closedForce = force;
  }
}
