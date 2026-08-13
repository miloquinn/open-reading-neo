import 'book_source_dedupe_models.dart';
import 'book_source_quality_score.dart';

class BookSourceDedupeEngine {
  const BookSourceDedupeEngine();

  BookSourceDedupeResult analyze(
    Iterable<BookSourceDedupeCandidate> input, {
    BookSourceDedupeMode mode = BookSourceDedupeMode.standard,
  }) {
    final candidates = input.toList(growable: false);
    final buckets = <String, List<BookSourceDedupeCandidate>>{};
    for (final candidate in candidates) {
      final key = _key(candidate, mode);
      buckets.putIfAbsent(key, () => []).add(candidate);
    }

    final selected = candidates.map((candidate) => candidate.index).toSet();
    final groups = <BookSourceDedupeGroup>[];
    for (final entry in buckets.entries) {
      if (entry.value.length < 2) continue;
      final members = List<BookSourceDedupeCandidate>.of(entry.value);
      final winner = _best(members);
      final confidence = _confidence(members, mode);
      final retainAll =
          confidence == BookSourceDedupeConfidence.sameSite ||
          confidence == BookSourceDedupeConfidence.conflict;
      final groupSelection = retainAll
          ? members.map((candidate) => candidate.index).toSet()
          : <int>{winner.index};
      if (!retainAll) {
        selected.removeAll(members.map((candidate) => candidate.index));
        selected.add(winner.index);
      }
      groups.add(
        BookSourceDedupeGroup(
          key: entry.key,
          confidence: confidence,
          candidates: members,
          recommendedIndex: winner.index,
          defaultSelectedIndices: groupSelection,
          reason: _reason(confidence),
        ),
      );
    }

    groups.sort((left, right) {
      final leftIndex = left.candidates.first.index;
      final rightIndex = right.candidates.first.index;
      return leftIndex.compareTo(rightIndex);
    });
    return BookSourceDedupeResult(
      mode: mode,
      candidates: candidates,
      groups: groups,
      defaultSelectedIndices: selected,
    );
  }

  String _key(BookSourceDedupeCandidate candidate, BookSourceDedupeMode mode) {
    final identity = candidate.identity;
    return switch (mode) {
      BookSourceDedupeMode.exact => identity.exactKey,
      BookSourceDedupeMode.standard => identity.canonicalKey,
      BookSourceDedupeMode.siteReview =>
        identity.isHttp ? identity.siteKey : identity.exactKey,
    };
  }

  BookSourceDedupeCandidate _best(List<BookSourceDedupeCandidate> candidates) {
    var best = candidates.first;
    var bestScore = BookSourceQualityScore.fromCandidate(best);
    for (final candidate in candidates.skip(1)) {
      final score = BookSourceQualityScore.fromCandidate(candidate);
      final qualityOrder = score.compareTo(bestScore);
      if (qualityOrder > 0 ||
          (qualityOrder == 0 && candidate.isInstalled && !best.isInstalled) ||
          (qualityOrder == 0 &&
              candidate.isInstalled == best.isInstalled &&
              candidate.index > best.index)) {
        best = candidate;
        bestScore = score;
      }
    }
    return best;
  }

  BookSourceDedupeConfidence _confidence(
    List<BookSourceDedupeCandidate> candidates,
    BookSourceDedupeMode mode,
  ) {
    if (candidates.map((candidate) => candidate.protocol).toSet().length > 1) {
      return BookSourceDedupeConfidence.conflict;
    }
    if (mode == BookSourceDedupeMode.siteReview) {
      final exactKeys = candidates
          .map((candidate) => candidate.identity.exactKey)
          .toSet();
      final canonicalKeys = candidates
          .map((candidate) => candidate.identity.canonicalKey)
          .toSet();
      if (exactKeys.length == 1) {
        return BookSourceDedupeConfidence.exact;
      }
      if (canonicalKeys.length == 1) {
        return BookSourceDedupeConfidence.canonical;
      }
      return BookSourceDedupeConfidence.sameSite;
    }
    if (candidates
            .map((candidate) => candidate.identity.exactKey)
            .toSet()
            .length ==
        1) {
      return BookSourceDedupeConfidence.exact;
    }
    return BookSourceDedupeConfidence.canonical;
  }

  String _reason(BookSourceDedupeConfidence confidence) => switch (confidence) {
    BookSourceDedupeConfidence.exact =>
      'Trimmed source identities are identical.',
    BookSourceDedupeConfidence.canonical =>
      'Canonical HTTP identities are identical after safe normalization.',
    BookSourceDedupeConfidence.sameSite =>
      'Sources share a host and port but may differ by path, query, or tag.',
    BookSourceDedupeConfidence.conflict =>
      'Matching identities cross protocol boundaries and require review.',
  };
}
