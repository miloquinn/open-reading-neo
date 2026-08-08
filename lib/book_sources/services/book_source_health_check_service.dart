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
}
