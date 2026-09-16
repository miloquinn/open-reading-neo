part of 'reader_aloud_service.dart';

enum ReaderAloudCloudProvider { openai, doubao, minimax, mimo }

/// Official provider catalog checked on 2026-09-16. Custom IDs remain supported.
class ReaderAloudProviderPreset {
  const ReaderAloudProviderPreset(
    this.name,
    this.provider,
    this.url,
    this.models,
    this.voices, {
    this.format = 'mp3',
  });
  final String format;
  final String name;
  final ReaderAloudCloudProvider provider;
  final String url;
  final Map<String, String> models;
  final Map<String, String> voices;
  ReaderAloudCloudSettings get settings => ReaderAloudCloudSettings(
    responseFormat: format,
    provider: provider,
    baseUrl: url,
    model: models.keys.first,
    voice: voices.keys.first,
  );
}

const readerAloudProviderPresets = [
  ReaderAloudProviderPreset(
    '豆包',
    ReaderAloudCloudProvider.doubao,
    'https://openspeech.bytedance.com/api/v3/tts/unidirectional',
    {'seed-tts-2.0': '豆包语音合成 2.0'},
    {
      'zh_female_vv_uranus_bigtts': 'Vivi 2.0',
      'zh_female_xiaohe_uranus_bigtts': '小何 2.0',
      'zh_male_m191_uranus_bigtts': '云舟 2.0',
      'zh_male_taocheng_uranus_bigtts': '小天 2.0',
      'zh_male_liufei_uranus_bigtts': '刘飞 2.0',
      'zh_female_sophie_uranus_bigtts': '魅力苏菲 2.0',
      'zh_female_cancan_uranus_bigtts': '知性灿灿 2.0',
      'zh_female_xiaoxue_uranus_bigtts': '儿童绘本 2.0',
      'zh_male_ruyayichen_uranus_bigtts': '儒雅逸辰 2.0',
    },
  ),
  ReaderAloudProviderPreset(
    'MiniMax',
    ReaderAloudCloudProvider.minimax,
    'https://api.minimax.cn/v1/t2a_v2',
    {'speech-2.8-hd': 'Speech 2.8 HD', 'speech-2.8-turbo': 'Speech 2.8 Turbo'},
    {
      'Chinese (Mandarin)_Gentleman': '温润男声',
      'Chinese (Mandarin)_Warm_Bestie': '温暖闺蜜',
      'Chinese (Mandarin)_Gentle_Youth': '温润青年',
      'Chinese (Mandarin)_Warm_Girl': '温暖少女',
      'Chinese (Mandarin)_Gentle_Senior': '温柔学姐',
      'male-qn-qingse': '青涩青年',
      'female-chengshu': '成熟女性',
      'Cantonese_GentleLady': '粤语 · 温柔女声',
    },
  ),
  ReaderAloudProviderPreset(
    'OpenAI',
    ReaderAloudCloudProvider.openai,
    'https://api.openai.com/v1',
    {'gpt-4o-mini-tts': 'GPT-4o mini TTS'},
    {
      'marin': 'Marin',
      'cedar': 'Cedar',
      'alloy': 'Alloy',
      'ash': 'Ash',
      'ballad': 'Ballad',
      'coral': 'Coral',
      'echo': 'Echo',
      'fable': 'Fable',
      'nova': 'Nova',
      'onyx': 'Onyx',
      'sage': 'Sage',
      'shimmer': 'Shimmer',
      'verse': 'Verse',
    },
  ),
  ReaderAloudProviderPreset(
    '小米 MiMo',
    ReaderAloudCloudProvider.mimo,
    'https://api.xiaomimimo.com/v1/chat/completions',
    {'mimo-v2.5-tts': 'MiMo-V2.5-TTS'},
    {
      '冰糖': '冰糖 · 中文女声',
      '茉莉': '茉莉 · 中文女声',
      '苏打': '苏打 · 中文男声',
      '白桦': '白桦 · 中文男声',
      'Mia': 'Mia · English',
      'Chloe': 'Chloe · English',
      'Milo': 'Milo · English',
      'Dean': 'Dean · English',
      'mimo_default': 'MiMo 默认',
    },
    format: 'wav',
  ),
];

List<String> readerAloudCloudFormats(ReaderAloudCloudProvider provider) =>
    switch (provider) {
      ReaderAloudCloudProvider.mimo => const ['wav'],
      ReaderAloudCloudProvider.doubao => const ['mp3', 'wav', 'opus'],
      ReaderAloudCloudProvider.minimax => const ['mp3', 'wav', 'flac'],
      ReaderAloudCloudProvider.openai => const [
        'mp3',
        'wav',
        'flac',
        'opus',
        'aac',
        'pcm',
      ],
    };

Future<Uint8List> synthesizeNativeCloud(
  Dio dio,
  ReaderAloudCloudSettings settings,
  String apiKey,
  String text,
  double speed,
  int maxBytes,
  int maxCharacters,
) async {
  validateReaderAloudCloudSettings(settings);
  if (apiKey.trim().isEmpty) {
    throw const ReaderAloudCloudException(
      'missing_api_key',
      '请先配置 TTS API Key',
    );
  }
  if (text.trim().isEmpty) return Uint8List(0);
  if (text.length > maxCharacters) {
    throw const ReaderAloudCloudException('input_too_long', 'TTS 文本超过单次请求限制');
  }
  final doubao = settings.provider == ReaderAloudCloudProvider.doubao;
  final mimo = settings.provider == ReaderAloudCloudProvider.mimo;
  if (!readerAloudCloudFormats(
    settings.provider,
  ).contains(settings.responseFormat)) {
    throw const ReaderAloudCloudException(
      'unsupported_format',
      '此服务不支持所选音频格式，请在高级设置中重新选择',
    );
  }
  try {
    final response = await dio.post<ResponseBody>(
      settings.baseUrl.trim(),
      data: mimo
          ? {
              'model': settings.model,
              'stream': false,
              'messages': [
                // MiMo documents natural-language style/rate guidance, not a numeric
                // speed parameter. Keep the instruction separate from spoken text.
                {
                  'role': 'user',
                  'content':
                      '请自然、连贯地朗读，以正常语速的 ${speed.clamp(0.5, 2.0).toStringAsFixed(2)} 倍为目标，保留必要的标点停顿，不要添加额外长停顿。',
                },
                {'role': 'assistant', 'content': text},
              ],
              'audio': {
                'format': settings.responseFormat,
                'voice': settings.voice,
              },
            }
          : doubao
          ? {
              'user': {'uid': 'open-reading'},
              'req_params': {
                'text': text,
                'speaker': settings.voice,
                'audio_params': {
                  'format': settings.responseFormat == 'opus'
                      ? 'ogg_opus'
                      : settings.responseFormat,
                  'sample_rate': settings.responseFormat == 'opus'
                      ? 48000
                      : 24000,
                  'speech_rate': ((speed.clamp(0.5, 2.0) - 1) * 100).round(),
                },
              },
            }
          : {
              'model': settings.model,
              'text': text,
              'stream': false,
              'output_format': 'hex',
              'voice_setting': {
                'voice_id': settings.voice,
                'speed': speed.clamp(0.5, 2.0),
                'vol': 1,
                'pitch': 0,
              },
              'audio_setting': {
                'sample_rate': 32000,
                'bitrate': 128000,
                'format': settings.responseFormat,
                'channel': 1,
              },
            },
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
        headers: {
          Headers.contentTypeHeader: Headers.jsonContentType,
          if (mimo)
            'api-key': apiKey.trim()
          else if (doubao)
            'X-Api-Key': apiKey.trim()
          else
            'Authorization': 'Bearer ${apiKey.trim()}',
          if (doubao) 'X-Api-Resource-Id': settings.model,
        },
      ),
    );
    final bytes = BytesBuilder(copy: false);
    final body = response.data;
    if (body == null) throw const FormatException();
    await for (final chunk in body.stream) {
      if (bytes.length + chunk.length > maxBytes * 2 + 65536) {
        throw const ReaderAloudCloudException(
          'response_too_large',
          'TTS 音频响应过大',
        );
      }
      bytes.add(chunk);
    }
    final raw = utf8.decode(bytes.takeBytes());
    final audio = BytesBuilder(copy: false);
    if (mimo) {
      final packet = jsonDecode(raw) as Map<String, dynamic>;
      if (packet['error'] != null) {
        throw const ReaderAloudCloudException(
          'provider_error',
          'MiMo 合成失败，请检查密钥、余额与模型权限',
        );
      }
      final choice = (packet['choices'] as List).single as Map<String, dynamic>;
      if (choice['finish_reason'] != 'stop') {
        throw const ReaderAloudCloudException(
          'incomplete_response',
          'MiMo 音频未生成完整，请重试',
        );
      }
      final data = choice['message']['audio']['data'] as String;
      final decoded = base64Decode(data);
      if (decoded.length > maxBytes) {
        throw const ReaderAloudCloudException(
          'response_too_large',
          'TTS 音频响应过大',
        );
      }
      audio.add(decoded);
    } else if (doubao) {
      var completed = false;
      for (var line in const LineSplitter().convert(raw)) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('event:') || line.startsWith(':')) {
          continue;
        }
        if (line.startsWith('data:')) line = line.substring(5).trim();
        final packet = jsonDecode(line) as Map<String, dynamic>;
        if (packet['code'] == 20000000) {
          completed = true;
          continue;
        }
        if (packet['code'] != 0) {
          throw const ReaderAloudCloudException(
            'provider_error',
            '豆包合成失败，请检查密钥、服务开通状态与音色权限',
          );
        }
        final data = packet['data'];
        if (data is String && data.isNotEmpty) audio.add(base64Decode(data));
        if (audio.length > maxBytes) {
          throw const ReaderAloudCloudException(
            'response_too_large',
            'TTS 音频响应过大',
          );
        }
      }
      if (!completed) {
        throw const ReaderAloudCloudException(
          'incomplete_response',
          '豆包音频未接收完整，请重试',
        );
      }
    } else {
      final packet = jsonDecode(raw) as Map<String, dynamic>;
      if (packet['base_resp']?['status_code'] != 0) {
        throw const ReaderAloudCloudException(
          'provider_error',
          'MiniMax 合成失败，请检查密钥、余额与音色权限',
        );
      }
      final hex = packet['data']?['audio'] as String;
      if (hex.length.isOdd || hex.length ~/ 2 > maxBytes) {
        throw const FormatException();
      }
      audio.add(
        Uint8List.fromList([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]),
      );
    }
    if (audio.length == 0) throw const FormatException();
    return audio.takeBytes();
  } on ReaderAloudCloudException {
    rethrow;
  } on DioException catch (e) {
    throw ReaderAloudCloudException(
      'request_failed',
      '语音服务请求失败，请检查网络与 API Key',
      statusCode: e.response?.statusCode,
    );
  } catch (_) {
    throw const ReaderAloudCloudException(
      'invalid_audio_response',
      '语音服务返回了无效音频，请检查配置后重试',
    );
  }
}
