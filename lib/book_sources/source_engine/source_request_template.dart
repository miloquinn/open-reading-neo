import 'dart:convert';

import '../../utils/chinese_charset_encoder.dart';
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
    this.syntheticBody,
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

  /// Set when [url] is a `data:` URI carrying a `type` option, mirroring the
  /// compatible `AnalyzeUrl.getStrResponseAwait` short-circuit: the request is
  /// never sent over the network. The payload is decoded locally and
  /// hex-encoded (matching `HexUtil.encodeHexStr`) so rule scripts that
  /// expect this convention (commonly paired with `java.hexDecodeToString`)
  /// see the protocol-compatible byte representation.
  final String? syntheticBody;

  static SourceRequestTemplate parse(
    String template, {
    required Uri baseUri,
    Map<String, String> variables = const {},
    Map<String, String> sourceHeaders = const {},
    String? cookieJarKey,
    String? defaultWebJs,
  }) {
    final input = template.trim();
    if (input.isEmpty) {
      throw const BookSourceProtocolException(
        'reading source request URL is empty.',
      );
    }

    var urlText = input;
    var options = const <String, dynamic>{};
    final optionsStart = _requestOptionsStart(input);
    if (optionsStart >= 0) {
      final candidate = input.substring(optionsStart + 1).trim();
      try {
        final decoded = _decodeOptions(candidate);
        if (decoded is! Map) throw const FormatException();
        options = decoded.map(
          (key, value) => MapEntry('$key', _expandOption(value, variables)),
        );
        urlText = input.substring(0, optionsStart).trim();
      } on FormatException {
        throw const BookSourceProtocolException(
          'reading source request options must be a JSON object.',
        );
      }
    }

    urlText = SourceRequestExpressions.expand(urlText, variables);
    final expanded = '$urlText,${jsonEncode(options)}';
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
    final charset = '${options['charset'] ?? 'utf-8'}'.trim().toLowerCase();
    if (!_supportedCharsets.contains(charset)) {
      throw BookSourceProtocolException(
        'Unsupported reading source request charset: $charset.',
      );
    }
    final methodText = '${options['method'] ?? 'GET'}'.trim().toUpperCase();
    if (methodText == 'GET') urlText = _encodeQuery(urlText, charset);
    final syntheticBody = _dataUriSyntheticBody(urlText, options);
    if (syntheticBody != null) {
      return SourceRequestTemplate(
        url: Uri(scheme: 'data', path: urlText.substring(5)),
        method: SourceRequestMethod.get,
        headers: const {},
        charset: 'utf-8',
        cookieJarKey: cookieJarKey,
        syntheticBody: syntheticBody,
      );
    }
    final uri = baseUri.resolve(urlText);
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'reading source request targets must use HTTP or HTTPS.',
      );
    }

    final method = switch (methodText) {
      'GET' => SourceRequestMethod.get,
      'HEAD' => SourceRequestMethod.head,
      'POST' => SourceRequestMethod.post,
      _ => throw BookSourceProtocolException(
        'Unsupported reading source request method: $methodText.',
      ),
    };
    // AnalyzeUrl serializes structured bodies and only consumes them for POST.
    final rawBody = options['body'];
    String? body = method != SourceRequestMethod.post || rawBody == null
        ? null
        : rawBody is String
        ? rawBody
        : jsonEncode(rawBody);

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
    if (method == SourceRequestMethod.post &&
        !headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      final contentType = _isJsonBody(body)
          ? 'application/json'
          : 'application/x-www-form-urlencoded';
      if (body != null &&
          !_isJsonBody(body) &&
          !body.trimLeft().startsWith('<')) {
        body = _encodeForm(
          body,
          charset,
          preserveEncoded: options['charset'] == null,
        );
      }
      headers['Content-Type'] = '$contentType; charset=$charset';
    }
    final useWebView =
        options['webView'] == true ||
        '${options['webView']}'.toLowerCase() == 'true';
    return SourceRequestTemplate(
      url: uri,
      method: method,
      headers: Map.unmodifiable(headers),
      charset: charset,
      useWebView: useWebView,
      webJs: options['webJs'] is String
          ? options['webJs'] as String
          : options['webjs'] is String
          ? options['webjs'] as String
          : useWebView
          ? defaultWebJs
          : null,
      body: body,
      cookieJarKey: cookieJarKey,
    );
  }
}

String resolveSourceRequestUrl(Uri baseUri, String value) {
  final optionsStart = _requestOptionsStart(value);
  final urlText = (optionsStart < 0 ? value : value.substring(0, optionsStart))
      .trim();
  final resolved = urlText.startsWith('data:')
      ? urlText
      : baseUri.resolve(urlText).toString();
  if (optionsStart < 0) return resolved;
  return '$resolved${value.substring(optionsStart)}';
}

/// Shared URL contract for selector and script rules. Opaque data labels are
/// local payload identifiers, not MIME types accepted by Uri.parse.
String resolveSourceRuleRequestUrl(
  Uri baseUri,
  String value,
  String errorMessage,
) {
  final urlText = value.split(RegExp(r',\s*\{')).first.trim();
  if (urlText.startsWith('data:')) return value;
  final resolved = resolveSourceRequestUrl(baseUri, value);
  final uri = Uri.tryParse(resolved.split(RegExp(r',\s*\{')).first);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw BookSourceProtocolException(errorMessage);
  }
  return resolved;
}

// Decode options before interpolation: URL escaping is appropriate for query
// and form values, but would corrupt JSON bodies and header values.
Object? _expandOption(Object? value, Map<String, String> variables) {
  if (value is Map) {
    return value.map(
      (key, item) => MapEntry(key, _expandOption(item, variables)),
    );
  }
  if (value is List) {
    return value.map((item) => _expandOption(item, variables)).toList();
  }
  if (value is! String ||
      (!value.contains('{{') && !_requestPageAlternatives.hasMatch(value))) {
    return value;
  }
  if (_isJsonBody(value)) {
    try {
      return jsonEncode(_expandOption(jsonDecode(value), variables));
    } on FormatException {
      // A non-JSON string remains a source-authored string, not a new object.
    }
  }
  final expanded = SourceRequestExpressions.expand(
    value,
    variables,
    expandPages: false,
  );
  // Attributes may contain commas too; preserve literal HTML/XML tags before
  // interpreting the remaining angle-bracket expressions as page choices.
  return expanded.replaceAllMapped(_requestPageAlternatives, (match) {
    final candidate = match.group(0)!;
    return _requestLiteralTag.hasMatch(candidate)
        ? candidate
        : SourceRequestExpressions.expand(candidate, variables);
  });
}

final _requestPageAlternatives = RegExp(r'<[^<>]*,[^<>]*>');
final _requestLiteralTag = RegExp(r'^</?[A-Za-z][\w:.-]*(?:\s+[^<>]*)?/?>$');

String _encodeQuery(String url, String charset) {
  final question = url.indexOf('?');
  if (question < 0) return url;
  final fragment = url.indexOf('#', question);
  final end = fragment < 0 ? url.length : fragment;
  final query = _percentEncode(
    url.substring(question + 1, end),
    charset,
    query: true,
  );
  return '${url.substring(0, question + 1)}$query${url.substring(end)}';
}

String _encodeForm(
  String body,
  String charset, {
  required bool preserveEncoded,
}) {
  String encode(String part) => preserveEncoded && _encodedForm.hasMatch(part)
      ? part
      : _percentEncode(part, charset);
  return body
      .split('&')
      .map((field) {
        final equals = field.indexOf('=');
        return equals < 0
            ? encode(field)
            : '${encode(field.substring(0, equals))}=${encode(field.substring(equals + 1))}';
      })
      .join('&');
}

String _percentEncode(String text, String charset, {bool query = false}) {
  final chinese =
      charset == 'gbk' || charset == 'gb2312' || charset == 'gb18030';
  final buffer = StringBuffer();
  final safe = query ? r"-._~!$&()*+,/:;=?@[\]^`{|}" : '*-._';
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (query &&
        unit == 37 &&
        index + 2 < text.length &&
        _isHex(text.codeUnitAt(index + 1)) &&
        _isHex(text.codeUnitAt(index + 2))) {
      buffer.write(text.substring(index, index + 3));
      index += 2;
    } else if ((unit >= 48 && unit <= 57) ||
        (unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122) ||
        safe.contains(String.fromCharCode(unit))) {
      buffer.writeCharCode(unit);
    } else if (!query && unit == 32) {
      buffer.write('+');
    } else {
      final start = index;
      if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < text.length) {
        final next = text.codeUnitAt(index + 1);
        if (next >= 0xdc00 && next <= 0xdfff) index++;
      }
      final value = text.substring(start, index + 1);
      // Escape all bytes of an unsafe character, including digit/letter bytes
      // inside GB18030/GBK sequences. This matches Java URL encoding.
      final bytes = chinese
          ? encodeChineseCharset(value, charset)
          : utf8.encode(value);
      for (final byte in bytes) {
        buffer.write(
          '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }
    }
  }
  return buffer.toString();
}

bool _isHex(int byte) =>
    (byte >= 48 && byte <= 57) ||
    (byte >= 65 && byte <= 70) ||
    (byte >= 97 && byte <= 102);

final _encodedForm = RegExp(r'^(?:[a-zA-Z0-9*._+\-]|%[0-9a-fA-F]{2})*$');

/// Decodes a `data:` request target into the protocol-compatible hex string
/// that rule scripts expect, or returns null when [value] is not a `data:` URI
/// carrying a non-blank `type` option (the compatibility signal used to treat
/// the whole request as local bytes instead of a network fetch).
String? _dataUriSyntheticBody(String value, Map<String, dynamic> options) {
  if (!value.startsWith('data:')) return null;
  final type = options['type'];
  if (type == null || '$type'.trim().isEmpty) return null;
  final comma = value.indexOf(',');
  if (comma < 0) return null;
  final metadata = value.substring(5, comma).toLowerCase();
  final payload = value.substring(comma + 1);
  try {
    final bytes = metadata.contains(';base64')
        ? base64Decode(
            payload.padRight(
              payload.length + (4 - payload.length % 4) % 4,
              '=',
            ),
          )
        : utf8.encode(Uri.decodeComponent(payload));
    final hex = StringBuffer();
    for (final byte in bytes) {
      hex.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  } on Object {
    return null;
  }
}

// The first delimiter starts the options object. Later `,{` sequences may
// belong to nested body arrays or quoted values and must not split the URL.
int _requestOptionsStart(String value) =>
    _requestOptionsDelimiter.firstMatch(value)?.start ?? -1;

bool _isJsonBody(String? body) {
  if (body == null) return false;
  final value = body.trim();
  // Match AnalyzeUrl's isJson boundary without parsing an already serialized
  // object a second time; malformed payloads remain the source's responsibility.
  return (value.startsWith('{') && value.endsWith('}')) ||
      (value.startsWith('[') && value.endsWith(']'));
}

final _requestOptionsDelimiter = RegExp(r',\s*\{');

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
