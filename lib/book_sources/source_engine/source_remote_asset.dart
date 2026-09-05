import 'dart:convert';

SourceRuntimeRemoteAsset? parseRemoteAsset(
  String value,
  Uri baseUri, [
  Map<String, String> fallbackHeaders = const {},
]) {
  var urlText = value.trim();
  final headers = <String, String>{...fallbackHeaders};
  final optionsStart = urlText.indexOf(RegExp(r',\s*\{'));
  if (optionsStart >= 0) {
    final optionsText = urlText.substring(optionsStart + 1).trim();
    urlText = urlText.substring(0, optionsStart).trim();
    final optionHeaders = _decodeRemoteAssetOptions(optionsText)?['headers'];
    if (optionHeaders is Map) {
      for (final entry in optionHeaders.entries) {
        if ('${entry.key}'.trim().isNotEmpty && entry.value is String) {
          headers['${entry.key}'.trim()] = entry.value as String;
        }
      }
    }
  }
  if (urlText.startsWith('//')) urlText = '${baseUri.scheme}:$urlText';
  final uri = baseUri.resolve(urlText);
  if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return SourceRuntimeRemoteAsset(url: uri, headers: Map.unmodifiable(headers));
}

Map<String, dynamic>? _decodeRemoteAssetOptions(String value) {
  try {
    final decoded = jsonDecode(value);
    return decoded is Map
        ? decoded.map((key, value) => MapEntry('$key', value))
        : null;
  } on FormatException {
    try {
      final normalized = value
          .replaceAllMapped(
            RegExp(r'''([,{]\s*)([A-Za-z_$][\w$-]*)(\s*:)'''),
            (match) => '${match.group(1)}"${match.group(2)}"${match.group(3)}',
          )
          .replaceAllMapped(
            RegExp(r'''(['"])(.*?)\1'''),
            (match) => jsonEncode(match.group(2) ?? ''),
          );
      final decoded = jsonDecode(normalized);
      return decoded is Map
          ? decoded.map((key, value) => MapEntry('$key', value))
          : null;
    } on FormatException {
      return null;
    }
  }
}

class SourceRuntimeRemoteAsset {
  const SourceRuntimeRemoteAsset({required this.url, required this.headers});
  final Uri url;
  final Map<String, String> headers;
}
