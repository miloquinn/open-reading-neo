import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/registered_book_source.dart';
import 'book_source_health_check_service.dart';
import 'book_source_maintenance_assessment.dart';
import 'book_source_registry.dart';

export 'book_source_maintenance_assessment.dart';

enum BookSourceMaintenanceStatus {
  idle,
  running,
  cancelling,
  completed,
  cancelled,
  failed,
}

@immutable
class BookSourceMaintenanceProgress {
  const BookSourceMaintenanceProgress({
    required this.completed,
    required this.total,
  });

  final int completed;
  final int total;

  double? get fraction => total == 0 ? null : completed / total;
}

@immutable
class BookSourceMaintenanceResult {
  const BookSourceMaintenanceResult({
    required this.allSources,
    required this.assessments,
    required this.remainingSources,
    this.reviewedSourceIds = const {},
  });

  const BookSourceMaintenanceResult.empty()
    : allSources = const [],
      assessments = const [],
      remainingSources = const [],
      reviewedSourceIds = const {};

  final List<RegisteredBookSource> allSources;
  final List<BookSourceMaintenanceAssessment> assessments;
  final List<RegisteredBookSource> remainingSources;
  final Set<String> reviewedSourceIds;

  List<RegisteredBookSource> get fullyAvailable => List.unmodifiable(
    assessments
        .where(
          (assessment) =>
              assessment.classification ==
              BookSourceMaintenanceClassification.available,
        )
        .map((assessment) => assessment.source),
  );

  List<RegisteredBookSource> get needsAttention => List.unmodifiable(
    assessments
        .where(
          (assessment) =>
              assessment.needsAttention &&
              assessment.source.enabled &&
              !reviewedSourceIds.contains(assessment.source.id),
        )
        .map((assessment) => assessment.source),
  );

  int get total => allSources.length;

  BookSourceMaintenanceClassification? classificationOf(String sourceId) {
    return assessmentOf(sourceId)?.classification;
  }

  BookSourceMaintenanceAssessment? assessmentOf(String sourceId) {
    for (final assessment in assessments) {
      if (assessment.source.id == sourceId) return assessment;
    }
    return null;
  }

  List<RegisteredBookSource> sourcesWithClassification(
    BookSourceMaintenanceClassification classification,
  ) => List.unmodifiable(
    assessments
        .where((assessment) => assessment.classification == classification)
        .map((assessment) => assessment.source),
  );

  BookSourceMaintenanceResult withReviewedSourceIds(Set<String> ids) =>
      BookSourceMaintenanceResult(
        allSources: allSources,
        assessments: assessments,
        remainingSources: remainingSources,
        reviewedSourceIds: Set.unmodifiable(ids),
      );
}

@immutable
class BookSourceMaintenanceState {
  const BookSourceMaintenanceState({
    this.status = BookSourceMaintenanceStatus.idle,
    this.runId = 0,
    this.progress,
    this.result,
    this.failure,
  });

  final BookSourceMaintenanceStatus status;
  final int runId;
  final BookSourceMaintenanceProgress? progress;
  final BookSourceMaintenanceResult? result;
  final Object? failure;

  bool get isRunning =>
      status == BookSourceMaintenanceStatus.running || isCancelling;
  bool get isCancelling => status == BookSourceMaintenanceStatus.cancelling;
  bool get canResume => !isRunning && remainingSources.isNotEmpty;
  List<RegisteredBookSource> get remainingSources =>
      result?.remainingSources ?? const [];
  bool get hasReviewResult =>
      result != null && result!.needsAttention.isNotEmpty;
}

/// Owns long-running source maintenance independently from the management
/// page, so hiding its progress UI or navigating elsewhere does not cancel it.
class BookSourceMaintenanceCoordinator extends ChangeNotifier {
  BookSourceMaintenanceCoordinator({
    BookSourceHealthCheckService? service,
    BookSourceRegistry? registry,
  }) : _service = service ?? BookSourceHealthCheckService(),
       _registry = registry ?? BookSourceRegistry();

  final BookSourceHealthCheckService _service;
  final BookSourceRegistry _registry;
  BookSourceMaintenanceState _state = const BookSourceMaintenanceState();
  final Map<String, RegisteredBookSource> _sourceUniverse = {};
  final Map<String, BookSourceMaintenanceAssessment> _assessments = {};
  final Set<String> _remainingIds = {};
  final Set<String> _reviewedSourceIds = {};
  int _total = 0;
  bool _cancelRequested = false;
  bool _disposed = false;
  Timer? _progressThrottleTimer;
  BookSourceMaintenanceProgress? _pendingProgress;
  Future<void>? _activeRun;

  BookSourceMaintenanceState get state => _state;

  Future<void> start(Iterable<RegisteredBookSource> sources) => begin(sources);

  Future<void> begin(Iterable<RegisteredBookSource> sources) {
    final active = _activeRun;
    if (active != null && _state.isRunning) return active;
    final targets = sources
        .where(
          (source) =>
              source.sourceProtocol == BookSourceProtocolKind.readingSource,
        )
        .toList(growable: false);
    _sourceUniverse
      ..clear()
      ..addEntries(targets.map((source) => MapEntry(source.id, source)));
    _assessments.clear();
    _remainingIds
      ..clear()
      ..addAll(_sourceUniverse.keys);
    _total = _sourceUniverse.length;
    _reviewedSourceIds.clear();
    return _launch(targets);
  }

  Future<void> resume() async {
    if (_state.isRunning || _remainingIds.isEmpty) return;
    final runId = _state.runId;
    final targets = await _loadCurrentTargets(
      _remainingIds,
      expectedRunId: runId,
    );
    if (targets == null) return;
    if (targets.isEmpty) {
      _emitCurrentSnapshot();
      return;
    }
    return _launch(targets);
  }

  Future<void> retryIssues() async {
    if (_state.isRunning) return;
    final issues = _currentResult().needsAttention
        .map((source) => source.id)
        .toSet();
    final pending = {..._remainingIds, ...issues};
    if (pending.isEmpty) return;
    final runId = _state.runId;
    final targets = await _loadCurrentTargets(
      pending,
      expectedRunId: runId,
      retryIssueIds: issues,
    );
    if (targets == null) return;
    if (targets.isEmpty) {
      _emitCurrentSnapshot();
      return;
    }
    _remainingIds.addAll(targets.map((source) => source.id));
    return _launch(targets);
  }

  Future<void> dismissReviewed(Iterable<String> ids) async {
    if (_state.isRunning || _state.result == null) return;
    final requested = ids.toSet();
    if (requested.isEmpty) return;
    final runId = _state.runId;
    final current = await _registry.load();
    if (_disposed || _state.isRunning || _state.runId != runId) return;
    final disabled = current
        .where((source) => requested.contains(source.id) && !source.enabled)
        .map((source) => source.id);
    _reviewedSourceIds.addAll(disabled);
    _emit(
      BookSourceMaintenanceState(
        status: _state.status,
        runId: _state.runId,
        progress: _state.progress,
        result: _currentResult(),
        failure: _state.failure,
      ),
    );
  }

  Future<void> _launch(List<RegisteredBookSource> targets) {
    final future = _run(targets);
    _activeRun = future;
    future.whenComplete(() {
      if (identical(_activeRun, future)) _activeRun = null;
    });
    return future;
  }

  Future<void> _run(List<RegisteredBookSource> targets) async {
    final runId = _state.runId + 1;
    _cancelRequested = false;
    final retained = _total - targets.length;
    _emit(
      BookSourceMaintenanceState(
        status: BookSourceMaintenanceStatus.running,
        runId: runId,
        progress: BookSourceMaintenanceProgress(
          completed: retained,
          total: _total,
        ),
        result: _currentResult(),
      ),
    );
    if (targets.isEmpty) {
      _finish(runId, BookSourceMaintenanceStatus.completed);
      return;
    }

    try {
      final updated = await _service.checkAllForCleanup(
        targets,
        onProgress: (completed, _) {
          if (!_isCurrent(runId)) return;
          _reportProgress(
            runId,
            BookSourceMaintenanceProgress(
              completed: retained + completed,
              total: _total,
            ),
          );
        },
        isCancelled: () => _cancelRequested || !_isCurrent(runId),
        onItemCompleted: (source) => _recordCompleted(runId, source),
        onItemError: (source, error, _) => _recordError(runId, source, error),
      );
      if (!_isCurrent(runId)) return;
      for (final source in updated) {
        final previous = _assessments[source.id];
        _assessments[source.id] = bookSourceMaintenanceAssessment(
          source,
          error: previous?.error,
        );
        _sourceUniverse[source.id] = source;
        _remainingIds.remove(source.id);
      }
      _finish(
        runId,
        _cancelRequested
            ? BookSourceMaintenanceStatus.cancelled
            : BookSourceMaintenanceStatus.completed,
      );
    } on SourceHealthCheckPersistenceException catch (error) {
      if (!_isCurrent(runId)) return;
      _remainingIds.addAll(
        error.unpersistedSourceIds.where(_sourceUniverse.containsKey),
      );
      _emitFailure(runId, error);
    } on Object catch (error) {
      if (!_isCurrent(runId)) return;
      _emitFailure(runId, error);
    }
  }

  void _emitFailure(int runId, Object error) {
    _clearPendingProgress();
    _emit(
      BookSourceMaintenanceState(
        status: BookSourceMaintenanceStatus.failed,
        runId: runId,
        progress: _actualProgress(),
        result: _currentResult(),
        failure: error,
      ),
    );
  }

  void _recordCompleted(int runId, RegisteredBookSource source) {
    if (!_isCurrent(runId)) return;
    _sourceUniverse[source.id] = source;
    _assessments[source.id] = bookSourceMaintenanceAssessment(source);
    _remainingIds.remove(source.id);
  }

  void _recordError(int runId, RegisteredBookSource source, Object error) {
    if (!_isCurrent(runId)) return;
    if (error is SourceHealthCheckConfigurationChangedException &&
        error.sourceWasRemoved) {
      _sourceUniverse.remove(source.id);
      _assessments.remove(source.id);
      _remainingIds.remove(source.id);
      _reviewedSourceIds.remove(source.id);
      return;
    }
    _sourceUniverse[source.id] = source;
    _assessments[source.id] = bookSourceMaintenanceAssessment(
      source,
      error: error,
    );
    _remainingIds.remove(source.id);
  }

  void _finish(int runId, BookSourceMaintenanceStatus status) {
    _clearPendingProgress();
    _emit(
      BookSourceMaintenanceState(
        status: status,
        runId: runId,
        progress: _actualProgress(),
        result: _currentResult(),
      ),
    );
  }

  BookSourceMaintenanceProgress _actualProgress() =>
      BookSourceMaintenanceProgress(
        completed: _total - _remainingIds.length,
        total: _total,
      );

  BookSourceMaintenanceResult _currentResult() {
    final allSources = <RegisteredBookSource>[];
    final assessments = <BookSourceMaintenanceAssessment>[];
    final remainingSources = <RegisteredBookSource>[];
    for (final entry in _sourceUniverse.entries) {
      if (_remainingIds.contains(entry.key)) {
        remainingSources.add(entry.value);
      }
      final assessment = _assessments[entry.key];
      if (assessment == null) continue;
      allSources.add(assessment.source);
      assessments.add(assessment);
    }
    return BookSourceMaintenanceResult(
      allSources: List.unmodifiable(allSources),
      assessments: List.unmodifiable(assessments),
      remainingSources: List.unmodifiable(remainingSources),
      reviewedSourceIds: Set.unmodifiable(_reviewedSourceIds),
    );
  }

  Future<List<RegisteredBookSource>?> _loadCurrentTargets(
    Set<String> ids, {
    required int expectedRunId,
    Set<String> retryIssueIds = const {},
  }) async {
    final current = await _registry.load();
    if (_disposed || _state.isRunning || _state.runId != expectedRunId) {
      return null;
    }
    final currentById = {
      for (final source in current)
        if (source.sourceProtocol == BookSourceProtocolKind.readingSource)
          source.id: source,
    };
    final targets = <RegisteredBookSource>[];
    for (final id in ids.toList(growable: false)) {
      final source = currentById[id];
      if (source == null) {
        _remainingIds.remove(id);
        _sourceUniverse.remove(id);
        _assessments.remove(id);
        _reviewedSourceIds.remove(id);
        continue;
      }
      _sourceUniverse[id] = source;
      final previous = _assessments[id];
      if (previous != null) {
        _assessments[id] = bookSourceMaintenanceAssessment(
          source,
          error: previous.error,
        );
      }
      final retryOnly =
          retryIssueIds.contains(id) && !_remainingIds.contains(id);
      if (retryOnly && !source.enabled) continue;
      targets.add(source);
    }
    return targets;
  }

  void _emitCurrentSnapshot() {
    _emit(
      BookSourceMaintenanceState(
        status: _state.status,
        runId: _state.runId,
        progress: _actualProgress(),
        result: _currentResult(),
        failure: _state.failure,
      ),
    );
  }

  void cancel() {
    if (!_state.isRunning || _state.isCancelling) return;
    _cancelRequested = true;
    _emit(
      BookSourceMaintenanceState(
        status: BookSourceMaintenanceStatus.cancelling,
        runId: _state.runId,
        progress: _state.progress,
        result: _currentResult(),
      ),
    );
  }

  void clearResult() {
    if (_state.isRunning || _state.result == null) return;
    _sourceUniverse.clear();
    _assessments.clear();
    _remainingIds.clear();
    _reviewedSourceIds.clear();
    _total = 0;
    _emit(BookSourceMaintenanceState(runId: _state.runId));
  }

  bool _isCurrent(int runId) =>
      !_disposed && _state.runId == runId && _state.isRunning;

  void _reportProgress(int runId, BookSourceMaintenanceProgress progress) {
    if (_progressThrottleTimer == null) {
      _emitProgress(runId, progress);
      _progressThrottleTimer = Timer(const Duration(milliseconds: 100), () {
        _progressThrottleTimer = null;
        final pending = _pendingProgress;
        _pendingProgress = null;
        if (pending != null) _emitProgress(runId, pending);
      });
      return;
    }
    _pendingProgress = progress;
  }

  void _emitProgress(int runId, BookSourceMaintenanceProgress progress) {
    if (!_isCurrent(runId)) return;
    _emit(
      BookSourceMaintenanceState(
        status: _state.status,
        runId: runId,
        progress: progress,
        result: _state.result,
      ),
    );
  }

  void _clearPendingProgress() {
    _progressThrottleTimer?.cancel();
    _progressThrottleTimer = null;
    _pendingProgress = null;
  }

  void _emit(BookSourceMaintenanceState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRequested = true;
    _clearPendingProgress();
    super.dispose();
  }
}
