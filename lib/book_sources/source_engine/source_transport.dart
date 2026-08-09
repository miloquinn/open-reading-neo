import 'dart:typed_data';

import '../services/book_download_cancellation.dart';
import 'source_request_template.dart';
import 'source_response.dart';

abstract interface class SourceTransport {
  Future<SourceResponse> send(
    SourceRequestTemplate request, {
    BookDownloadCancellation? cancellation,
  });
}

abstract interface class SourceInteractionTransport {
  Future<void> validateInteractionUri(Uri uri);

  Future<Uint8List> fetchInteractionBytes({
    required Uri uri,
    required Map<String, String> headers,
    String? cookieJarKey,
    int maxBytes = 2 * 1024 * 1024,
  });
}

abstract interface class SourceCookieTransport {
  String scriptCookieHeader(String jarKey, Uri uri);

  void setScriptCookies(String jarKey, Uri uri, String cookieHeader);

  void removeScriptCookies(String jarKey, Uri uri);
}

abstract interface class SourceClosableTransport {
  void close({bool force = true});
}
