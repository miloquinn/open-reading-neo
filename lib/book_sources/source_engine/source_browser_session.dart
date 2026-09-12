import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';

/// Website state is scoped first by source, then by cookie domain / origin.
/// Local storage is never guessed to be an Authorization header.
class SourceBrowserSession {
  const SourceBrowserSession({
    this.cookies = const [],
    this.localStorage = const {},
    this.active = false,
  });

  final List<Map<String, Object?>> cookies;
  final Map<String, Map<String, String>> localStorage;
  final bool active;

  factory SourceBrowserSession.fromJson(Object? json) {
    if (json is! Map) return const SourceBrowserSession();
    final origins = <String, Map<String, String>>{};
    if (json['localStorage'] case final Map storage) {
      for (final entry in storage.entries) {
        final uri = Uri.tryParse('${entry.key}');
        if (!isSourceBrowserUri(uri) || entry.value is! Map) continue;
        origins[uri!.origin] = Map.unmodifiable({
          for (final item in (entry.value as Map).entries)
            '${item.key}': '${item.value ?? ''}',
        });
      }
    }
    return SourceBrowserSession(
      active: json['active'] == true,
      cookies: List.unmodifiable([
        if (json['cookies'] case final List cookies)
          for (final cookie in cookies)
            if (cookie is Map &&
                cookie['name'] is String &&
                cookie['value'] is String &&
                cookie['domain'] is String &&
                (cookie['domain'] as String).isNotEmpty)
              Map<String, Object?>.unmodifiable({
                for (final item in cookie.entries) '${item.key}': item.value,
              }),
      ]),
      localStorage: Map.unmodifiable(origins),
    );
  }

  Map<String, Object?> toJson() => {
    'cookies': cookies,
    'localStorage': localStorage,
    'active': active,
  };

  SourceBrowserSession copyWith({
    List<Map<String, Object?>>? cookies,
    Map<String, Map<String, String>>? localStorage,
    bool? active,
  }) => SourceBrowserSession(
    cookies: cookies ?? this.cookies,
    localStorage: localStorage ?? this.localStorage,
    active: active ?? this.active,
  );
}

bool isSourceBrowserUri(Uri? uri) =>
    uri != null &&
    (uri.scheme == 'https' || uri.scheme == 'http') &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty;

/// A script in loginUrl must never be mistaken for a relative website URL.
Uri? sourceBrowserLoginUri(Map<String, dynamic> config) {
  final raw = '${config['loginUrl'] ?? ''}'.trim();
  if (raw.isEmpty ||
      RegExp(r'[\s{}<>]').hasMatch(raw) ||
      raw.startsWith('@js:')) {
    return null;
  }
  final base = Uri.tryParse('${config['bookSourceUrl'] ?? ''}');
  final parsed = Uri.tryParse(raw);
  if (parsed == null || !isSourceBrowserUri(base)) return null;
  if (!parsed.hasScheme && RegExp(r'[();=]').hasMatch(parsed.path)) return null;
  final uri = base!.resolveUri(parsed);
  return isSourceBrowserUri(uri) ? uri : null;
}

class SourceBrowserCancelled implements Exception {
  const SourceBrowserCancelled();
}

class SourceBrowserResult {
  const SourceBrowserResult({
    required this.body,
    required this.finalUri,
    required this.session,
  });
  final String body;
  final Uri finalUri;
  final SourceBrowserSession session;
}

class SourceBrowserSessionClient {
  const SourceBrowserSessionClient();

  static const channel = MethodChannel(
    'com.niki.xxread/source_browser_session',
  );
  static int _serial = 0;

  bool get isSupported =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  Future<SourceBrowserResult> open({
    required String sourceId,
    required Uri url,
    required Map<String, String> headers,
    required SourceBrowserSession session,
    String? title,
    String? html,
  }) => _invoke('open', {
    'sourceId': sourceId,
    'url': url.toString(),
    'headers': headers,
    'session': session.toJson(),
    'title': title,
    'html': html,
  });

  Future<SourceBrowserResult> load({
    required String sourceId,
    required Uri url,
    required Map<String, String> headers,
    required SourceBrowserSession session,
    required String method,
    String? body,
    String? webJs,
    String? html,
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final requestId =
        'browser-${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
    void cancel() => unawaited(_cancel(requestId));
    final future = _invoke('load', {
      'sourceId': sourceId,
      'url': url.toString(),
      'headers': headers,
      'session': session.toJson(),
      'method': method,
      'body': body,
      'webJs': webJs,
      'html': html,
      'timeoutMs': 15000,
      'requestId': requestId,
    });
    cancellation?.addListener(cancel);
    try {
      if (cancellation == null) return await future;
      return await Future.any([
        future,
        cancellation.whenCancelled.then<SourceBrowserResult>((_) {
          throw const BookDownloadCancelledException();
        }),
      ]);
    } finally {
      cancellation?.removeListener(cancel);
    }
  }

  Future<void> clear(String sourceId) async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>('clear', {'sourceId': sourceId});
    } on MissingPluginException {
      // Older builds have no native browser state to clear.
    }
  }

  Future<void> _cancel(String requestId) async {
    try {
      await channel.invokeMethod<void>('cancel', {'requestId': requestId});
    } on PlatformException {
      // The request may already have completed and destroyed its WebView.
    } on MissingPluginException {
      // No native request was started in this build.
    }
  }

  Future<SourceBrowserResult> _invoke(
    String method,
    Map<String, Object?> args,
  ) async {
    if (!isSupported) {
      throw const BookSourceProtocolException(
        'Website login is supported on Android, iOS and macOS.',
      );
    }
    if (!isSourceBrowserUri(Uri.tryParse('${args['url']}'))) {
      throw const BookSourceProtocolException(
        'Website login requires an HTTP(S) URL.',
      );
    }
    try {
      final raw = await channel.invokeMapMethod<String, dynamic>(method, args);
      final uri = Uri.tryParse('${raw?['finalUrl'] ?? ''}');
      if (!isSourceBrowserUri(uri) ||
          raw?['session'] is! Map ||
          raw?['body'] is! String) {
        throw const BookSourceProtocolException(
          'The website returned an invalid session.',
        );
      }
      return SourceBrowserResult(
        body: raw!['body'] as String,
        finalUri: uri!,
        session: SourceBrowserSession.fromJson(
          raw['session'],
        ).copyWith(active: true),
      );
    } on PlatformException catch (error) {
      if (error.code == 'cancelled') throw const SourceBrowserCancelled();
      throw BookSourceProtocolException(
        error.message ?? 'Website login failed.',
      );
    } on MissingPluginException {
      throw const BookSourceProtocolException(
        'Website login is unavailable in this build.',
      );
    }
  }
}
