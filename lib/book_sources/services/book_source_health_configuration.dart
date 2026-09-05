import 'package:flutter/foundation.dart';

import '../models/registered_book_source.dart';

@immutable
class BookSourceHealthMergeResult {
  const BookSourceHealthMergeResult({
    required this.sources,
    required this.mergedSourceIds,
  });

  final List<RegisteredBookSource> sources;
  final Set<String> mergedSourceIds;
}

class BookSourceHealthMergePersistenceException implements Exception {
  const BookSourceHealthMergePersistenceException({
    required this.cause,
    required this.unpersistedSourceIds,
  });

  final Object cause;
  final Set<String> unpersistedSourceIds;

  @override
  String toString() => 'BookSourceHealthMergePersistenceException: $cause';
}

const _nonOperationalFields = {
  '_openReadingHealthCheck',
  '_openReadingCompatibility',
  'bookSourceName',
  'bookSourceGroup',
  'bookSourceComment',
  'bookSourceDescription',
  'bookSourceIcon',
  'enabled',
  'customOrder',
  'lastUpdateTime',
  'respondTime',
  'exploreScreen',
};

/// Whether a stored health result was produced by the same request and rule
/// configuration as [current]. User-owned labels and presentation metadata do
/// not invalidate a check, while URL, header, script, rule, protocol, and
/// runnable-capability changes do.
bool sameBookSourceHealthCheckConfiguration(
  RegisteredBookSource current,
  RegisteredBookSource checked,
) {
  if (current.sourceProtocol != checked.sourceProtocol ||
      current.manifestUrl != checked.manifestUrl ||
      current.apiBaseUrl != checked.apiBaseUrl ||
      !setEquals(current.capabilities, checked.capabilities)) {
    return false;
  }
  return _deepJsonEquals(
    _operationalSourceConfig(current.sourceConfig),
    _operationalSourceConfig(checked.sourceConfig),
  );
}

Map<String, dynamic> _operationalSourceConfig(Map<String, dynamic>? config) {
  if (config == null) return const {};
  return Map.fromEntries(
    config.entries.where(
      (entry) =>
          !_nonOperationalFields.contains(entry.key) &&
          !entry.key.startsWith('_openReading'),
    ),
  );
}

bool _deepJsonEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepJsonEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepJsonEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
