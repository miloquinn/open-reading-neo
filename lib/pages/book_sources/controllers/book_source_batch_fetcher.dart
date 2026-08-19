import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';

/// Concurrent per-source fetch with a bounded worker pool.
///
/// Successful batches keep source order. Failed sources are dropped when any
/// other source returned items; if every batch is empty and at least one
/// source failed, the joined errors are thrown as [BookSourceProtocolException].
class BookSourceBatchFetcher {
  const BookSourceBatchFetcher({required this.maxConcurrent});

  final int maxConcurrent;

  Future<List<List<T>>> fetch<T>(
    List<RegisteredBookSource> sources,
    Future<List<T>> Function(RegisteredBookSource source) fetch,
  ) async {
    if (sources.isEmpty) return const [];
    final results = List<_SourceFetchResult<T>?>.filled(sources.length, null);
    var nextIndex = 0;
    Future<void> worker() async {
      while (nextIndex < sources.length) {
        final index = nextIndex++;
        final source = sources[index];
        try {
          results[index] = _SourceFetchResult.success(
            source,
            await fetch(source),
          );
        } catch (error) {
          results[index] = _SourceFetchResult.failure(source, error);
        }
      }
    }

    await Future.wait(
      List.generate(sources.length.clamp(1, maxConcurrent), (_) => worker()),
    );
    final completed = results.whereType<_SourceFetchResult<T>>().toList(
      growable: false,
    );
    final batches = completed
        .where((result) => result.error == null)
        .map((result) => result.items)
        .toList(growable: false);
    final failures = completed.where((result) => result.error != null).toList();
    if (!batches.any((items) => items.isNotEmpty) && failures.isNotEmpty) {
      throw BookSourceProtocolException(
        failures
            .map((failure) => '${failure.source.name}: ${failure.error}')
            .join('\n'),
      );
    }
    return batches;
  }
}

/// Keep each source's latest order, then interleave one item per source.
///
/// The first round prefers sources whose head item is newer; later rounds
/// still contribute at most one book per source so a single catalog cannot
/// fill the aggregated list.
List<SourcedBook> mergeLatestSourceBatches(
  Iterable<List<SourcedBook>> batches, {
  required int maxItemsPerSource,
}) {
  if (maxItemsPerSource <= 0) return const [];
  final queues = batches
      .where((batch) => batch.isNotEmpty)
      .map((batch) => batch.take(maxItemsPerSource).toList(growable: false))
      .toList();
  queues.sort((left, right) {
    final leftTime = left.first.book.updatedAt;
    final rightTime = right.first.book.updatedAt;
    if (leftTime != null && rightTime != null) {
      final byTime = rightTime.compareTo(leftTime);
      if (byTime != 0) return byTime;
    } else if (leftTime != null) {
      return -1;
    } else if (rightTime != null) {
      return 1;
    }
    return left.first.source.name.compareTo(right.first.source.name);
  });

  final results = <SourcedBook>[];
  for (var index = 0; index < maxItemsPerSource; index++) {
    var added = false;
    for (final queue in queues) {
      if (index >= queue.length) continue;
      results.add(queue[index]);
      added = true;
    }
    if (!added) break;
  }
  return results;
}

class _SourceFetchResult<T> {
  final RegisteredBookSource source;
  final List<T> items;
  final Object? error;

  const _SourceFetchResult.success(this.source, this.items) : error = null;

  const _SourceFetchResult.failure(this.source, this.error) : items = const [];
}
