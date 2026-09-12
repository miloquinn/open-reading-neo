import 'dart:convert';

import '../models/registered_book_source.dart';
import 'source_browser_session.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import 'source_config.dart';
import 'source_login_session.dart';
import 'source_login_ui.dart';
import 'scripting/source_script_contract.dart';
import 'source_transport.dart';

abstract interface class SourceRuntimeSessionPort {
  Future<void> ensure(ReadingSourceConfig source);
  int generation(ReadingSourceConfig source);
  SourceLoginSession current(ReadingSourceConfig source);
  Future<void> save(
    ReadingSourceConfig source, {
    Map<String, String> loginInfo,
    Map<String, String> loginHeaders,
  });
  void updateInfo(ReadingSourceConfig source, Map<String, String> loginInfo);
  void updateHeaders(
    ReadingSourceConfig source,
    Map<String, String> loginHeaders,
  );
  Future<void> flush(ReadingSourceConfig source);
  Future<void> clear(ReadingSourceConfig source);
  String cookieHeader(ReadingSourceConfig source, Uri uri);
  void setCookies(ReadingSourceConfig source, Uri uri, String cookie);
  void removeCookies(ReadingSourceConfig source, Uri uri);
  void clearMemory();
  Future<void> saveBrowserSession(
    ReadingSourceConfig source,
    SourceBrowserSession session, {
    int? expectedGeneration,
  });
  void updateLocalStorage(
    ReadingSourceConfig source,
    Map<String, Map<String, String>> storage, {
    Map<String, Map<String, String>>? initial,
    Set<String> clearedOrigins = const {},
  });
}

abstract interface class SourceRuntimeScriptContextPort {
  SourceScriptContext scriptContext(
    ReadingSourceConfig source, {
    Object? result,
    Uri? baseUrl,
    Map<String, String> variables,
    Map<String, Object?> book,
    Map<String, Object?> chapter,
    bool includeSourceHeaders,
    BookDownloadCancellation? cancellation,
  });
}

class SourceRuntimeSessionManager implements SourceRuntimeSessionPort {
  SourceRuntimeSessionManager(this._store, this._cookieTransport);

  final SourceLoginSessionStore _store;
  final SourceCookieTransport? _cookieTransport;
  final Map<String, SourceLoginSession> _sessions = {};
  final Set<String> _dirty = {};
  final Map<String, Future<void>> _writes = {};
  final Map<String, Future<void>> _loads = {};
  final Map<String, int> _revisions = {};

  Future<void> _persist(String id, Future<void> Function() action) {
    final write = (_writes[id] ?? Future<void>.value()).then((_) => action());
    _writes[id] = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }

  SourceBrowserSessionTransport? get _browserTransport =>
      switch (_cookieTransport) {
        final SourceBrowserSessionTransport value => value,
        _ => null,
      };

  @override
  int generation(ReadingSourceConfig source) =>
      _revisions[source.stableId] ?? 0;

  @override
  Future<void> ensure(ReadingSourceConfig source) async {
    if (_sessions.containsKey(source.stableId)) return;
    final id = source.stableId;
    final pending = _loads[id];
    if (pending != null) return pending;
    final revision = _revisions[id] ?? 0;
    final load = () async {
      SourceLoginSession session;
      try {
        session = await _store.read(id);
      } on Object {
        // Public reading remains available when platform secure storage is
        // unavailable. Explicit login writes still surface storage failures.
        session = const SourceLoginSession();
      }
      if ((_revisions[id] ?? 0) != revision) return;
      _sessions[id] = session;
      _browserTransport?.restoreBrowserSession(id, session.browserSession);
    }();
    _loads[id] = load;
    try {
      await load;
    } finally {
      _loads.remove(id);
    }
  }

  @override
  SourceLoginSession current(ReadingSourceConfig source) =>
      _sessions[source.stableId] ?? const SourceLoginSession();

  @override
  Future<void> save(
    ReadingSourceConfig source, {
    Map<String, String> loginInfo = const {},
    Map<String, String> loginHeaders = const {},
  }) async {
    final previous = current(source);
    final session = SourceLoginSession(
      loginInfo: Map.unmodifiable(loginInfo),
      loginHeaders: Map.unmodifiable(loginHeaders),
      browserSession: previous.browserSession,
    );
    _sessions[source.stableId] = session;
    await _persist(
      source.stableId,
      () => _store.write(source.stableId, session),
    );
  }

  @override
  void updateInfo(ReadingSourceConfig source, Map<String, String> loginInfo) {
    final previous = current(source);
    if (_sameStringMap(previous.loginInfo, loginInfo)) return;
    _sessions[source.stableId] = SourceLoginSession(
      loginInfo: Map.unmodifiable(loginInfo),
      loginHeaders: previous.loginHeaders,
      browserSession: previous.browserSession,
    );
    _dirty.add(source.stableId);
  }

  @override
  void updateHeaders(
    ReadingSourceConfig source,
    Map<String, String> loginHeaders,
  ) {
    final previous = current(source);
    if (_sameStringMap(previous.loginHeaders, loginHeaders)) return;
    _sessions[source.stableId] = SourceLoginSession(
      loginInfo: previous.loginInfo,
      loginHeaders: Map.unmodifiable(loginHeaders),
      browserSession: previous.browserSession,
    );
    final cookie = loginHeaders.entries
        .where((entry) => entry.key.toLowerCase() == 'cookie')
        .map((entry) => entry.value)
        .firstOrNull;
    if (cookie != null) setCookies(source, source.baseUri, cookie);
    _dirty.add(source.stableId);
  }

  @override
  Future<void> flush(ReadingSourceConfig source) async {
    final previous = current(source);
    final browser = _browserTransport?.browserSession(source.stableId);
    if (browser != null &&
        jsonEncode(browser.toJson()) !=
            jsonEncode(previous.browserSession.toJson())) {
      _sessions[source.stableId] = SourceLoginSession(
        loginInfo: previous.loginInfo,
        loginHeaders: previous.loginHeaders,
        browserSession: browser,
      );
      _dirty.add(source.stableId);
    }
    if (!_dirty.remove(source.stableId)) return;
    try {
      final snapshot = current(source);
      await _persist(
        source.stableId,
        () => _store.write(source.stableId, snapshot),
      );
    } on Object {
      _dirty.add(source.stableId);
      rethrow;
    }
  }

  @override
  Future<void> clear(ReadingSourceConfig source) async {
    final id = source.stableId;
    _revisions[id] = (_revisions[id] ?? 0) + 1;
    _sessions[id] = const SourceLoginSession();
    _dirty.remove(id);
    _browserTransport?.clearBrowserSession(id);
    removeCookies(source, source.baseUri);
    await _persist(id, () => _store.clear(id));
  }

  @override
  String cookieHeader(ReadingSourceConfig source, Uri uri) {
    final cookieTransport = _cookieTransport;
    if ((!source.enabledCookieJar && !current(source).browserSession.active) ||
        cookieTransport == null) {
      return '';
    }
    return cookieTransport.scriptCookieHeader(source.stableId, uri);
  }

  @override
  void setCookies(ReadingSourceConfig source, Uri uri, String cookie) {
    final cookieTransport = _cookieTransport;
    if ((source.enabledCookieJar || current(source).browserSession.active) &&
        cookieTransport != null) {
      cookieTransport.setScriptCookies(source.stableId, uri, cookie);
    }
  }

  @override
  void removeCookies(ReadingSourceConfig source, Uri uri) {
    final cookieTransport = _cookieTransport;
    if ((source.enabledCookieJar || current(source).browserSession.active) &&
        cookieTransport != null) {
      cookieTransport.removeScriptCookies(source.stableId, uri);
    }
  }

  @override
  Future<void> saveBrowserSession(
    ReadingSourceConfig source,
    SourceBrowserSession session, {
    int? expectedGeneration,
  }) async {
    if (expectedGeneration != null &&
        generation(source) != expectedGeneration) {
      throw const SourceBrowserCancelled();
    }
    final previous = current(source);
    final next = SourceLoginSession(
      loginInfo: previous.loginInfo,
      loginHeaders: previous.loginHeaders,
      browserSession: session,
    );
    // Publish only after secure storage succeeds: a cancelled or failed login
    // must not silently replace the prior usable account.
    final revision = _revisions[source.stableId] ?? 0;
    await _persist(source.stableId, () => _store.write(source.stableId, next));
    if ((_revisions[source.stableId] ?? 0) != revision) {
      throw const SourceBrowserCancelled();
    }
    _sessions[source.stableId] = next;
    _browserTransport?.restoreBrowserSession(source.stableId, session);
  }

  @override
  void updateLocalStorage(
    ReadingSourceConfig source,
    Map<String, Map<String, String>> storage, {
    Map<String, Map<String, String>>? initial,
    Set<String> clearedOrigins = const {},
  }) {
    final previous = current(source);
    final merged = <String, Map<String, String>>{
      for (final entry in previous.browserSession.localStorage.entries)
        entry.key: Map<String, String>.from(entry.value),
    };
    if (initial != null) {
      for (final origin in {
        ...initial.keys,
        ...storage.keys,
        ...clearedOrigins,
      }) {
        final before = initial[origin] ?? const <String, String>{};
        final after = storage[origin] ?? const <String, String>{};
        if (clearedOrigins.contains(origin)) merged[origin] = {};
        final currentValues = merged.putIfAbsent(origin, () => {});
        for (final key in {...before.keys, ...after.keys}) {
          if (!clearedOrigins.contains(origin) &&
              before[key] == after[key] &&
              before.containsKey(key) == after.containsKey(key)) {
            continue;
          }
          if (after.containsKey(key)) {
            currentValues[key] = after[key]!;
          } else {
            currentValues.remove(key);
          }
        }
      }
    }
    final browser =
        (_browserTransport?.browserSession(source.stableId) ??
                previous.browserSession)
            .copyWith(localStorage: initial == null ? storage : merged);
    _sessions[source.stableId] = SourceLoginSession(
      loginInfo: previous.loginInfo,
      loginHeaders: previous.loginHeaders,
      browserSession: browser,
    );
    _browserTransport?.restoreBrowserSession(source.stableId, browser);
    _dirty.add(source.stableId);
  }

  @override
  void clearMemory() {
    _sessions.clear();
    _dirty.clear();
  }
}

class SourceRuntimeLogin {
  SourceRuntimeLogin({
    required SourceRuntimeSessionPort sessions,
    required SourceRuntimeScriptContextPort contexts,
    required SourceScriptEvaluator Function() scripts,
    SourceBrowserSessionClient browser = const SourceBrowserSessionClient(),
  }) : this._(sessions, contexts, scripts, browser);

  SourceRuntimeLogin._(
    this._sessions,
    this._contexts,
    this._scripts,
    this._browser,
  );

  final SourceRuntimeSessionPort _sessions;
  final SourceRuntimeScriptContextPort _contexts;
  final SourceScriptEvaluator Function() _scripts;
  final SourceBrowserSessionClient _browser;
  final Map<String, int> _loginRevisions = {};
  final Set<String> _openBrowsers = {};

  Future<void> saveLoginSession(
    RegisteredBookSource registered, {
    Map<String, String> loginInfo = const {},
    Map<String, String> loginHeaders = const {},
  }) => _sessions.save(
    sourceFromRegistered(registered),
    loginInfo: loginInfo,
    loginHeaders: loginHeaders,
  );

  Future<void> clearLoginSession(RegisteredBookSource registered) async {
    final source = sourceFromRegistered(registered);
    _loginRevisions[source.stableId] =
        (_loginRevisions[source.stableId] ?? 0) + 1;
    await _sessions.ensure(source);
    final hasBrowser =
        _sessions.current(source).browserSession.active ||
        _openBrowsers.contains(source.stableId);
    try {
      if (hasBrowser) await _browser.clear(source.stableId);
    } finally {
      await _sessions.clear(source);
    }
  }

  Future<void> browserLogin(
    ReadingSourceConfig source,
    Uri uri, {
    String? html,
  }) async {
    await _sessions.ensure(source);
    final revision = (_loginRevisions[source.stableId] ?? 0) + 1;
    _loginRevisions[source.stableId] = revision;
    final previous = _sessions.current(source);
    final rawHeaders = source.raw['header'];
    Map? headers;
    if (rawHeaders is Map) headers = rawHeaders;
    if (rawHeaders is String) {
      try {
        final value = jsonDecode(rawHeaders);
        if (value is Map) headers = value;
      } on FormatException {
        final body =
            sourceScriptBody(rawHeaders) ?? 'JSON.stringify(($rawHeaders))';
        Object? value = await _scripts().evaluateAsync(
          body,
          _contexts.scriptContext(source, includeSourceHeaders: false),
        );
        if (value is String) value = jsonDecode(value);
        if (value is! Map) {
          throw const BookSourceProtocolException(
            'Website headers must return an object.',
          );
        }
        headers = value;
      }
    }
    _openBrowsers.add(source.stableId);
    try {
      final result = await _browser.open(
        sourceId: source.stableId,
        url: uri,
        title: source.name,
        html: html,
        headers: {
          if (headers != null)
            for (final item in headers.entries) '${item.key}': '${item.value}',
          ...previous.loginHeaders,
        },
        session: previous.browserSession,
      );
      if (_loginRevisions[source.stableId] != revision) {
        throw const SourceBrowserCancelled();
      }
      await _sessions.saveBrowserSession(source, result.session);
    } finally {
      _openBrowsers.remove(source.stableId);
    }
  }

  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource registered,
  ) async {
    final source = sourceFromRegistered(registered);
    await _sessions.ensure(source);
    final raw = source.raw['loginUi'];
    if (raw is! String || raw.trim().isEmpty) return const [];
    final body = sourceScriptBody(raw);
    if (body == null) return parseSourceLoginFields(raw);
    final loginSource = '${source.raw['loginUrl'] ?? ''}';
    final loginScript = sourceScriptBody(loginSource) ?? loginSource;
    final value = await _scripts().evaluateAsync(
      '$loginScript\n$body',
      _contexts.scriptContext(
        source,
        result: _sessions.current(source).loginInfo,
      ),
    );
    return parseSourceLoginFields(value);
  }

  Future<void> login(
    RegisteredBookSource registered,
    Map<String, String> values, {
    String? action,
  }) async {
    final source = sourceFromRegistered(registered);
    await _sessions.ensure(source);
    final website = sourceBrowserLoginUri(source.raw);
    if (website != null) {
      await browserLogin(source, website);
      return;
    }
    final fields = await loadLoginFields(registered);
    final loginInfo = <String, String>{
      ..._sessions.current(source).loginInfo,
      for (final field in fields)
        if (!field.isButton)
          field.name: values[field.name] ?? field.defaultValue ?? '',
      ...values,
    };
    await _sessions.save(source, loginInfo: loginInfo);
    final loginSource = '${source.raw['loginUrl'] ?? ''}';
    final loginScript = sourceScriptBody(loginSource) ?? loginSource;
    if (loginScript.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'This source does not define a login script.',
      );
    }
    final trimmedAction = action?.trim() ?? '';
    final actionScript = switch (Uri.tryParse(trimmedAction)) {
      final uri?
          when (uri.scheme == 'http' || uri.scheme == 'https') &&
              uri.host.isNotEmpty =>
        'java.startBrowserAwait(${jsonEncode(uri.toString())});',
      _ when trimmedAction.isNotEmpty => trimmedAction,
      _ => "if (typeof login === 'function') login();",
    };
    await _scripts().evaluateAsync(
      '$loginScript\n$actionScript',
      _contexts.scriptContext(source, result: loginInfo),
    );
    await _sessions.flush(source);
  }
}

ReadingSourceConfig sourceFromRegistered(RegisteredBookSource registered) {
  if (registered.sourceProtocol != BookSourceProtocolKind.readingSource ||
      registered.sourceConfig == null) {
    throw const BookSourceProtocolException(
      'This is not a compatible source configuration.',
    );
  }
  return ReadingSourceConfig.fromJson(registered.sourceConfig!);
}

String? sourceScriptBody(String value) {
  final trimmed = value.trim();
  if (trimmed.toLowerCase().startsWith('@js:')) {
    return trimmed.substring(4).trimLeft();
  }
  return RegExp(
    r'^<js>(.*?)</js>$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(trimmed)?.group(1);
}

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}
