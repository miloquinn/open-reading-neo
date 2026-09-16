import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/account/account_api_client.dart';
import 'package:xxread/services/account/account_token_store.dart';

void main() {
  test(
    'reading upload carries expected owner even if credentials switched',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          requests.add(request);
          return ResponseBody.fromString(
            jsonEncode({
              'user_id': 'account-a',
              'accepted': [],
              'rejected': [],
            }),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });
      final api = MemberAccountApiClient(
        dio: dio,
        tokenStore: _Tokens(),
        baseUri: Uri.parse('https://example.test'),
      );
      await api.readingRequest(
        'POST',
        'events',
        'account-a',
        data: {'events': [], 'user_id': 'wrong'},
      );
      expect(requests.single.headers['Authorization'], 'Bearer token-b');
      expect((requests.single.data as Map)['user_id'], 'account-a');
      await api.readingRequest(
        'GET',
        'leaderboard',
        'account-a',
        period: 'month',
      );
      expect(requests.last.uri.queryParameters, {
        'user_id': 'account-a',
        'period': 'month',
      });
      dio.close();
    },
  );

  test(
    'late unauthorized reading request never refreshes global credentials',
    () async {
      final requests = <RequestOptions>[];
      final tokens = _Tokens();
      final dio = Dio()
        ..httpClientAdapter = _Adapter((request) {
          requests.add(request);
          return ResponseBody.fromString(
            '{"detail":"expired"}',
            401,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });
      final api = MemberAccountApiClient(
        dio: dio,
        tokenStore: tokens,
        baseUri: Uri.parse('https://example.test'),
      );
      await expectLater(
        api.readingRequest('GET', 'summary', 'account-a'),
        throwsA(
          isA<MemberAccountException>().having(
            (e) => e.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(requests, hasLength(1));
      expect(tokens.written, isFalse);
      expect(tokens.cleared, isFalse);
      dio.close();
    },
  );
}

class _Tokens implements MemberTokenStore {
  bool written = false, cleared = false;
  @override
  Future<String?> readAccessToken() async => 'token-b';
  @override
  Future<String?> readRefreshToken() async => 'refresh-b';
  @override
  Future<bool> readMfaPending() async => false;
  @override
  Future<void> clear() async {
    cleared = true;
  }

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    bool mfaPending = false,
  }) async {
    written = true;
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final ResponseBody Function(RequestOptions) respond;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async => respond(options);
  @override
  void close({bool force = false}) {}
}
