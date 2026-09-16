import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/reader_aloud_service.dart';

void main() {
  final doubao = readerAloudProviderPresets.first.settings;
  final minimax = readerAloudProviderPresets[1].settings;
  OpenAiCompatibleReaderAloudCloudClient client(
    String body, {
    void Function(RequestOptions)? inspect,
    int limit = 1024,
  }) {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            inspect?.call(options);
            // Split every byte to exercise transport boundaries across UTF-8/JSON.
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: ResponseBody(
                  Stream.fromIterable(
                    utf8.encode(body).map((b) => Uint8List.fromList([b])),
                  ),
                  200,
                ),
              ),
            );
          },
        ),
      );
    return OpenAiCompatibleReaderAloudCloudClient(
      dio: dio,
      maxResponseBytes: limit,
    );
  }

  final mimo = readerAloudProviderPresets
      .firstWhere((p) => p.provider == ReaderAloudCloudProvider.mimo)
      .settings;
  test(
    'MiMo V2.5 uses chat audio protocol and separate speech instructions',
    () async {
      final c = client(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'audio': {'data': 'AQID'},
              },
            },
          ],
        }),
        inspect: (r) {
          expect(
            r.uri.toString(),
            'https://api.xiaomimimo.com/v1/chat/completions',
          );
          expect(r.headers['api-key'], 'key');
          expect(r.headers.containsKey('Authorization'), isFalse);
          expect(r.followRedirects, isFalse);
          expect(r.data['model'], 'mimo-v2.5-tts');
          expect(r.data['audio'], {'format': 'wav', 'voice': '冰糖'});
          expect(r.data['messages'][0]['role'], 'user');
          expect(r.data['messages'][0]['content'], contains('2.00'));
          expect(r.data['messages'][1], {
            'role': 'assistant',
            'content': '朗读正文',
          });
          expect(r.data.containsKey('speed'), isFalse);
          expect(r.data['stream'], isFalse);
        },
      );
      expect(
        await c.synthesize(
          settings: mimo,
          apiKey: 'key',
          text: '朗读正文',
          speed: 2,
        ),
        [1, 2, 3],
      );
      final restored = ReaderAloudCloudProfile.fromJson(
        ReaderAloudCloudProfile(
          id: 'mimo',
          name: 'MiMo',
          settings: mimo,
        ).toJson(),
      );
      expect(restored.settings.provider, ReaderAloudCloudProvider.mimo);
      expect(restored.settings.responseFormat, 'wav');
    },
  );
  test(
    'MiMo rejects errors, missing audio, truncation and oversized audio',
    () async {
      for (final packet in [
        {
          'error': {'message': 'private service details'},
        },
        {'choices': []},
        {
          'choices': [
            {
              'finish_reason': 'length',
              'message': {
                'audio': {'data': 'AQI='},
              },
            },
          ],
        },
        {
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'audio': {'data': '!!!'},
              },
            },
          ],
        },
        {
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'audio': {'data': ''},
              },
            },
          ],
        },
        {
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'audio': {'data': 'AQID'},
              },
            },
          ],
        },
      ]) {
        await expectLater(
          client(
            jsonEncode(packet),
            limit: 2,
          ).synthesize(settings: mimo, apiKey: 'key', text: 'text', speed: 1),
          throwsA(isA<ReaderAloudCloudException>()),
        );
      }
    },
  );

  test(
    'Doubao uses API Key, 2.0 resource and maps 2x to speech_rate 100',
    () async {
      final c = client(
        '{"code":0,"data":"AQID"}\n{"code":20000000,"data":null}\n',
        inspect: (r) {
          expect(r.uri.toString(), doubao.baseUrl);
          expect(r.headers['X-Api-Key'], 'key');
          expect(r.headers['Authorization'], isNull);
          expect(r.headers['X-Api-Resource-Id'], 'seed-tts-2.0');
          expect(r.followRedirects, isFalse);
          expect(r.data['req_params']['audio_params']['speech_rate'], 100);
          expect(r.data['req_params']['speaker'], doubao.voice);
        },
      );
      expect(
        await c.synthesize(
          settings: doubao,
          apiKey: 'key',
          text: '听书',
          speed: 2,
        ),
        [1, 2, 3],
      );
    },
  );
  test(
    'Doubao supports SSE frames and rejects incomplete or failed synthesis',
    () async {
      final c = client(
        'event: 352\ndata: {"code":0,"data":"AQI="}\n\nevent: 152\ndata: {"code":20000000}\n',
      );
      expect(
        await c.synthesize(
          settings: doubao,
          apiKey: 'key',
          text: 'text',
          speed: 1,
        ),
        [1, 2],
      );
      for (final raw in [
        '{"code":0,"data":"AQI="}\n',
        '{"code":45000000,"message":"secret"}\n',
        '{"code":0,"data":"!!!"}\n{"code":20000000}\n',
      ]) {
        await expectLater(
          client(
            raw,
          ).synthesize(settings: doubao, apiKey: 'key', text: 'text', speed: 1),
          throwsA(isA<ReaderAloudCloudException>()),
        );
      }
    },
  );
  test('MiniMax 2.8 uses native body and decodes hex audio', () async {
    final c = client(
      '{"base_resp":{"status_code":0},"data":{"audio":"0102ff"}}',
      inspect: (r) {
        expect(r.headers['Authorization'], 'Bearer key');
        expect(r.data['model'], 'speech-2.8-hd');
        expect(r.data['voice_setting']['speed'], 2);
        expect(r.data['output_format'], 'hex');
        expect(r.data['stream'], isFalse);
      },
    );
    expect(
      await c.synthesize(
        settings: minimax,
        apiKey: 'key',
        text: 'text',
        speed: 2,
      ),
      [1, 2, 255],
    );
  });
  test(
    'native providers reject malformed, empty, oversized and provider error responses',
    () async {
      for (final raw in [
        '{}',
        '{"base_resp":{"status_code":1004}}',
        '{"base_resp":{"status_code":0},"data":{"audio":""}}',
        '{"base_resp":{"status_code":0},"data":{"audio":"123"}}',
        '{"base_resp":{"status_code":0},"data":{"audio":"010203"}}',
      ]) {
        await expectLater(
          client(raw, limit: 2).synthesize(
            settings: minimax,
            apiKey: 'key',
            text: 'text',
            speed: 1,
          ),
          throwsA(isA<ReaderAloudCloudException>()),
        );
      }
    },
  );
  test(
    'catalog profiles round trip protocol and old profiles default to OpenAI',
    () {
      final p = ReaderAloudCloudProfile(
        id: 'test',
        name: '豆包',
        settings: doubao,
      );
      expect(
        ReaderAloudCloudProfile.fromJson(p.toJson()).settings.provider,
        ReaderAloudCloudProvider.doubao,
      );
      final old = p.toJson()..remove('provider');
      expect(
        ReaderAloudCloudProfile.fromJson(old).settings.provider,
        ReaderAloudCloudProvider.openai,
      );
      final cache = ReaderAloudCloudAudioCache();
      expect(
        cache.keyFor(settings: doubao, text: 'text', speed: 1),
        isNot(
          cache.keyFor(
            settings: doubao.copyWith(
              provider: ReaderAloudCloudProvider.openai,
            ),
            text: 'text',
            speed: 1,
          ),
        ),
      );
    },
  );
}
