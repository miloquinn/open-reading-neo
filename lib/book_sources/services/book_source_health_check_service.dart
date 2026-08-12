import '../models/registered_book_source.dart';
import '../source_engine/source_health_checker.dart';
import 'book_source_registry.dart';

typedef SourceHealthCheckProgress = void Function(int completed, int total);

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
    if (updated.isNotEmpty) await _registry.upsertAll(updated);
    return List.unmodifiable(updated);
  }

  /// Checks and persists a single source, returning its updated copy.
  Future<RegisteredBookSource> checkOne(RegisteredBookSource source) async {
    final result = await _checker.check(source);
    final updated = withSourceHealthCheckResult(source, result);
    await _registry.upsert(updated);
    return updated;
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
  }) async {
    final now = DateTime.now().toUtc();
    final targets = <RegisteredBookSource>[];
    final skipped = <RegisteredBookSource>[];
    for (final source in sources) {
      if (source.sourceProtocol != BookSourceProtocolKind.readingSource) {
        skipped.add(source);
        continue;
      }
      final previous = sourceHealthCheckResultOf(source);
      final freshEnough =
          previous != null &&
          previous.fullyAvailable &&
          now.difference(previous.checkedAt) < cleanupRecheckWindow;
      (freshEnough ? skipped : targets).add(source);
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
          checkedOk.add(withSourceHealthCheckResult(source, result));
        } on Object {
          // Leave this source's previously stored health state untouched.
          unchanged.add(source);
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
    if (checkedOk.isNotEmpty) await _registry.upsertAll(checkedOk);
    return List.unmodifiable([...skipped, ...checkedOk, ...unchanged]);
  }
}
