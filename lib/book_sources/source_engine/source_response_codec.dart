import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gbk_codec/gbk_codec.dart';

import '../../utils/fast_gbk_decoder.dart';
import 'source_cookie_utils.dart';

class SourceResponseCodec {
  const SourceResponseCodec._();

  static List<int> encode(String value, String charset) {
    if (charset == 'gbk' || charset == 'gb2312') {
      return gbk_bytes.encode(value);
    }
    return utf8.encode(value);
  }

  static String decode(List<int> bytes, String configured, Headers headers) {
    final contentType = headers
        .value(HttpHeaders.contentTypeHeader)
        ?.toLowerCase();
    final headerCharset = contentType == null
        ? null
        : RegExp(
            r'''charset\s*=\s*["']?([^;"'\s]+)''',
          ).firstMatch(contentType)?.group(1);
    final normalizedHeader = headerCharset?.toLowerCase();
    final charset =
        normalizedHeader != null &&
            (_supportedCharsets.contains(normalizedHeader) ||
                normalizedHeader == 'gb18030')
        ? normalizedHeader
        : configured;
    if (charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030') {
      final encoded = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      return decodeGbkFast(
        encoded,
        lenient: !isLikelyValidGbkByteStream(encoded),
      );
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Map<String, String> responseHeaders(Headers headers) {
    final result = <String, String>{};
    for (final entry in headers.map.entries) {
      result[entry.key.toLowerCase()] = entry.value.join(', ');
    }
    return Map.unmodifiable(result);
  }

  static Map<String, String> responseCookies(Headers headers) {
    final values = headers[HttpHeaders.setCookieHeader];
    if (values == null) return const {};
    final result = <String, String>{};
    for (final value in values) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        result[cookie.name] = cookie.value;
      } on FormatException {
        // Ignore one malformed response cookie without losing other metadata.
      }
    }
    return Map.unmodifiable(result);
  }

  static Map<String, String> cookieMapFromHeader(String? cookieHeader) =>
      Map.unmodifiable(parseSourceCookieHeader(cookieHeader));
}

const _supportedCharsets = {'utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030'};
