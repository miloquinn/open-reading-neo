enum ReadingProgressEventRelation {
  same,
  incomingDominates,
  currentDominates,
  concurrent,
  unknown,
}

String? readingProgressEventId(Object? event) {
  if (event is! Map) return null;
  final value = event['event_id'];
  return value is String && value.isNotEmpty ? value : null;
}

Map<String, int>? readingProgressEventVector(Object? event) {
  if (event is! Map || event['vector'] is! Map) return null;
  final result = <String, int>{};
  for (final entry in (event['vector'] as Map).entries) {
    if (entry.key is! String || entry.key.toString().isEmpty) return null;
    final value = entry.value;
    if (value is! num || value.toInt() < 0) return null;
    result[entry.key as String] = value.toInt();
  }
  return result.isEmpty ? null : result;
}

ReadingProgressEventRelation compareReadingProgressEvents(
  Object? current,
  Object? incoming,
) {
  final currentId = readingProgressEventId(current);
  final incomingId = readingProgressEventId(incoming);
  if (currentId != null && currentId == incomingId) {
    return ReadingProgressEventRelation.same;
  }
  final currentVector = readingProgressEventVector(current);
  final incomingVector = readingProgressEventVector(incoming);
  if (currentVector == null || incomingVector == null) {
    return ReadingProgressEventRelation.unknown;
  }
  var currentGreater = false;
  var incomingGreater = false;
  for (final deviceId in {...currentVector.keys, ...incomingVector.keys}) {
    final currentSequence = currentVector[deviceId] ?? 0;
    final incomingSequence = incomingVector[deviceId] ?? 0;
    currentGreater |= currentSequence > incomingSequence;
    incomingGreater |= incomingSequence > currentSequence;
  }
  if (!currentGreater && !incomingGreater) {
    return currentId != null && incomingId != null
        ? ReadingProgressEventRelation.concurrent
        : ReadingProgressEventRelation.unknown;
  }
  if (incomingGreater && !currentGreater) {
    return ReadingProgressEventRelation.incomingDominates;
  }
  if (currentGreater && !incomingGreater) {
    return ReadingProgressEventRelation.currentDominates;
  }
  return ReadingProgressEventRelation.concurrent;
}

String readingProgressCandidateKey(String bookUid, String eventId) =>
    'progress_candidate:$bookUid:$eventId';

String readingProgressCandidateId(Object? event) {
  final eventId = readingProgressEventId(event) ?? 'legacy';
  if (event is! Map) return eventId;
  final revision = event['locator_revision'];
  return revision is String && revision.isNotEmpty
      ? '$eventId@$revision'
      : eventId;
}
