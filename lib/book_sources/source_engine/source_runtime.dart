import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import 'source_concurrency_limiter.dart';
import 'source_debug.dart';
import 'source_http_transport.dart';
import 'source_interaction_coordinator.dart';
import 'source_login_session.dart';
import 'source_login_ui.dart';
import 'source_rule_engine.dart';
import 'source_runtime_catalog.dart';
import 'source_runtime_dependencies.dart';
import 'source_runtime_login.dart';
import 'source_runtime_reading.dart';
import 'source_runtime_requests.dart';
import 'source_runtime_rules.dart';
import 'source_runtime_state.dart';
import 'source_script_contract.dart';
import 'source_transport.dart';

class SourceRuntime {
  SourceRuntime({
    SourceTransport? transport,
    SourceScriptEvaluator? scriptEvaluator,
    SourceLoginSessionStore? loginSessionStore,
    SourceConcurrencyLimiter? concurrencyLimiter,
    SourceDebugRecorder? debugRecorder,
    SourceInteractionCoordinatorPort? interactionCoordinator,
  }) : _transport = transport ?? SourceHttpTransport(),
       _debugRecorder = debugRecorder {
    final interactionTransport = switch (_transport) {
      final SourceInteractionTransport value => value,
      _ => null,
    };
    final cookieTransport = switch (_transport) {
      final SourceCookieTransport value => value,
      _ => null,
    };
    _trace = SourceRuntimeTrace(debugRecorder);
    _scripts = SourceRuntimeScriptOwner(scriptEvaluator);
    _state = SourceRuntimeState();
    _sessions = SourceRuntimeSessionManager(
      loginSessionStore ?? SecureSourceLoginSessionStore(),
      cookieTransport,
    );
    _rules = SourceRuntimeRules(
      SourceRuleEngine(scriptEvaluatorProvider: () => _scripts.evaluator),
    );
    _requests = SourceRuntimeRequests(
      transport: _transport,
      limiter: concurrencyLimiter ?? SourceConcurrencyLimiter(),
      sessions: _sessions,
      rules: _rules,
      state: _state,
      trace: _trace,
      scripts: () => _scripts.evaluator,
      interactionCoordinator:
          interactionCoordinator ?? SourceInteractionCoordinator.instance,
      interactionTransport: interactionTransport,
    );
    _login = SourceRuntimeLogin(
      sessions: _sessions,
      contexts: _requests,
      scripts: () => _scripts.evaluator,
    );
    _catalog = SourceRuntimeCatalog(
      requests: _requests,
      rules: _rules,
      state: _state,
      sessions: _sessions,
    );
    _reading = SourceRuntimeReading(
      requests: _requests,
      rules: _rules,
      state: _state,
      sessions: _sessions,
    );
  }

  final SourceTransport _transport;
  late final SourceRuntimeTrace _trace;
  late final SourceRuntimeScriptOwner _scripts;
  late final SourceRuntimeState _state;
  late final SourceRuntimeSessionPort _sessions;
  late final SourceRuntimeRulePort _rules;
  late final SourceRuntimeRequests _requests;
  late final SourceRuntimeLogin _login;
  late final SourceRuntimeCatalog _catalog;
  late final SourceRuntimeReading _reading;
  SourceDebugRecorder? _debugRecorder;

  /// When set, traces every request and flow stage made through this
  /// runtime. Meant for a single dedicated runtime driving one debug
  /// session — a shared, long-lived runtime should never have one attached,
  /// since concurrent unrelated calls would interleave in its trace.
  SourceDebugRecorder? get debugRecorder => _debugRecorder;
  set debugRecorder(SourceDebugRecorder? value) {
    _debugRecorder = value;
    _trace.recorder = value;
  }

  void close({bool force = true}) {
    _state.clear();
    _sessions.clearMemory();
    _scripts.close();
    final transport = _transport;
    if (transport case final SourceClosableTransport closable) {
      closable.close(force: force);
    }
  }

  Future<BookSourceSearchPage> search(
    RegisteredBookSource registered,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) => _trace.stage(
    'search',
    () => _catalog.search(
      registered,
      query,
      page: page,
      pageSize: pageSize,
      cancellation: cancellation,
    ),
    describe: (page) => '${page.items.length} result(s)',
  );

  Future<List<BookSourceCategory>> getExploreCategories(
    RegisteredBookSource registered,
  ) => _catalog.getExploreCategories(registered);

  Future<BookSourceSearchPage> browse(
    RegisteredBookSource registered, {
    required String? category,
    int page = 1,
    int pageSize = 20,
  }) => _trace.stage(
    'explore',
    () => _catalog.browse(
      registered,
      category: category,
      page: page,
      pageSize: pageSize,
    ),
    describe: (page) => '${page.items.length} result(s)',
  );

  Future<BookSourceBook> getBook(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) => _trace.stage(
    'info',
    () =>
        _catalog.getBook(registered, bookId, sourceVariables: sourceVariables),
    describe: (book) =>
        '"${book.title}" by ${book.author.isEmpty ? 'unknown author' : book.author}',
  );

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource registered,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) => _trace.stage(
    'toc',
    () => _reading.getChapters(
      registered,
      bookId,
      sourceVariables: sourceVariables,
    ),
    describe: (chapters) => '${chapters.length} chapter(s)',
  );

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource registered, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) => _trace.stage(
    'content',
    () => _reading.getChapterContent(
      registered,
      bookId: bookId,
      chapterId: chapterId,
      sourceVariables: sourceVariables,
    ),
    describe: (content) => '${content.content.length} character(s)',
  );

  Future<void> saveLoginSession(
    RegisteredBookSource registered, {
    Map<String, String> loginInfo = const {},
    Map<String, String> loginHeaders = const {},
  }) => _login.saveLoginSession(
    registered,
    loginInfo: loginInfo,
    loginHeaders: loginHeaders,
  );

  Future<void> clearLoginSession(RegisteredBookSource registered) =>
      _login.clearLoginSession(registered);

  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource registered,
  ) => _login.loadLoginFields(registered);

  Future<void> login(
    RegisteredBookSource registered,
    Map<String, String> values,
  ) => _login.login(registered, values);
}
