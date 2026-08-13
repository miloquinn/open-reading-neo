import 'dart:collection';

import 'book_source_identity.dart';

enum BookSourceDedupeMode { exact, standard, siteReview }

enum BookSourceDedupeConfidence { exact, canonical, sameSite, conflict }

class BookSourceDedupeCandidate {
  BookSourceDedupeCandidate({
    required this.index,
    required Map<String, dynamic> rawConfig,
    this.provenance,
    this.installedSourceId,
    this.protocol = 'reading',
    this.isReferenced = false,
    this.isHealthy = false,
    this.compatibilityRank = 0,
    this.runnableCapabilities = 0,
  }) : rawConfig = _immutableMap(rawConfig),
       identity = BookSourceIdentity.parse(
         '${rawConfig['bookSourceUrl'] ?? ''}',
       );

  final int index;
  final Map<String, dynamic> rawConfig;
  final Object? provenance;
  final String? installedSourceId;
  final String protocol;
  final bool isReferenced;
  final bool isHealthy;
  final int compatibilityRank;
  final int runnableCapabilities;
  final BookSourceIdentity identity;

  String get name => '${rawConfig['bookSourceName'] ?? ''}'.trim();
  bool get isInstalled => installedSourceId != null;
}

Map<String, dynamic> _immutableMap(Map<String, dynamic> source) {
  return UnmodifiableMapView(
    source.map((key, value) => MapEntry(key, _immutableValue(value))),
  );
}

Object? _immutableValue(Object? value) {
  if (value is Map) {
    return UnmodifiableMapView(
      value.map((key, item) => MapEntry(key, _immutableValue(item))),
    );
  }
  if (value is List) {
    return List.unmodifiable(value.map(_immutableValue));
  }
  if (value is Set) {
    return Set.unmodifiable(value.map(_immutableValue));
  }
  return value;
}

class BookSourceDedupeGroup {
  BookSourceDedupeGroup({
    required this.key,
    required this.confidence,
    required List<BookSourceDedupeCandidate> candidates,
    required this.recommendedIndex,
    required Set<int> defaultSelectedIndices,
    required this.reason,
  }) : candidates = List.unmodifiable(candidates),
       defaultSelectedIndices = Set.unmodifiable(defaultSelectedIndices);

  final String key;
  final BookSourceDedupeConfidence confidence;
  final List<BookSourceDedupeCandidate> candidates;
  final int recommendedIndex;
  final Set<int> defaultSelectedIndices;
  final String reason;

  bool get requiresReview =>
      confidence == BookSourceDedupeConfidence.sameSite ||
      confidence == BookSourceDedupeConfidence.conflict;
}

class BookSourceDedupeResult {
  BookSourceDedupeResult({
    required this.mode,
    required List<BookSourceDedupeCandidate> candidates,
    required List<BookSourceDedupeGroup> groups,
    required Set<int> defaultSelectedIndices,
  }) : candidates = List.unmodifiable(candidates),
       groups = List.unmodifiable(groups),
       defaultSelectedIndices = Set.unmodifiable(defaultSelectedIndices);

  final BookSourceDedupeMode mode;
  final List<BookSourceDedupeCandidate> candidates;
  final List<BookSourceDedupeGroup> groups;
  final Set<int> defaultSelectedIndices;

  int get duplicateCandidateCount =>
      groups.fold(0, (total, group) => total + group.candidates.length - 1);
}
