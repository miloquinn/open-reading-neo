import 'package:flutter/foundation.dart';

import '../models/registered_book_source.dart';
import '../source_engine/source_health_checker.dart';

enum BookSourceMaintenanceClassification {
  available,
  limited,
  failed,
  timedOut,
  unchecked,
}

@immutable
class BookSourceMaintenanceAssessment {
  const BookSourceMaintenanceAssessment({
    required this.source,
    required this.classification,
    this.healthResult,
    this.error,
  });

  final RegisteredBookSource source;
  final BookSourceMaintenanceClassification classification;
  final SourceHealthCheckResult? healthResult;
  final Object? error;

  bool get needsAttention =>
      classification != BookSourceMaintenanceClassification.available;
}

BookSourceMaintenanceAssessment bookSourceMaintenanceAssessment(
  RegisteredBookSource source, {
  Object? error,
}) {
  final result = sourceHealthCheckResultOf(source);
  if (error != null || result == null) {
    return BookSourceMaintenanceAssessment(
      source: source,
      classification: BookSourceMaintenanceClassification.unchecked,
      healthResult: result,
      error: error,
    );
  }
  if (result.timedOut) {
    return BookSourceMaintenanceAssessment(
      source: source,
      classification: BookSourceMaintenanceClassification.timedOut,
      healthResult: result,
    );
  }
  if (result.fullyAvailable) {
    return BookSourceMaintenanceAssessment(
      source: source,
      classification: BookSourceMaintenanceClassification.available,
      healthResult: result,
    );
  }

  const readingChain = {
    SourceHealthCapability.info,
    SourceHealthCapability.catalog,
    SourceHealthCapability.content,
  };
  final readingChainFailed = result.failed.any(readingChain.contains);
  final everyAttemptFailed =
      result.checked.isNotEmpty && result.failed.containsAll(result.checked);
  return BookSourceMaintenanceAssessment(
    source: source,
    classification: readingChainFailed || everyAttemptFailed
        ? BookSourceMaintenanceClassification.failed
        : BookSourceMaintenanceClassification.limited,
    healthResult: result,
  );
}
