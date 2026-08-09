import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'source_config.dart';
import 'source_login_session.dart';
import 'source_login_ui.dart';
import 'source_script_contract.dart';
import 'source_transport.dart';

abstract interface class SourceRuntimeSessionPort {
  Future<void> ensure(ReadingSourceConfig source);
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
  });
}

class SourceRuntimeSessionManager implements SourceRuntimeSessionPort {
  SourceRuntimeSessionManager(this._store, this._cookieTransport);

  final SourceLoginSessionStore _store;
  final SourceCookieTransport? _cookieTransport;
  final Map<String, SourceLoginSession> _sessions = {};
  final Set<String> _dirty = {};

  @override
  Future<void> ensure(ReadingSourceConfig source) async {
    if (_sessions.containsKey(source.stableId)) return;
    try {
      _sessions[source.stableId] = await _store.read(source.stableId);
    } on Object {
      _sessions[source.stableId] = const SourceLoginSession();
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
    final session = SourceLoginSession(
      loginInfo: Map.unmodifiable(loginInfo),
      loginHeaders: Map.unmodifiable(loginHeaders),
    );
    _sessions[source.stableId] = session;
    await _store.write(source.stableId, session);
  }

  @override
  void updateInfo(ReadingSourceConfig source, Map<String, String> loginInfo) {
    final previous = current(source);
    if (_sameStringMap(previous.loginInfo, loginInfo)) return;
    _sessions[source.stableId] = SourceLoginSession(
      loginInfo: Map.unmodifiable(loginInfo),
      loginHeaders: previous.loginHeaders,
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
    if (!_dirty.remove(source.stableId)) return;
    try {
      await _store.write(source.stableId, current(source));
    } on Object {
      _dirty.add(source.stableId);
      rethrow;
    }
  }

  @override
  Future<void> clear(ReadingSourceConfig source) async {
    _sessions.remove(source.stableId);
    await _store.clear(source.stableId);
    removeCookies(source, source.baseUri);
  }

  @override
  String cookieHeader(ReadingSourceConfig source, Uri uri) {
    final cookieTransport = _cookieTransport;
    if (!source.enabledCookieJar || cookieTransport == null) {
      return '';
    }
    return cookieTransport.scriptCookieHeader(source.stableId, uri);
  }

  @override
  void setCookies(ReadingSourceConfig source, Uri uri, String cookie) {
    final cookieTransport = _cookieTransport;
    if (source.enabledCookieJar && cookieTransport != null) {
      cookieTransport.setScriptCookies(source.stableId, uri, cookie);
    }
  }

  @override
  void removeCookies(ReadingSourceConfig source, Uri uri) {
    final cookieTransport = _cookieTransport;
    if (source.enabledCookieJar && cookieTransport != null) {
      cookieTransport.removeScriptCookies(source.stableId, uri);
    }
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
  }) : this._(sessions, contexts, scripts);

  SourceRuntimeLogin._(this._sessions, this._contexts, this._scripts);

  final SourceRuntimeSessionPort _sessions;
  final SourceRuntimeScriptContextPort _contexts;
  final SourceScriptEvaluator Function() _scripts;

  Future<void> saveLoginSession(
    RegisteredBookSource registered, {
    Map<String, String> loginInfo = const {},
    Map<String, String> loginHeaders = const {},
  }) => _sessions.save(
    sourceFromRegistered(registered),
    loginInfo: loginInfo,
    loginHeaders: loginHeaders,
  );

  Future<void> clearLoginSession(RegisteredBookSource registered) =>
      _sessions.clear(sourceFromRegistered(registered));

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
    Map<String, String> values,
  ) async {
    final source = sourceFromRegistered(registered);
    await _sessions.ensure(source);
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
    await _scripts().evaluateAsync(
      '$loginScript\nif (typeof login === \'function\') login();',
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
