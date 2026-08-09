import 'dart:io';

class SourceResponse {
  const SourceResponse({
    required this.body,
    required this.finalUri,
    this.statusCode = HttpStatus.ok,
    this.headers = const {},
    this.cookies = const {},
  });

  final String body;
  final Uri finalUri;
  final int statusCode;
  final Map<String, String> headers;
  final Map<String, String> cookies;
}
