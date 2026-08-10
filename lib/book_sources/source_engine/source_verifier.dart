import '../models/registered_book_source.dart';
import 'source_config.dart';
import 'source_http_transport.dart';
import 'source_runtime.dart';

typedef SourceVerificationProgress =
    void Function(int completed, int total, int available);
typedef SourceProbe =
    Future<bool> Function(RegisteredBookSource source, String query);

class SourceVerificationResult {
  const SourceVerificationResult({
    required this.available,
    required this.rejected,
  });

  final List<RegisteredBookSource> available;
  final int rejected;
}

class SourceVerifier {
  SourceVerifier({
    SourceRuntime? runtime,
    this._sourceProbe,
    this.maxConcurrency = 12,
    this.maxCandidates = 120,
    this.maxAvailable = 30,
    this.queries = const ['斗破苍穹'],
  }) : _runtime =
           runtime ??
           SourceRuntime(
             transport: SourceHttpTransport(
               requestTimeout: const Duration(seconds: 4),
             ),
           );

  final SourceRuntime _runtime;
  final SourceProbe? _sourceProbe;
  final int maxConcurrency;
  final int maxCandidates;
  final int maxAvailable;
  final List<String> queries;

  void close() => _runtime.close();

  Future<SourceVerificationResult> verify(
    Iterable<ReadingSourceConfig> imported, {
    SourceVerificationProgress? onProgress,
  }) async {
    final ranked = imported
        .where(
          (source) => const SourceCompatibilityScanner().scan(source).canRun,
        )
        .toList();
    ranked.sort((left, right) {
      final updated = right.lastUpdateTime.compareTo(left.lastUpdateTime);
      if (updated != 0) return updated;
      final leftResponse = left.respondTime <= 0 ? 1 << 30 : left.respondTime;
      final rightResponse = right.respondTime <= 0
          ? 1 << 30
          : right.respondTime;
      return leftResponse.compareTo(rightResponse);
    });
    final candidates = <ReadingSourceConfig>[];
    final hosts = <String>{};
    for (final source in ranked) {
      if (!hosts.add(source.baseUri.host)) continue;
      candidates.add(source);
      if (candidates.length >= maxCandidates) break;
    }
    final available = <RegisteredBookSource>[];
    var next = 0;
    var completed = 0;

    Future<void> worker() async {
      while (true) {
        if (available.length >= maxAvailable) return;
        final index = next++;
        if (index >= candidates.length) return;
        final source = candidates[index];
        if (await _hasWorkingSearch(source)) {
          if (available.length < maxAvailable) {
            available.add(
              source.toRegisteredSource(
                enabled: true,
                readingChainVerified: true,
              ),
            );
          }
        }
        completed++;
        onProgress?.call(completed, candidates.length, available.length);
      }
    }

    final workers = List.generate(
      candidates.length.clamp(0, maxConcurrency),
      (_) => worker(),
    );
    await Future.wait(workers);
    available.sort((left, right) => left.name.compareTo(right.name));
    return SourceVerificationResult(
      available: List.unmodifiable(available),
      rejected: imported.length - available.length,
    );
  }

  Future<bool> _hasWorkingSearch(ReadingSourceConfig source) async {
    final registered = source.toRegisteredSource();
    for (final query in queries) {
      try {
        final probe = _sourceProbe;
        if (probe != null) {
          if (await probe(registered, query)) return true;
          continue;
        }
        final result = await _runtime.search(registered, query, pageSize: 5);
        final match = result.items.firstWhere(
          (book) => book.id.trim().isNotEmpty && book.title.trim().isNotEmpty,
        );
        final book = await _runtime.getBook(
          registered,
          match.id,
          sourceVariables: match.sourceVariables,
        );
        final chapters = await _runtime.getChapters(
          registered,
          book.id,
          sourceVariables: book.sourceVariables,
        );
        if (chapters.isEmpty) continue;
        final content = await _runtime.getChapterContent(
          registered,
          bookId: book.id,
          chapterId: chapters.first.id,
          sourceVariables: book.sourceVariables,
        );
        if (content.content.trim().isNotEmpty || content.images.isNotEmpty) {
          return true;
        }
      } catch (_) {
        // Try the next neutral probe query. Failed sources are discarded.
      }
    }
    return false;
  }
}
