import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/registered_book_source.dart';
import '../source_engine/source_health_checker.dart';
import 'book_source_health_check_service.dart';

enum BookSourceMaintenanceStatus { idle, running, completed, cancelled, failed }

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
    required this.fullyAvailable,
    required this.needsAttention,
  });

  final List<RegisteredBookSource> fullyAvailable;
  final List<RegisteredBookSource> needsAttention;

  int get total => fullyAvailable.length + needsAttention.length;
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

  bool get isRunning => status == BookSourceMaintenanceStatus.running;
  bool get hasReviewResult =>
      result != null && result!.needsAttention.isNotEmpty;
}

/// Owns long-running source maintenance independently from the management
/// page, so hiding its progress UI or navigating elsewhere does not cancel it.
class BookSourceMaintenanceCoordinator extends ChangeNotifier {
  BookSourceMaintenanceCoordinator({BookSourceHealthCheckService? service})
    : _service = service ?? BookSourceHealthCheckService();

  final BookSourceHealthCheckService _service;
  BookSourceMaintenanceState _state = const BookSourceMaintenanceState();
  bool _cancelRequested = false;
  bool _disposed = false;
  Timer? _progressThrottleTimer;
  BookSourceMaintenanceProgress? _pendingProgress;

  BookSourceMaintenanceState get state => _state;

  Future<void> start(Iterable<RegisteredBookSource> sources) async {
    if (_state.isRunning) return;
    final targets = sources
        .where(
          (source) =>
              source.sourceProtocol == BookSourceProtocolKind.readingSource,
        )
        .toList(growable: false);
    final runId = _state.runId + 1;
    _cancelRequested = false;
    _emit(
      BookSourceMaintenanceState(
        status: BookSourceMaintenanceStatus.running,
        runId: runId,
        progress: BookSourceMaintenanceProgress(
          completed: 0,
          total: targets.length,
        ),
      ),
    );
    if (targets.isEmpty) {
      _emit(
        BookSourceMaintenanceState(
          status: BookSourceMaintenanceStatus.completed,
          runId: runId,
          result: const BookSourceMaintenanceResult(
            fullyAvailable: [],
            needsAttention: [],
          ),
        ),
      );
      return;
    }

    try {
      final updated = await _service.checkAllForCleanup(
        targets,
        onProgress: (completed, total) {
          if (!_isCurrent(runId)) return;
          _reportProgress(
            runId,
            BookSourceMaintenanceProgress(completed: completed, total: total),
          );
        },
        isCancelled: () => _cancelRequested || !_isCurrent(runId),
      );
      if (!_isCurrent(runId)) return;
      _clearPendingProgress();
      final fullyAvailable = <RegisteredBookSource>[];
      final needsAttention = <RegisteredBookSource>[];
      for (final source in updated) {
        final result = sourceHealthCheckResultOf(source);
        (result?.fullyAvailable == true ? fullyAvailable : needsAttention).add(
          source,
        );
      }
      _emit(
        BookSourceMaintenanceState(
          status: _cancelRequested
              ? BookSourceMaintenanceStatus.cancelled
              : BookSourceMaintenanceStatus.completed,
          runId: runId,
          result: BookSourceMaintenanceResult(
            fullyAvailable: List.unmodifiable(fullyAvailable),
            needsAttention: List.unmodifiable(needsAttention),
          ),
        ),
      );
    } on Object catch (error) {
      if (!_isCurrent(runId)) return;
      _clearPendingProgress();
      _emit(
        BookSourceMaintenanceState(
          status: BookSourceMaintenanceStatus.failed,
          runId: runId,
          failure: error,
        ),
      );
    }
  }

  void cancel() {
    if (_state.isRunning) _cancelRequested = true;
  }

  void clearResult() {
    if (_state.isRunning || _state.result == null) return;
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
        status: BookSourceMaintenanceStatus.running,
        runId: runId,
        progress: progress,
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
