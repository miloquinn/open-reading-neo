import '../models/registered_book_source.dart';
import '../source_engine/source_health_checker.dart';
import 'book_source_registry.dart';

typedef SourceHealthCheckProgress = void Function(int completed, int total);
typedef SourceHealthCheckItemCompleted =
    void Function(RegisteredBookSource source);
typedef SourceHealthCheckItemError =
    void Function(
      RegisteredBookSource source,
      Object error,
      StackTrace stackTrace,
    );

class SourceHealthCheckConfigurationChangedException implements Exception {
  const SourceHealthCheckConfigurationChangedException(
    this.sourceId, {
    this.sourceWasRemoved = false,
  });

  final String sourceId;
  final bool sourceWasRemoved;

  @override
  String toString() =>
      'SourceHealthCheckConfigurationChangedException: $sourceId';
}

class SourceHealthCheckPersistenceException implements Exception {
  const SourceHealthCheckPersistenceException({
    required this.cause,
    required this.unpersistedSourceIds,
  });

  final Object cause;
  final Set<String> unpersistedSourceIds;

  @override
  String toString() => 'SourceHealthCheckPersistenceException: $cause';
}

/// Batches [SourceHealthChecker] runs across already-added sources and
/// persists the results through [BookSourceRegistry] — the engine-level
/// checker stays free of storage concerns, this is where that gets wired up.
class BookSourceHealthCheckService {
  BookSourceHealthCheckService({
    this._checker = const SourceHealthChecker(),
    BookSourceRegistry? registry,
    this.maxConcurrency = 4,
  }) : _registry = registry ?? BookSourceRegistry();

  /// Applied instead of the constructor's checker during [checkAllForCleanup]
  /// sweeps: broken sources should fail fast rather than each claim a full
  /// share of the timeout budget across a large source library.
  static const Duration cleanupTimeout = Duration(seconds: 8);
  static const int cleanupConcurrency = 16;

  /// A source that was fully available this recently is skipped by
  /// [checkAllForCleanup] rather than re-checked.
  static const Duration cleanupRecheckWindow = Duration(hours: 24);

  final SourceHealthChecker _checker;
  final BookSourceRegistry _registry;
  final int maxConcurrency;

  /// Checks [sources] (non-`readingSource` entries are skipped) and persists
  /// every completed result in one write. Returns the updated copies, in no
  /// particular order, so callers can refresh their view without a reload.
  Future<List<RegisteredBookSource>> checkAll(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
  }) async {
    final targets = sources
        .where(
          (source) =>
              source.sourceProtocol == BookSourceProtocolKind.readingSource,
        )
        .toList(growable: false);
    final updated = <RegisteredBookSource>[];
    var next = 0;
    var completed = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= targets.length) return;
        final source = targets[index];
        try {
          final result = await _checker.check(source);
          updated.add(withSourceHealthCheckResult(source, result));
        } on Object {
          // Leave this source's previously stored health state untouched.
        }
        completed++;
        onProgress?.call(completed, targets.length);
      }
    }

    await Future.wait(
      List.generate(targets.length.clamp(0, maxConcurrency), (_) => worker()),
    );
    if (updated.isEmpty) return const [];
    final merge = await _registry.mergeHealthCheckResults(updated);
    final currentById = {for (final source in merge.sources) source.id: source};
    final currentTargets = <RegisteredBookSource>[];
    for (final source in updated) {
      final current = currentById[source.id];
      if (current != null) currentTargets.add(current);
    }
    return List.unmodifiable(currentTargets);
  }

  /// Checks and persists a single source, returning its updated copy.
  Future<RegisteredBookSource> checkOne(RegisteredBookSource source) async {
    final result = await _checker.check(source);
    final updated = withSourceHealthCheckResult(source, result);
    final merge = await _registry.mergeHealthCheckResults([updated]);
    return merge.sources.firstWhere(
      (current) => current.id == source.id,
      orElse: () => throw StateError(
        'The source was removed while its health check was running.',
      ),
    );
  }

  /// A faster, cleanup-oriented sweep across [sources]: a shorter per-source
  /// timeout and higher concurrency than [checkAll], and skips sources whose
  /// most recent result is already fully available within
  /// [cleanupRecheckWindow] — so re-running this after a first pass only
  /// re-tests what's new or still broken. Non-`readingSource` entries (which
  /// [SourceHealthChecker] cannot check) are returned untouched.
  ///
  /// Returns every source in [sources] that either was skipped or actually
  /// got checked before [isCancelled] (if given) started reporting true —
  /// each carrying its current (possibly just-refreshed) health result, so
  /// callers don't need to merge a partial result set back into their own
  /// view. A source library can run into the thousands, so callers should
  /// always offer a way to cancel rather than block until every source is
  /// done; whatever was already checked is still persisted and returned.
  Future<List<RegisteredBookSource>> checkAllForCleanup(
    List<RegisteredBookSource> sources, {
    SourceHealthCheckProgress? onProgress,
    bool Function()? isCancelled,
    SourceHealthCheckItemCompleted? onItemCompleted,
    SourceHealthCheckItemError? onItemError,
  }) async {
    final now = DateTime.now().toUtc();
    final targets = <RegisteredBookSource>[];
    final skipped = <RegisteredBookSource>[];
    for (final source in sources) {
      if (source.sourceProtocol != BookSourceProtocolKind.readingSource) {
        skipped.add(source);
        onItemCompleted?.call(source);
        continue;
      }
      final previous = sourceHealthCheckResultOf(source);
      final freshEnough =
          previous != null &&
          previous.fullyAvailable &&
          now.difference(previous.checkedAt) < cleanupRecheckWindow;
      if (freshEnough) {
        skipped.add(source);
        onItemCompleted?.call(source);
      } else {
        targets.add(source);
      }
    }

    final checker = _checker.withTimeout(cleanupTimeout);
    final checkedOk = <RegisteredBookSource>[];
    final unchanged = <RegisteredBookSource>[];
    var next = 0;
    var completed = skipped.length;
    onProgress?.call(completed, sources.length);

    Future<void> worker() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final index = next++;
        if (index >= targets.length) return;
        final source = targets[index];
        try {
          final result = await checker.check(source);
          final updated = withSourceHealthCheckResult(source, result);
          checkedOk.add(updated);
          onItemCompleted?.call(updated);
        } on Object catch (error, stackTrace) {
          // Leave this source's previously stored health state untouched.
          unchanged.add(source);
          onItemError?.call(source, error, stackTrace);
        }
        completed++;
        onProgress?.call(completed, sources.length);
      }
    }

    await Future.wait(
      List.generate(
        targets.length.clamp(0, cleanupConcurrency),
        (_) => worker(),
      ),
    );
    final cached = skipped.where(
      (source) =>
          source.sourceProtocol == BookSourceProtocolKind.readingSource &&
          sourceHealthCheckResultOf(source) != null,
    );
    final healthCandidates = [...cached, ...checkedOk];
    final healthCandidateIds = healthCandidates
        .map((source) => source.id)
        .toSet();
    final checkedIds = checkedOk.map((source) => source.id).toSet();
    final BookSourceHealthMergeResult merge;
    try {
      merge = await _registry.mergeHealthCheckResults(
        healthCandidates,
        persistSourceIds: checkedIds,
      );
    } on BookSourceHealthMergePersistenceException catch (error) {
      throw SourceHealthCheckPersistenceException(
        cause: error.cause,
        unpersistedSourceIds: error.unpersistedSourceIds,
      );
    } on Object catch (error) {
      if (checkedIds.isNotEmpty) {
        throw SourceHealthCheckPersistenceException(
          cause: error,
          unpersistedSourceIds: Set.unmodifiable(checkedIds),
        );
      }
      rethrow;
    }
    final currentById = {for (final source in merge.sources) source.id: source};
    for (final candidate in healthCandidates) {
      final current = currentById[candidate.id];
      if (merge.mergedSourceIds.contains(candidate.id) && current != null) {
        if (!checkedIds.contains(candidate.id)) {
          onItemCompleted?.call(current);
        }
        continue;
      }
      onItemError?.call(
        current ?? candidate,
        SourceHealthCheckConfigurationChangedException(
          candidate.id,
          sourceWasRemoved: current == null,
        ),
        StackTrace.empty,
      );
    }
    final completedById = <String, RegisteredBookSource>{
      for (final source in unchanged)
        source.id: currentById[source.id] ?? source,
    };
    for (final source in skipped) {
      final current = currentById[source.id];
      if (current == null) continue;
      completedById[source.id] =
          healthCandidateIds.contains(source.id) &&
              !merge.mergedSourceIds.contains(source.id)
          ? _withoutSourceHealthCheckResult(current)
          : current;
    }
    for (final checked in checkedOk) {
      final current = currentById[checked.id];
      if (current == null) continue;
      completedById[checked.id] = merge.mergedSourceIds.contains(checked.id)
          ? current
          : _withoutSourceHealthCheckResult(current);
    }
    final ordered = <RegisteredBookSource>[];
    for (final source in sources) {
      final completed = completedById[source.id];
      if (completed != null) ordered.add(completed);
    }
    return List.unmodifiable(ordered);
  }
}

RegisteredBookSource _withoutSourceHealthCheckResult(
  RegisteredBookSource source,
) {
  final config = {...?source.sourceConfig}..remove('_openReadingHealthCheck');
  return source.copyWith(sourceConfig: config);
}
