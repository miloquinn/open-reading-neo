import '../services/book_download_cancellation.dart';

/// Caps how often requests to one reading source may fire, mirroring the
/// legado `concurrentRate` contract: `"N/M"` allows N requests per M
/// milliseconds, a bare `"M"` is shorthand for `"1/M"`, and `"0"`/blank means
/// unlimited. All calls sharing a [SourceConcurrencyLimiter] instance and key
/// (typically a source's stable id) draw from the same sliding window,
/// regardless of which endpoint (search/catalog/content/script network call)
/// they came from — a source that declares "1/1000" is protected everywhere
/// it's reached from, not just on one call site.
class SourceConcurrencyLimiter {
  final Map<String, _RateWindow> _windows = {};

  /// Blocks until a request slot for [key] under [concurrentRate] is free.
  /// Returns immediately for an unlimited or unparsable rate. Waiting can be
  /// interrupted early via [cancellation].
  Future<void> acquire(
    String key,
    String concurrentRate, {
    BookDownloadCancellation? cancellation,
  }) async {
    final limit = _parseRate(concurrentRate);
    if (limit == null) return;
    while (true) {
      cancellation?.throwIfCancelled();
      final now = DateTime.now().millisecondsSinceEpoch;
      final window = _windows[key];
      if (window == null || now - window.windowStart >= limit.intervalMs) {
        _windows[key] = _RateWindow(now, 1);
        return;
      }
      if (window.count < limit.maxRequests) {
        window.count++;
        return;
      }
      final waitMs = window.windowStart + limit.intervalMs - now;
      final wait = Duration(milliseconds: waitMs > 0 ? waitMs : 1);
      if (cancellation != null) {
        await cancellation.delay(wait);
      } else {
        await Future<void>.delayed(wait);
      }
    }
  }

  void reset([String? key]) {
    if (key == null) {
      _windows.clear();
    } else {
      _windows.remove(key);
    }
  }
}

class _RateWindow {
  _RateWindow(this.windowStart, this.count);
  final int windowStart;
  int count;
}

class _RateLimit {
  const _RateLimit({required this.maxRequests, required this.intervalMs});
  final int maxRequests;
  final int intervalMs;
}

_RateLimit? _parseRate(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value == '0') return null;
  final slash = value.indexOf('/');
  if (slash < 0) {
    final intervalMs = int.tryParse(value);
    if (intervalMs == null || intervalMs <= 0) return null;
    return _RateLimit(maxRequests: 1, intervalMs: intervalMs);
  }
  final maxRequests = int.tryParse(value.substring(0, slash).trim());
  final intervalMs = int.tryParse(value.substring(slash + 1).trim());
  if (maxRequests == null ||
      maxRequests <= 0 ||
      intervalMs == null ||
      intervalMs <= 0) {
    return null;
  }
  return _RateLimit(maxRequests: maxRequests, intervalMs: intervalMs);
}
