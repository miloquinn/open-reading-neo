import 'dart:async';

/// Coalesces reading events without postponing transmission indefinitely.
/// Durable changes live in the database; this class only schedules attempts.
class AutomaticSyncScheduler {
  AutomaticSyncScheduler({
    required this.run,
    required this.enabled,
    this.coalesceDelay = const Duration(seconds: 5),
    this.pollInterval = const Duration(seconds: 45),
  });

  final Future<void> Function() run;
  final bool Function() enabled;
  final Duration coalesceDelay;
  final Duration pollInterval;
  Timer? _queued;
  Timer? _poll;
  bool _foreground = true;
  bool _disposed = false;
  bool _running = false;
  bool _dirtyDuringRun = false;
  int _failures = 0;

  void start() {
    if (_disposed || _poll != null || !_foreground) return;
    _poll = Timer.periodic(pollInterval, (_) => request(immediate: true));
  }

  void setForeground(bool value) {
    if (_foreground == value) return;
    _foreground = value;
    _poll?.cancel();
    _poll = null;
    if (value) {
      start();
      request(immediate: true);
    } else {
      // One best-effort flush; the OS may suspend execution afterwards.
      request(immediate: true);
    }
  }

  void request({bool immediate = false}) {
    if (_disposed || !enabled()) return;
    if (_running) {
      _dirtyDuringRun = true;
      return;
    }
    if (immediate) {
      _queued?.cancel();
      _queued = null;
      unawaited(_attempt());
    } else {
      _queued ??= Timer(coalesceDelay, () {
        _queued = null;
        unawaited(_attempt());
      });
    }
  }

  Future<void> _attempt() async {
    if (_disposed || _running || !enabled()) return;
    _running = true;
    var failed = false;
    try {
      await run();
      _failures = 0;
    } catch (_) {
      failed = true;
      _failures = (_failures + 1).clamp(1, 6);
    } finally {
      _running = false;
      if (!_disposed && enabled() && _foreground) {
        if (failed) {
          _queued?.cancel();
          _queued = Timer(Duration(seconds: 5 * (1 << _failures)), () {
            _queued = null;
            unawaited(_attempt());
          });
        } else if (_dirtyDuringRun) {
          request();
        }
      }
      _dirtyDuringRun = false;
    }
  }

  void cancelPending() {
    _queued?.cancel();
    _queued = null;
    _dirtyDuringRun = false;
  }

  void dispose() {
    _disposed = true;
    cancelPending();
    _poll?.cancel();
    _poll = null;
  }
}
