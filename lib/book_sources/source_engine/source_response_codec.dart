import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../utils/chinese_charset_encoder.dart';
import '../../utils/fast_gbk_decoder.dart';
import 'source_cookie_utils.dart';

class SourceResponseCodec {
  const SourceResponseCodec._();

  static List<int> encode(String value, String charset) {
    final normalized = charset.toLowerCase().replaceAll(RegExp(r'[-_]'), '');
    if (normalized == 'gbk' ||
        normalized == 'gb2312' ||
        normalized == 'gb18030') {
      return encodeChineseCharset(value, normalized);
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
            _supportedCharsets.contains(normalizedHeader)
        ? normalizedHeader
        : configured.trim().toLowerCase();
    if (charset == 'gb18030') return decodeGb18030(bytes);
    if (charset == 'gbk' || charset == 'gb2312') {
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
        final cookie = parseSourceSetCookie(value);
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
