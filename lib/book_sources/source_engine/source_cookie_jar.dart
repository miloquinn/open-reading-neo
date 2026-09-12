import 'dart:io';

import 'package:dio/dio.dart';

import 'source_cookie_utils.dart';

typedef SourceCookieClock = DateTime Function();

class SourceCookieJar {
  SourceCookieJar({SourceCookieClock? clock}) : _clock = clock ?? _systemClock;

  final SourceCookieClock _clock;
  final Map<String, Map<String, SourceStoredCookie>> _jars = {};

  void clear() => _jars.clear();

  void clearSource(String sourceId) => _jars.remove(sourceId);

  List<Map<String, Object?>> exportCookies(String sourceId) {
    final jar = _jars[sourceId];
    if (jar == null) return const [];
    final now = _clock().toUtc();
    jar.removeWhere((_, cookie) => cookie.expiresAt?.isAfter(now) == false);
    return [for (final cookie in jar.values) cookie.toJson()];
  }

  void restoreCookies(String sourceId, List<Map<String, Object?>> cookies) {
    final jar = <String, SourceStoredCookie>{};
    final now = _clock().toUtc();
    for (final value in cookies) {
      try {
        final cookie = Cookie('${value['name']}', '${value['value']}')
          ..secure = value['secure'] == true
          ..httpOnly = value['httpOnly'] == true;
        final domain = '${value['domain'] ?? ''}'.toLowerCase().replaceFirst(
          RegExp(r'^\.'),
          '',
        );
        if (domain.isEmpty ||
            domain.contains('/') ||
            domain.contains(RegExp(r'\s'))) {
          continue;
        }
        final path = '${value['path'] ?? '/'}';
        final expires = value['expiresAt'];
        final expiresAt = expires is num
            ? DateTime.fromMillisecondsSinceEpoch(expires.toInt(), isUtc: true)
            : null;
        if (expiresAt != null && !expiresAt.isAfter(now)) continue;
        final stored = SourceStoredCookie(
          cookie: cookie,
          domain: domain,
          path: path.startsWith('/') ? path : '/',
          hostOnly: value['hostOnly'] != false,
          expiresAt: expiresAt,
          attributesKnown: value['attributesKnown'] != false,
          sameSite: value['sameSite'] as String?,
        );
        jar['$domain\u0000${stored.path}\u0000${cookie.name}'] = stored;
      } on FormatException {
        // Ignore malformed persisted cookie entries independently.
      }
    }
    _jars[sourceId] = jar;
  }

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
          sameSite: RegExp(
            r'(?:^|;)\s*SameSite=([^;]+)',
            caseSensitive: false,
          ).firstMatch(value)?.group(1)?.trim(),
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
    // A Cookie header can legitimately contain the same name for multiple
    // paths. Keep the jar's most-specific-path-first ordering intact.
    final storedPairs = [
      for (final pair in (stored ?? '').split(';'))
        if (pair.indexOf('=') > 0) pair.trim(),
    ];
    final storedNames = {
      for (final pair in storedPairs)
        pair.substring(0, pair.indexOf('=')).trim(),
    };
    final pairs = [
      ...storedPairs,
      for (final entry in parseSourceCookieHeader(configured).entries)
        if (!storedNames.contains(entry.key)) '${entry.key}=${entry.value}',
    ];
    return pairs.isEmpty ? null : pairs.join('; ');
  }
}

class SourceStoredCookie {
  const SourceStoredCookie({
    required this.cookie,
    required this.domain,
    required this.path,
    required this.hostOnly,
    required this.expiresAt,
    this.attributesKnown = true,
    this.sameSite,
  });

  final Cookie cookie;
  final String domain;
  final String path;
  final bool hostOnly;
  final DateTime? expiresAt;
  final bool attributesKnown;
  final String? sameSite;

  Map<String, Object?> toJson() => {
    'name': cookie.name,
    'value': cookie.value,
    'domain': domain,
    'path': path,
    'secure': cookie.secure,
    'httpOnly': cookie.httpOnly,
    'hostOnly': hostOnly,
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
    'attributesKnown': attributesKnown,
    if (sameSite != null) 'sameSite': sameSite,
  };

  bool matches(Uri uri) {
    if (cookie.secure && uri.scheme != 'https') return false;
    if (!_cookieDomainMatches(uri.host, domain, hostOnly: hostOnly)) {
      return false;
    }
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    return requestPath == path ||
        (requestPath.startsWith(path) &&
            (path.endsWith('/') ||
                requestPath.substring(path.length).startsWith('/')));
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
