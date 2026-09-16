import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'reading_account_scope.dart';
import 'reading_cloud_store.dart';

/// Small immutable checkpoints bound to the account at reading time, never to
/// the account that happens to be logged in when a network request completes.
class ReadingCloudRecorder {
  ReadingCloudRecorder({
    ReadingCloudStore? store,
    ReadingAccountScope? scope,
    this.elapsedSeconds,
    DateTime Function()? now,
  }) : _store = store ?? ReadingCloudStore(),
       _scope = scope ?? ReadingAccountScope.instance,
       _now = now ?? DateTime.now;

  final ReadingCloudStore _store;
  final ReadingAccountScope _scope;
  final int Function()? elapsedSeconds;
  final DateTime Function() _now;
  final Stopwatch _elapsed = Stopwatch();
  Timer? _timer;
  int _startMs = 0;
  String? _owner;
  bool _active = false;
  Future<void> _saving = Future<void>.value();

  void start() {
    if (_active) return;
    _active = true;
    _owner = _scope.owner;
    _startMs = _now().millisecondsSinceEpoch;
    _elapsed
      ..reset()
      ..start();
    _scope.addListener(_accountChanged);
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _checkpoint());
  }

  void _accountChanged() {
    _checkpoint();
    _owner = _scope.owner;
    _startMs = _now().millisecondsSinceEpoch;
    _elapsed
      ..reset()
      ..start();
  }

  void _checkpoint() {
    final seconds = elapsedSeconds?.call() ?? _elapsed.elapsed.inSeconds;
    if (seconds <= 0) return;
    // Preserve monotonic elapsed duration when the wall clock changes.
    final owner = _owner;
    final start = _startMs;
    _startMs += seconds * 1000;
    _elapsed
      ..reset()
      ..start();
    for (var offset = 0; offset < seconds; offset += 300) {
      final partStart = start + offset * 1000;
      final partSeconds = math.min(300, seconds - offset);
      final id = ReadingCloudStore.newId();
      _saving = _saving
          .then(
            (_) => _store.record(
              eventId: id,
              owner: owner,
              startMs: partStart,
              seconds: partSeconds,
            ),
          )
          .catchError((Object error) {
            debugPrint('Save reading cloud checkpoint failed: $error');
          });
    }
  }

  Future<void> stop() {
    if (!_active) return _saving;
    _checkpoint();
    _elapsed.stop();
    _active = false;
    _timer?.cancel();
    _scope.removeListener(_accountChanged);
    return _saving;
  }
}
