import 'package:flutter/foundation.dart';

const String comicDebugLogPrefix = '[COMIC-TRACE]';

void comicDebugLog(
  String stage,
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!kDebugMode) return;
  final suffix = error == null ? '' : ' error=${_oneLine('$error')}';
  debugPrint('$comicDebugLogPrefix [$stage] ${_oneLine(message)}$suffix');
  if (stackTrace != null) {
    debugPrintStack(
      label: '$comicDebugLogPrefix [$stage] stack',
      stackTrace: stackTrace,
      maxFrames: 12,
    );
  }
}

String comicDebugTarget(String value) {
  final uri = Uri.tryParse(value);
  return uri == null ? '<invalid-target>' : comicDebugUri(uri);
}

String comicDebugUri(Uri uri) {
  final queryKeys = uri.queryParametersAll.keys.toList()..sort();
  return uri
      .replace(
        userInfo: uri.userInfo.isEmpty ? null : '<redacted>',
        query: queryKeys.isEmpty
            ? null
            : queryKeys.map((key) => '$key=<redacted>').join('&'),
        fragment: uri.fragment.isEmpty ? null : '<redacted>',
      )
      .toString();
}

String comicDebugHeaderNames(Map<String, String> headers) {
  if (headers.isEmpty) return 'none';
  final names = headers.keys.map((key) => key.toLowerCase()).toSet().toList()
    ..sort();
  return names.join(',');
}

String _oneLine(String value) =>
    value.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
