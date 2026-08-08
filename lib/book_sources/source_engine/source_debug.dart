enum SourceDebugEventKind { stageStart, stageSuccess, stageError, network }

class SourceDebugEvent {
  const SourceDebugEvent({
    required this.kind,
    required this.stage,
    required this.message,
    required this.timestamp,
    this.detail,
    this.statusCode,
    this.error,
    this.elapsed,
  });

  final SourceDebugEventKind kind;
  final String stage;
  final String message;
  final String? detail;
  final int? statusCode;
  final Object? error;
  final DateTime timestamp;
  final Duration? elapsed;

  bool get isError =>
      kind == SourceDebugEventKind.stageError ||
      error != null ||
      (statusCode != null && statusCode! >= 400);
}

/// Receives step-by-step trace events as a `SourceRuntime` resolves a
/// request. Attaching one to a runtime turns on tracing for every call made
/// through that runtime instance; leaving it unset costs nothing extra.
abstract interface class SourceDebugRecorder {
  void stageStarted(String stage);
  void stageSucceeded(String stage, String summary);
  void stageFailed(String stage, Object error);
  void recordNetwork({
    required String stage,
    required String method,
    required Uri url,
    int? statusCode,
    String? bodyPreview,
    Object? error,
    Duration? elapsed,
  });
}
