import 'dart:async';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'source_runtime.dart';
import 'source_transport.dart';

/// One capability a book source can independently succeed or fail at.
/// `info`/`catalog`/`content` form a dependent chain — each is only attempted
/// once the previous one produced something to feed it — so a source with a
/// broken `content` rule still reports `search`/`info`/`catalog` as healthy.
enum SourceHealthCapability { search, discover, info, catalog, content }

class SourceHealthCheckResult {
  const SourceHealthCheckResult({
    required this.checked,
    required this.failed,
    required this.checkedAt,
    this.respondTimeMs,
    this.timedOut = false,
  });

  final Set<SourceHealthCapability> checked;
  final Set<SourceHealthCapability> failed;
  final DateTime checkedAt;
  final int? respondTimeMs;
  final bool timedOut;

  bool get healthy => !timedOut && checked.isNotEmpty && failed.isEmpty;

  /// The capabilities required to browse into a source's list and read a
  /// full chapter of a book — stricter than [healthy], which only requires
  /// that whatever *was* attempted didn't fail (so a source lacking the
  /// `search` capability could still read as healthy without ever proving it
  /// can list books or return content).
  static const Set<SourceHealthCapability> fullAvailabilityCapabilities = {
    SourceHealthCapability.search,
    SourceHealthCapability.discover,
    SourceHealthCapability.info,
    SourceHealthCapability.content,
  };

  bool get fullyAvailable =>
      !timedOut &&
      failed.isEmpty &&
      checked.containsAll(fullAvailabilityCapabilities);

  /// The capabilities keeping this result short of [fullyAvailable]: ones
  /// that failed outright, plus ones a source never even attempted (for
  /// example because it doesn't declare a `search` rule at all).
  Set<SourceHealthCapability> get missingForFullAvailability => timedOut
      ? fullAvailabilityCapabilities
      : fullAvailabilityCapabilities
            .difference(checked)
            .union(failed.intersection(fullAvailabilityCapabilities));

  Map<String, dynamic> toJson() => {
    'checked': (checked.map((capability) => capability.name).toList()..sort()),
    'failed': (failed.map((capability) => capability.name).toList()..sort()),
    'checkedAt': checkedAt.toIso8601String(),
    if (respondTimeMs != null) 'respondTimeMs': respondTimeMs,
    if (timedOut) 'timedOut': true,
  };

  factory SourceHealthCheckResult.fromJson(Map<String, dynamic> json) {
    return SourceHealthCheckResult(
      checked: _capabilitiesFromJson(json['checked']),
      failed: _capabilitiesFromJson(json['failed']),
      checkedAt:
          DateTime.tryParse('${json['checkedAt']}')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      respondTimeMs: (json['respondTimeMs'] as num?)?.toInt(),
      timedOut: json['timedOut'] == true,
    );
  }
}

/// Reads back the most recently persisted [SourceHealthCheckResult] for
/// [source], if any. Returns null for a source that has never been checked
/// or whose stored result could not be parsed.
SourceHealthCheckResult? sourceHealthCheckResultOf(
  RegisteredBookSource source,
) {
  final raw = source.sourceConfig?['_openReadingHealthCheck'];
  if (raw is! Map) return null;
  try {
    return SourceHealthCheckResult.fromJson(
      raw.map((key, value) => MapEntry('$key', value)),
    );
  } on Object {
    return null;
  }
}

/// Returns [source] with [result] merged into its stored configuration.
/// Callers are responsible for persisting the returned copy (e.g. via
/// `BookSourceRegistry.upsert`/`upsertAll`).
RegisteredBookSource withSourceHealthCheckResult(
  RegisteredBookSource source,
  SourceHealthCheckResult result,
) {
  return source.copyWith(
    sourceConfig: {
      ...?source.sourceConfig,
      '_openReadingHealthCheck': result.toJson(),
    },
  );
}

/// Runs a single compatible source through its available capabilities —
/// search, discover, and the info → catalog → content reading chain — and
/// reports which ones actually work right now. Unlike [SourceVerifier]
/// (which screens many *candidate* sources down to a usable set at import
/// time), this checks one *already added* source in depth, the way legado's
/// "校验书源" does, so a broken `content` rule doesn't hide that search still
/// works.
class SourceHealthChecker {
  const SourceHealthChecker({
    this.keyword = '斗破苍穹',
    this.timeout = const Duration(seconds: 20),
    SourceTransport? transport,
    // ignore: prefer_initializing_formals
  }) : _transport = transport;

  final String keyword;
  final Duration timeout;
  final SourceTransport? _transport;

  /// A copy of this checker with a different [timeout], keeping the same
  /// [keyword] and transport — used by cleanup-oriented batch sweeps that
  /// want a tighter per-source budget than a user-initiated check.
  SourceHealthChecker withTimeout(Duration timeout) => SourceHealthChecker(
    keyword: keyword,
    timeout: timeout,
    transport: _transport,
  );

  Future<SourceHealthCheckResult> check(
    RegisteredBookSource source, {
    SourceRuntime? runtime,
  }) async {
    if (source.sourceProtocol != BookSourceProtocolKind.readingSource) {
      throw const BookSourceProtocolException(
        'Health checks only support compatible reading sources.',
      );
    }
    final owned = runtime == null;
    final engine = runtime ?? SourceRuntime(transport: _transport);
    final checked = <SourceHealthCapability>{};
    final failed = <SourceHealthCapability>{};
    final stopwatch = Stopwatch()..start();
    var timedOut = false;
    try {
      await _runChecks(engine, source, checked, failed).timeout(timeout);
    } on TimeoutException {
      timedOut = true;
    } finally {
      stopwatch.stop();
      if (owned) engine.close();
    }
    return SourceHealthCheckResult(
      checked: Set.unmodifiable(checked),
      failed: Set.unmodifiable(failed),
      checkedAt: DateTime.now().toUtc(),
      respondTimeMs: timedOut ? null : stopwatch.elapsedMilliseconds,
      timedOut: timedOut,
    );
  }

  Future<void> _runChecks(
    SourceRuntime engine,
    RegisteredBookSource source,
    Set<SourceHealthCapability> checked,
    Set<SourceHealthCapability> failed,
  ) async {
    BookSourceBook? candidate;

    if (source.capabilities.contains('search')) {
      checked.add(SourceHealthCapability.search);
      try {
        final page = await engine.search(source, keyword, pageSize: 5);
        candidate = page.items.firstWhere(
          (book) => book.id.trim().isNotEmpty && book.title.trim().isNotEmpty,
        );
      } on Object {
        failed.add(SourceHealthCapability.search);
      }
    }

    if (source.capabilities.contains('browse')) {
      checked.add(SourceHealthCapability.discover);
      try {
        final categories = await engine.getExploreCategories(source);
        final page = await engine.browse(
          source,
          category: categories.first.id,
          pageSize: 5,
        );
        final hit = page.items.firstWhere(
          (book) => book.id.trim().isNotEmpty && book.title.trim().isNotEmpty,
        );
        candidate ??= hit;
      } on Object {
        failed.add(SourceHealthCapability.discover);
      }
    }

    if (candidate == null) return;

    checked.add(SourceHealthCapability.info);
    final BookSourceBook book;
    try {
      book = await engine.getBook(
        source,
        candidate.id,
        sourceVariables: candidate.sourceVariables,
      );
    } on Object {
      failed.add(SourceHealthCapability.info);
      return;
    }

    checked.add(SourceHealthCapability.catalog);
    final List<BookSourceChapter> chapters;
    try {
      chapters = await engine.getChapters(
        source,
        book.id,
        sourceVariables: book.sourceVariables,
      );
      if (chapters.isEmpty) throw const BookSourceProtocolException('empty');
    } on Object {
      failed.add(SourceHealthCapability.catalog);
      return;
    }

    checked.add(SourceHealthCapability.content);
    try {
      final content = await engine.getChapterContent(
        source,
        bookId: book.id,
        chapterId: chapters.first.id,
        sourceVariables: book.sourceVariables,
      );
      if (content.content.trim().isEmpty && content.images.isEmpty) {
        throw const BookSourceProtocolException('empty');
      }
    } on Object {
      failed.add(SourceHealthCapability.content);
    }
  }
}

Set<SourceHealthCapability> _capabilitiesFromJson(Object? value) {
  if (value is! List) return const {};
  final result = <SourceHealthCapability>{};
  for (final item in value) {
    for (final capability in SourceHealthCapability.values) {
      if (capability.name == item) result.add(capability);
    }
  }
  return Set.unmodifiable(result);
}
