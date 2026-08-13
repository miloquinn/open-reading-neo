import 'dart:convert';

import 'book_source_dedupe_models.dart';

class BookSourceQualityScore implements Comparable<BookSourceQualityScore> {
  const BookSourceQualityScore({
    required this.referencePriority,
    required this.healthPriority,
    required this.capabilityCount,
    required this.compatibilityRank,
    required this.completeRuleGroups,
    required this.enabledPriority,
    required this.lastUpdateTime,
    required this.nonEmptyFields,
  });

  factory BookSourceQualityScore.fromCandidate(
    BookSourceDedupeCandidate candidate,
  ) {
    final raw = candidate.rawConfig;
    return BookSourceQualityScore(
      referencePriority: candidate.isInstalled && candidate.isReferenced
          ? 1
          : 0,
      healthPriority: candidate.isHealthy ? 1 : 0,
      capabilityCount: candidate.runnableCapabilities,
      compatibilityRank: candidate.compatibilityRank,
      completeRuleGroups: _ruleNames
          .where((name) => _isNonEmpty(raw[name]))
          .length,
      enabledPriority: raw['enabled'] == false ? 0 : 1,
      lastUpdateTime: _asInt(raw['lastUpdateTime']),
      nonEmptyFields: raw.values.where(_isNonEmpty).length,
    );
  }

  final int referencePriority;
  final int healthPriority;
  final int capabilityCount;
  final int compatibilityRank;
  final int completeRuleGroups;
  final int enabledPriority;
  final int lastUpdateTime;
  final int nonEmptyFields;

  List<String> advantagesOver(BookSourceQualityScore other) {
    final reasons = <String>[];
    if (referencePriority > other.referencePriority) {
      reasons.add('referenced installed source');
    }
    if (healthPriority > other.healthPriority) {
      reasons.add('verified healthy');
    }
    if (capabilityCount > other.capabilityCount) {
      reasons.add('more runnable capabilities');
    }
    if (compatibilityRank > other.compatibilityRank) {
      reasons.add('higher compatibility');
    }
    if (completeRuleGroups > other.completeRuleGroups) {
      reasons.add('more complete rule groups');
    }
    if (enabledPriority > other.enabledPriority) {
      reasons.add('enabled');
    }
    if (lastUpdateTime > other.lastUpdateTime) {
      reasons.add('newer update');
    }
    if (nonEmptyFields > other.nonEmptyFields) {
      reasons.add('more non-empty fields');
    }
    return List.unmodifiable(reasons);
  }

  @override
  int compareTo(BookSourceQualityScore other) {
    for (final comparison in [
      referencePriority.compareTo(other.referencePriority),
      healthPriority.compareTo(other.healthPriority),
      capabilityCount.compareTo(other.capabilityCount),
      compatibilityRank.compareTo(other.compatibilityRank),
      completeRuleGroups.compareTo(other.completeRuleGroups),
      enabledPriority.compareTo(other.enabledPriority),
      lastUpdateTime.compareTo(other.lastUpdateTime),
      nonEmptyFields.compareTo(other.nonEmptyFields),
    ]) {
      if (comparison != 0) return comparison;
    }
    return 0;
  }

  static const _ruleNames = [
    'ruleSearch',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
    'ruleExplore',
  ];

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static bool _isNonEmpty(Object? value) {
    if (value == null) return false;
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return false;
      if (text.startsWith('{')) {
        try {
          return _isNonEmpty(jsonDecode(text));
        } on FormatException {
          return false;
        }
      }
      return true;
    }
    if (value is Map) return value.values.any(_isNonEmpty);
    if (value is Iterable) return value.any(_isNonEmpty);
    return true;
  }
}
