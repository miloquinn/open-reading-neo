import 'dart:convert';

import '../protocol/book_source_protocol.dart';
import 'source_request_expressions.dart';

enum SourceRequestMethod { get, head, post }

const sourceDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/124.0.0.0 Safari/537.36';

class SourceRequestTemplate {
  const SourceRequestTemplate({
    required this.url,
    required this.method,
    required this.headers,
    required this.charset,
    this.useWebView = false,
    this.webJs,
    this.webViewHtml,
    this.body,
    this.cookieJarKey,
  });

  final Uri url;
  final SourceRequestMethod method;
  final Map<String, String> headers;
  final String charset;
  final bool useWebView;
  final String? webJs;
  final String? webViewHtml;
  final String? body;
  final String? cookieJarKey;

  static SourceRequestTemplate parse(
    String template, {
    required Uri baseUri,
    Map<String, String> variables = const {},
    Map<String, String> sourceHeaders = const {},
    String? cookieJarKey,
  }) {
    final expanded = SourceRequestExpressions.expand(
      template.trim(),
      variables,
    );
    if (_unresolvedVariables.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'reading source request contains an unsupported template expression.',
      );
    }
    if (_unsupportedRequestSyntax.hasMatch(expanded)) {
      throw const BookSourceProtocolException(
        'reading source request uses scripting, which is not supported.',
      );
    }
    if (expanded.isEmpty) {
      throw const BookSourceProtocolException(
        'reading source request URL is empty.',
      );
    }

    var urlText = expanded;
    var options = const <String, dynamic>{};
    final optionsStart = _requestOptionsStart(expanded);
    if (optionsStart >= 0) {
      final candidate = expanded.substring(optionsStart + 1).trim();
      try {
        final decoded = _decodeOptions(candidate);
        if (decoded is! Map) throw const FormatException();
        options = decoded.map((key, value) => MapEntry('$key', value));
        urlText = expanded.substring(0, optionsStart).trim();
      } on FormatException {
        throw const BookSourceProtocolException(
          'reading source request options must be a JSON object.',
        );
      }
    }

    final uri = baseUri.resolve(urlText);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'reading source request targets must use HTTP or HTTPS.',
      );
    }

    final methodText = '${options['method'] ?? 'GET'}'.trim().toUpperCase();
    final method = switch (methodText) {
      'GET' => SourceRequestMethod.get,
      'HEAD' => SourceRequestMethod.head,
      'POST' => SourceRequestMethod.post,
      _ => throw BookSourceProtocolException(
        'Unsupported reading source request method: $methodText.',
      ),
    };
    final body = options['body'];
    if (body != null && body is! String) {
      throw const BookSourceProtocolException(
        'reading source request body must be text.',
      );
    }
    if (method != SourceRequestMethod.post &&
        body is String &&
        body.isNotEmpty) {
      throw const BookSourceProtocolException(
        'GET and HEAD reading source requests cannot contain a body.',
      );
    }

    final headers = <String, String>{};
    for (final entry in sourceHeaders.entries) {
      final name = entry.key.trim();
      if (name.isEmpty || _forbiddenHeaders.contains(name.toLowerCase())) {
        throw BookSourceProtocolException(
          'reading source request header is not allowed: $name.',
        );
      }
      headers[name] = entry.value;
    }
    final optionHeaders = options['headers'];
    if (optionHeaders != null) {
      Object? normalizedHeaders = optionHeaders;
      if (normalizedHeaders is String) {
        final headerText = normalizedHeaders.trim();
        if (headerText.startsWith('{')) {
          try {
            normalizedHeaders = _decodeOptions(headerText);
          } on FormatException {
            throw const BookSourceProtocolException(
              'Reading source request headers must be valid JSON.',
            );
          }
        } else {
          normalizedHeaders = {'User-Agent': headerText};
        }
      }
      if (normalizedHeaders is! Map) {
        throw const BookSourceProtocolException(
          'reading source request headers must be an object.',
        );
      }
      for (final entry in normalizedHeaders.entries) {
        final name = '${entry.key}'.trim();
        final value = entry.value;
        if (name.isEmpty || value is! String) {
          throw const BookSourceProtocolException(
            'reading source request headers must contain text values.',
          );
        }
        if (_forbiddenHeaders.contains(name.toLowerCase())) {
          throw BookSourceProtocolException(
            'reading source request header is not allowed: $name.',
          );
        }
        headers[name] = value;
      }
    }
    if (!headers.keys.any((name) => name.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = sourceDefaultUserAgent;
    }
    for (final entry in headers.entries) {
      if (entry.key.contains(RegExp(r'[\r\n]')) ||
          entry.value.contains(RegExp(r'[\r\n]'))) {
        throw const BookSourceProtocolException(
          'reading source request headers cannot contain line breaks.',
        );
      }
      if (entry.key.toLowerCase() == 'host' &&
          !_staticHostHeader.hasMatch(entry.value.trim())) {
        throw const BookSourceProtocolException(
          'reading source Host headers must contain a static host name.',
        );
      }
    }
    final charset = '${options['charset'] ?? 'utf-8'}'.trim().toLowerCase();
    if (!_supportedCharsets.contains(charset)) {
      throw BookSourceProtocolException(
        'Unsupported reading source request charset: $charset.',
      );
    }
    if (method == SourceRequestMethod.post &&
        !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      headers['Content-Type'] =
          'application/x-www-form-urlencoded; charset=$charset';
    }
    return SourceRequestTemplate(
      url: uri,
      method: method,
      headers: Map.unmodifiable(headers),
      charset: charset,
      useWebView:
          options['webView'] == true ||
          '${options['webView']}'.toLowerCase() == 'true',
      webJs: options['webJs'] is String
          ? options['webJs'] as String
          : options['webjs'] is String
          ? options['webjs'] as String
          : null,
      body: body as String?,
      cookieJarKey: cookieJarKey,
    );
  }
}

String resolveSourceRequestUrl(Uri baseUri, String value) {
  final optionsStart = _requestOptionsStart(value);
  final urlText = (optionsStart < 0 ? value : value.substring(0, optionsStart))
      .trim();
  final resolved = baseUri.resolve(urlText).toString();
  if (optionsStart < 0) return resolved;
  return '$resolved${value.substring(optionsStart)}';
}

int _requestOptionsStart(String value) {
  RegExpMatch? last;
  for (final match in RegExp(r',\s*\{').allMatches(value)) {
    last = match;
  }
  return last?.start ?? -1;
}

Object? _decodeOptions(String input) {
  try {
    return jsonDecode(input);
  } on FormatException {
    if (input.contains('`') ||
        input.contains(RegExp(r'\b(function|return|new)\b')) ||
        input.contains('//') ||
        input.contains('/*')) {
      rethrow;
    }
    final buffer = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var escaped = false;
    for (var index = 0; index < input.length; index++) {
      final char = input[index];
      if (escaped) {
        buffer.write(char == '"' && inSingle ? r'\"' : char);
        escaped = false;
        continue;
      }
      if (char == r'\') {
        buffer.write(char);
        escaped = true;
        continue;
      }
      if (char == '"' && !inSingle) {
        inDouble = !inDouble;
        buffer.write(char);
        continue;
      }
      if (char == "'" && !inDouble) {
        inSingle = !inSingle;
        buffer.write('"');
        continue;
      }
      if (inSingle && char == '"') {
        buffer.write(r'\"');
      } else {
        buffer.write(char);
      }
    }
    if (inSingle) throw const FormatException('Unterminated quoted string.');
    return jsonDecode(buffer.toString());
  }
}

const _supportedCharsets = {'utf-8', 'utf8', 'gbk', 'gb2312', 'gb18030'};
final _unresolvedVariables = RegExp(r'\{\{[^{}]+\}\}');
final _unsupportedRequestSyntax = RegExp(
  r'@js:|<js>|@put:|@get:',
  caseSensitive: false,
);
final _staticHostHeader = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?(?::\d{1,5})?$',
);
const _forbiddenHeaders = {'content-length', 'transfer-encoding'};
