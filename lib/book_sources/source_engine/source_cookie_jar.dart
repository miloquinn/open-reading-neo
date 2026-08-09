import 'dart:io';

import 'package:dio/dio.dart';

import 'source_cookie_utils.dart';

typedef SourceCookieClock = DateTime Function();

class SourceCookieJar {
  SourceCookieJar({SourceCookieClock? clock}) : _clock = clock ?? _systemClock;

  final SourceCookieClock _clock;
  final Map<String, Map<String, SourceStoredCookie>> _jars = {};

  void clear() => _jars.clear();

  String scriptCookieHeader(String jarKey, Uri uri) =>
      header(jarKey, uri) ?? '';

  void setScriptCookies(String jarKey, Uri uri, String cookieHeader) {
    final jar = _jars.putIfAbsent(jarKey, () => {});
    jar.removeWhere(
      (_, cookie) => _cookieDomainMatches(
        uri.host,
        cookie.domain,
        hostOnly: cookie.hostOnly,
      ),
    );
    storeBrowserCookies(jarKey, uri, cookieHeader);
  }

  void removeScriptCookies(String jarKey, Uri uri) {
    final jar = _jars[jarKey];
    if (jar == null) return;
    jar.removeWhere(
      (_, cookie) => _cookieDomainMatches(
        uri.host,
        cookie.domain,
        hostOnly: cookie.hostOnly,
      ),
    );
    if (jar.isEmpty) _jars.remove(jarKey);
  }

  String? header(String? jarKey, Uri uri) {
    if (jarKey == null) return null;
    return headerFromJar(_jars[jarKey], uri);
  }

  String? headerFromJar(Map<String, SourceStoredCookie>? jar, Uri uri) {
    if (jar == null || jar.isEmpty) return null;
    final now = _clock().toUtc();
    jar.removeWhere((_, cookie) => cookie.expiresAt?.isBefore(now) ?? false);
    final matching = jar.values.where((cookie) => cookie.matches(uri)).toList()
      ..sort((left, right) => right.path.length.compareTo(left.path.length));
    if (matching.isEmpty) return null;
    return matching
        .map((cookie) => '${cookie.cookie.name}=${cookie.cookie.value}')
        .join('; ');
  }

  void store(String? jarKey, Uri uri, Headers headers) {
    if (jarKey == null) return;
    storeInJar(_jars.putIfAbsent(jarKey, () => {}), uri, headers);
  }

  Map<String, SourceStoredCookie> createTransientJar() => {};

  void storeInJar(
    Map<String, SourceStoredCookie> jar,
    Uri uri,
    Headers headers,
  ) {
    final values = headers[HttpHeaders.setCookieHeader];
    if (values == null || values.isEmpty) return;
    final now = _clock().toUtc();
    for (final value in values) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        final configuredDomain = cookie.domain?.trim().toLowerCase();
        final domain = (configuredDomain == null || configuredDomain.isEmpty)
            ? uri.host.toLowerCase()
            : configuredDomain.replaceFirst(RegExp(r'^\.'), '');
        final hostOnly = configuredDomain == null || configuredDomain.isEmpty;
        if (!_cookieDomainMatches(uri.host, domain, hostOnly: hostOnly)) {
          continue;
        }
        final path = cookie.path?.isNotEmpty == true
            ? cookie.path!
            : _defaultCookiePath(uri.path);
        final id = '$domain\u0000$path\u0000${cookie.name}';
        final expiresAt = cookie.maxAge == null
            ? cookie.expires?.toUtc()
            : now.add(Duration(seconds: cookie.maxAge!));
        if ((cookie.maxAge != null && cookie.maxAge! <= 0) ||
            (expiresAt?.isBefore(now) ?? false)) {
          jar.remove(id);
          continue;
        }
        jar[id] = SourceStoredCookie(
          cookie: cookie,
          domain: domain,
          path: path,
          hostOnly: hostOnly,
          expiresAt: expiresAt,
        );
      } on FormatException {
        // Ignore one malformed Set-Cookie without discarding the response.
      }
    }
  }

  void storeBrowserCookies(String? jarKey, Uri uri, String? cookieHeader) {
    if (jarKey == null || cookieHeader == null || cookieHeader.trim().isEmpty) {
      return;
    }
    final jar = _jars.putIfAbsent(jarKey, () => {});
    final domain = uri.host.toLowerCase();
    for (final entry in parseSourceCookieHeader(cookieHeader).entries) {
      final cookie = Cookie(entry.key, entry.value);
      final id = '$domain\u0000/\u0000${entry.key}';
      jar[id] = SourceStoredCookie(
        cookie: cookie,
        domain: domain,
        path: '/',
        hostOnly: true,
        expiresAt: null,
      );
    }
  }

  static String? mergeHeaders(String? configured, String? stored) {
    final values = <String, String>{};
    for (final header in [configured, stored]) {
      values.addAll(parseSourceCookieHeader(header));
    }
    if (values.isEmpty) return null;
    return values.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }
}

class SourceStoredCookie {
  const SourceStoredCookie({
    required this.cookie,
    required this.domain,
    required this.path,
    required this.hostOnly,
    required this.expiresAt,
  });

  final Cookie cookie;
  final String domain;
  final String path;
  final bool hostOnly;
  final DateTime? expiresAt;

  bool matches(Uri uri) {
    if (cookie.secure && uri.scheme != 'https') return false;
    if (!_cookieDomainMatches(uri.host, domain, hostOnly: hostOnly)) {
      return false;
    }
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return requestPath.startsWith(path);
  }
}

DateTime _systemClock() => DateTime.now();

bool _cookieDomainMatches(
  String host,
  String domain, {
  required bool hostOnly,
}) {
  final normalizedHost = host.toLowerCase();
  if (normalizedHost == domain) return true;
  return !hostOnly && normalizedHost.endsWith('.$domain');
}

String _defaultCookiePath(String requestPath) {
  if (!requestPath.startsWith('/') || requestPath == '/') return '/';
  final lastSlash = requestPath.lastIndexOf('/');
  return lastSlash <= 0 ? '/' : requestPath.substring(0, lastSlash + 1);
}
