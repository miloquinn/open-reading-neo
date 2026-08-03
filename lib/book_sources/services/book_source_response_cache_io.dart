import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Two-level cache for public book-source metadata responses.
///
/// The persistent format intentionally stores only raw JSON. Reading-source
/// runtime results can contain source variables or authentication-derived
/// state, so callers must keep those responses out of this cache.
class BookSourceResponseCache {
  static const int schemaVersion = 1;
  static const String directoryName = 'book_source_responses';
  static final BookSourceResponseCache instance = BookSourceResponseCache();

  BookSourceResponseCache({
    this.cacheDirectory,
    this.maxMemoryEntries = 48,
    this.maxMemoryBytes = 4 * 1024 * 1024,
    this.maxDiskEntries = 160,
    this.maxDiskBytes = 16 * 1024 * 1024,
    @visibleForTesting DateTime Function()? now,
    @visibleForTesting this.beforeDiskMutation,
  }) : _now = now ?? DateTime.now;

  final Directory? cacheDirectory;
  final int maxMemoryEntries;
  final int maxMemoryBytes;
  final int maxDiskEntries;
  final int maxDiskBytes;
  final DateTime Function() _now;

  @visibleForTesting
  final Future<void> Function()? beforeDiskMutation;

  final Map<String, _MemoryEntry> _memory = {};
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};
  final Map<String, _KeyState> _keyStates = {};
  int _memoryBytes = 0;
  int _clearEpoch = 0;
  Future<void> _diskMutationTail = Future<void>.value();
  Future<void> _diskReadBarrier = Future<void>.value();
  bool _quotaEnforcementScheduled = false;

  int get memorySizeBytes => _memoryBytes;
  int get memoryEntryCount => _memory.length;

  Future<Map<String, dynamic>> getOrLoadJson({
    required String key,
    required Duration ttl,
    required Future<Map<String, dynamic>> Function() loader,
    bool forceRefresh = false,
    bool deduplicateInFlight = true,
    bool persistToDisk = true,
  }) async {
    if (forceRefresh) await invalidate(key);

    if (!deduplicateInFlight) {
      return _runKeyOperation(
        key: key,
        ttl: ttl,
        loader: loader,
        skipCache: forceRefresh,
        persistToDisk: persistToDisk,
      );
    }

    final flightKey = forceRefresh ? '$key\u0000refresh' : key;
    final pending = _inFlight[flightKey];
    if (pending != null) return pending;

    final future = _runKeyOperation(
      key: key,
      ttl: ttl,
      loader: loader,
      skipCache: forceRefresh,
      persistToDisk: persistToDisk,
    );
    _inFlight[flightKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[flightKey], future)) {
        _inFlight.remove(flightKey);
      }
    }
  }

  Future<Map<String, dynamic>> _runKeyOperation({
    required String key,
    required Duration ttl,
    required Future<Map<String, dynamic>> Function() loader,
    required bool skipCache,
    required bool persistToDisk,
  }) async {
    final state = _retainKeyState(key);
    final generation = state.generation;
    final clearEpoch = _clearEpoch;
    try {
      return await _readOrLoadJson(
        key: key,
        state: state,
        generation: generation,
        clearEpoch: clearEpoch,
        ttl: ttl,
        loader: loader,
        skipCache: skipCache,
        persistToDisk: persistToDisk,
      );
    } finally {
      _releaseKeyState(key, state);
    }
  }

  Future<Map<String, dynamic>> _readOrLoadJson({
    required String key,
    required _KeyState state,
    required int generation,
    required int clearEpoch,
    required Duration ttl,
    required Future<Map<String, dynamic>> Function() loader,
    required bool skipCache,
    required bool persistToDisk,
  }) async {
    if (!skipCache && _isCurrent(state, generation, clearEpoch)) {
      final memory = _memory.remove(key);
      if (memory != null) {
        _memoryBytes -= memory.size;
        if (_isFresh(memory.cachedAt, ttl)) {
          _remember(key, memory);
          return memory.value;
        }
      }

      if (persistToDisk) {
        await _diskReadBarrier;
        if (_isCurrent(state, generation, clearEpoch)) {
          final disk = await _readDisk(key, ttl);
          if (disk != null && _isCurrent(state, generation, clearEpoch)) {
            _remember(key, disk);
            return disk.value;
          }
        }
      }
    }
    return _loadAndStore(
      key,
      state,
      generation,
      clearEpoch,
      ttl,
      persistToDisk,
      loader,
    );
  }

  Future<void> invalidate(String key) async {
    final state = _keyStates[key];
    if (state != null) state.generation++;
    _inFlight.remove(key);
    _inFlight.remove('$key\u0000refresh');
    final memory = _memory.remove(key);
    if (memory != null) _memoryBytes -= memory.size;
    final deletion = _enqueueDiskMutation(() async {
      try {
        final file = await _fileFor(key);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Cache invalidation must not make a manual refresh fail.
      }
    });
    _diskReadBarrier = deletion.catchError((Object _) {});
    await deletion;
  }

  Future<void> invalidatePrefix(String prefix) async {
    return invalidatePrefixes([prefix]);
  }

  Future<void> invalidatePrefixes(Iterable<String> prefixes) async {
    final normalized = prefixes.where((prefix) => prefix.isNotEmpty).toSet();
    if (normalized.isEmpty) return;
    bool matches(String key) => normalized.any(key.startsWith);

    for (final entry in _keyStates.entries.where(
      (entry) => matches(entry.key),
    )) {
      entry.value.generation++;
    }
    for (final flightKey in _inFlight.keys.where(matches).toList()) {
      _inFlight.remove(flightKey);
    }
    for (final key in _memory.keys.where(matches).toList()) {
      final entry = _memory.remove(key);
      if (entry != null) _memoryBytes -= entry.size;
    }
    final deletion = _enqueueDiskMutation(() async {
      try {
        final root = await _rootDirectory();
        if (!await root.exists()) return;
        await for (final entity in root.list()) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          try {
            final decoded = jsonDecode(await entity.readAsString());
            if (decoded is Map && matches('${decoded['key']}')) {
              await entity.delete();
            }
          } catch (_) {
            await _deleteIfPresent(entity);
          }
        }
      } catch (_) {
        // Persistent cache cleanup is best effort.
      }
    });
    _diskReadBarrier = deletion.catchError((Object _) {});
    await deletion;
  }

  Future<Map<String, dynamic>> _loadAndStore(
    String key,
    _KeyState state,
    int generation,
    int clearEpoch,
    Duration ttl,
    bool persistToDisk,
    Future<Map<String, dynamic>> Function() loader,
  ) async {
    final loaded = Map<String, dynamic>.unmodifiable(await loader());
    if (!_isCurrent(state, generation, clearEpoch)) return loaded;
    final entry = _MemoryEntry(loaded, _now().toUtc(), _estimateSize(loaded));
    _remember(key, entry);
    if (persistToDisk) {
      _scheduleWrite(
        key,
        state,
        () => _writeDisk(
          key,
          state,
          generation,
          clearEpoch,
          entry,
          jsonEncode(loaded),
          ttl,
        ),
      );
    }
    return loaded;
  }

  void _scheduleWrite(
    String key,
    _KeyState state,
    Future<void> Function() write,
  ) {
    state.activeOperations++;
    final queued = _enqueueDiskMutation(write);
    unawaited(
      queued
          .whenComplete(() => _releaseKeyState(key, state))
          .catchError((Object _) {}),
    );
  }

  Future<void> flushPendingWrites() async {
    while (true) {
      final pending = _diskMutationTail;
      await pending;
      if (identical(pending, _diskMutationTail)) return;
    }
  }

  Future<void> _enqueueDiskMutation(Future<void> Function() mutation) {
    final queued = _diskMutationTail.then((_) async {
      await beforeDiskMutation?.call();
      await mutation();
    });
    _diskMutationTail = queued.catchError((Object _) {
      // Disk caching is opportunistic; keep the queue usable after a failure.
    });
    return queued;
  }

  _KeyState _retainKeyState(String key) {
    final state = _keyStates.putIfAbsent(key, _KeyState.new);
    state.activeOperations++;
    return state;
  }

  void _releaseKeyState(String key, _KeyState state) {
    state.activeOperations--;
    if (state.activeOperations == 0 && identical(_keyStates[key], state)) {
      _keyStates.remove(key);
    }
  }

  bool _isCurrent(_KeyState state, int generation, int clearEpoch) {
    return state.generation == generation && _clearEpoch == clearEpoch;
  }

  bool _isFresh(DateTime cachedAt, Duration ttl) {
    final age = _now().toUtc().difference(cachedAt);
    return !age.isNegative && age < ttl;
  }

  int _estimateSize(Object? value) {
    final limit = maxMemoryBytes > 0 ? maxMemoryBytes : 0;

    int visit(Object? item, int remaining) {
      int fixed(int size) => size > remaining ? limit + 1 : size;

      return switch (item) {
        null => fixed(8),
        bool() || num() => fixed(16),
        String() => fixed(16 + item.length * 3),
        List() => () {
          var total = 32;
          if (total > remaining) return limit + 1;
          for (final child in item) {
            final childSize = visit(child, remaining - total);
            if (childSize > remaining - total) return limit + 1;
            total += childSize;
          }
          return total;
        }(),
        Map() => () {
          var total = 48;
          if (total > remaining) return limit + 1;
          for (final entry in item.entries) {
            final key = entry.key;
            final keySize = key is String
                ? visit(key, remaining - total)
                : fixed(32);
            if (keySize > remaining - total) return limit + 1;
            total += keySize;
            final valueSize = visit(entry.value, remaining - total);
            if (valueSize > remaining - total) return limit + 1;
            total += valueSize;
          }
          return total;
        }(),
        _ => fixed(32),
      };
    }

    return visit(value, limit);
  }

  void _remember(String key, _MemoryEntry entry) {
    if (entry.size > maxMemoryBytes || maxMemoryEntries <= 0) return;
    final previous = _memory.remove(key);
    if (previous != null) _memoryBytes -= previous.size;
    _memory[key] = entry;
    _memoryBytes += entry.size;
    while (_memory.length > maxMemoryEntries || _memoryBytes > maxMemoryBytes) {
      final oldestKey = _memory.keys.first;
      final oldest = _memory.remove(oldestKey)!;
      _memoryBytes -= oldest.size;
    }
  }

  Future<_MemoryEntry?> _readDisk(String key, Duration ttl) async {
    File? file;
    try {
      file = await _fileFor(key);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['schema'] != schemaVersion ||
          decoded['key'] != key ||
          decoded['payload'] is! Map) {
        await _deleteIfPresent(file);
        return null;
      }
      final cachedAt = DateTime.tryParse('${decoded['cachedAt']}')?.toUtc();
      if (cachedAt == null || !_isFresh(cachedAt, ttl)) {
        await _deleteIfPresent(file);
        return null;
      }
      final value = (decoded['payload'] as Map).map(
        (key, value) => MapEntry('$key', value),
      );
      final size = utf8.encode(jsonEncode(value)).length;
      return _MemoryEntry(Map.unmodifiable(value), cachedAt, size);
    } catch (_) {
      if (file != null) await _deleteIfPresent(file);
      return null;
    }
  }

  Future<void> _writeDisk(
    String key,
    _KeyState state,
    int generation,
    int clearEpoch,
    _MemoryEntry entry,
    String encodedPayload,
    Duration ttl,
  ) async {
    if (maxDiskEntries <= 0 || maxDiskBytes <= 0) return;
    try {
      final file = await _fileFor(key);
      await file.parent.create(recursive: true);
      final expiresAt = entry.cachedAt.add(ttl).toIso8601String();
      final contents =
          '{"schema":$schemaVersion,'
          '"key":${jsonEncode(key)},'
          '"cachedAt":${jsonEncode(entry.cachedAt.toIso8601String())},'
          '"expiresAt":${jsonEncode(expiresAt)},'
          '"payload":$encodedPayload}';
      if (utf8.encode(contents).length > maxDiskBytes) return;
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(contents, flush: true);
      if (!_isCurrent(state, generation, clearEpoch)) {
        await _deleteIfPresent(temporary);
        return;
      }
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      _scheduleDiskQuotaEnforcement();
    } catch (_) {
      // Cache persistence is opportunistic and must never fail a request.
    }
  }

  Future<void> _enforceDiskQuota() async {
    final root = await _rootDirectory();
    if (!await root.exists()) return;
    final files = <_DiskFile>[];
    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final stat = await entity.stat();
        files.add(_DiskFile(entity, stat.modified, stat.size));
      } catch (_) {
        // A concurrently removed file needs no further cleanup.
      }
    }
    files.sort((left, right) => left.modified.compareTo(right.modified));
    var totalBytes = files.fold<int>(0, (sum, file) => sum + file.size);
    while (files.length > maxDiskEntries || totalBytes > maxDiskBytes) {
      final oldest = files.removeAt(0);
      totalBytes -= oldest.size;
      await _deleteIfPresent(oldest.file);
    }
  }

  void _scheduleDiskQuotaEnforcement() {
    if (_quotaEnforcementScheduled) return;
    _quotaEnforcementScheduled = true;
    unawaited(
      _enqueueDiskMutation(() async {
        try {
          await _enforceDiskQuota();
        } finally {
          _quotaEnforcementScheduled = false;
        }
      }).catchError((Object _) {}),
    );
  }

  Future<Directory> directory() async {
    if (cacheDirectory != null) return cacheDirectory!;
    final temporary = await getTemporaryDirectory();
    return Directory(path.join(temporary.path, directoryName));
  }

  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }

  Future<void> clear() async {
    _clearEpoch++;
    clearMemory();
    _inFlight.clear();
    final deletion = _enqueueDiskMutation(() async {
      try {
        final root = await directory();
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {
        // Cache cleanup is best effort and must not affect application data.
      }
    });
    _diskReadBarrier = deletion.catchError((Object _) {});
    await deletion;
  }

  Future<int> diskSizeBytes() async {
    final root = await directory();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } catch (_) {
        // A concurrent cleanup may remove an entry while sizes are read.
      }
    }
    return total;
  }

  Future<Directory> _rootDirectory() => directory();

  Future<File> _fileFor(String key) async {
    final root = await directory();
    final name = sha256.convert(utf8.encode(key)).toString();
    return File(path.join(root.path, '$name.json'));
  }

  Future<void> _deleteIfPresent(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort corruption and quota cleanup.
    }
  }
}

class _MemoryEntry {
  const _MemoryEntry(this.value, this.cachedAt, this.size);

  final Map<String, dynamic> value;
  final DateTime cachedAt;
  final int size;
}

class _KeyState {
  int generation = 0;
  int activeOperations = 0;
}

class _DiskFile {
  const _DiskFile(this.file, this.modified, this.size);

  final File file;
  final DateTime modified;
  final int size;
}
