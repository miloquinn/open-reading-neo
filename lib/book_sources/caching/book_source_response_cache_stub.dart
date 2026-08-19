/// Memory-only fallback for platforms without `dart:io` file-system caches.
class BookSourceResponseCache {
  static const int schemaVersion = 1;
  static const String directoryName = 'book_source_responses';
  static final BookSourceResponseCache instance = BookSourceResponseCache();

  BookSourceResponseCache({
    Object? cacheDirectory,
    this.maxMemoryEntries = 48,
    this.maxMemoryBytes = 4 * 1024 * 1024,
    this.maxDiskEntries = 0,
    this.maxDiskBytes = 0,
    DateTime Function()? now,
    this.beforeDiskMutation,
  }) : _now = now ?? DateTime.now;

  final int maxMemoryEntries;
  final int maxMemoryBytes;
  final int maxDiskEntries;
  final int maxDiskBytes;
  final DateTime Function() _now;
  final Future<void> Function()? beforeDiskMutation;

  final Map<String, _MemoryEntry> _memory = {};
  final Map<String, Future<Map<String, dynamic>>> _inFlight = {};
  final Map<String, _KeyState> _keyStates = {};
  int _memoryBytes = 0;
  int _clearEpoch = 0;

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
    }
    return _loadAndStore(key, state, generation, clearEpoch, loader);
  }

  Future<void> invalidate(String key) async {
    final state = _keyStates[key];
    if (state != null) state.generation++;
    _inFlight.remove(key);
    _inFlight.remove('$key\u0000refresh');
    final memory = _memory.remove(key);
    if (memory != null) _memoryBytes -= memory.size;
  }

  Future<void> invalidatePrefix(String prefix) => invalidatePrefixes([prefix]);

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
  }

  Future<Map<String, dynamic>> _loadAndStore(
    String key,
    _KeyState state,
    int generation,
    int clearEpoch,
    Future<Map<String, dynamic>> Function() loader,
  ) async {
    final loaded = Map<String, dynamic>.unmodifiable(await loader());
    if (!_isCurrent(state, generation, clearEpoch)) return loaded;
    final entry = _MemoryEntry(loaded, _now().toUtc(), _estimateSize(loaded));
    _remember(key, entry);
    return loaded;
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
      final oldest = _memory.remove(_memory.keys.first)!;
      _memoryBytes -= oldest.size;
    }
  }

  void clearMemory() {
    _memory.clear();
    _memoryBytes = 0;
  }

  Future<void> clear() async {
    _clearEpoch++;
    clearMemory();
    _inFlight.clear();
  }

  Future<void> flushPendingWrites() async {}

  Future<int> diskSizeBytes() async => 0;
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
