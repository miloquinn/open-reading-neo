import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

typedef CacheDiskGroupKey = String Function(File file);

/// Applies expiry and byte quotas to rebuildable files below one cache root.
///
/// A group is the eviction unit. Callers can group related index/data files or
/// every file below a per-book directory so pruning never leaves half a cache.
class CacheDiskBudget {
  const CacheDiskBudget({
    required this.directory,
    required this.maxBytes,
    this.maxAge,
    this.maintenanceInterval = const Duration(minutes: 5),
    this.groupKey,
    this.onScan,
  }) : assert(maxBytes >= 0);

  final Directory directory;
  final int maxBytes;
  final Duration? maxAge;
  final Duration maintenanceInterval;
  final CacheDiskGroupKey? groupKey;

  /// Test hook used to prove that hot-path maintenance is throttled.
  final void Function()? onScan;

  static final Map<String, DateTime> _lastMaintenance = {};
  static final Map<String, Future<void>> _maintenanceInFlight = {};
  static final Map<String, int> _knownSizeBytes = {};

  /// Records cache growth and forces a scan when the known quota is crossed.
  /// Replacements can overestimate growth, which only causes an earlier scan.
  Future<void> recordWrite(
    int bytes, {
    Set<String> protectedPaths = const {},
  }) async {
    final root = path.normalize(directory.absolute.path);
    final known = _knownSizeBytes[root];
    if (known == null) {
      await maintain(protectedPaths: protectedPaths, force: true);
      return;
    }
    final expected = known + bytes;
    _knownSizeBytes[root] = expected;
    await maintain(protectedPaths: protectedPaths, force: expected > maxBytes);
  }

  Future<void> maintain({
    Set<String> protectedPaths = const {},
    bool force = false,
  }) async {
    final root = path.normalize(directory.absolute.path);
    final active = _maintenanceInFlight[root];
    if (active != null) {
      await active;
      if (!force) return;
    }
    final now = DateTime.now();
    final last = _lastMaintenance[root];
    if (!force && last != null && now.difference(last) < maintenanceInterval) {
      return;
    }

    late final Future<void> maintenance;
    maintenance = _maintainNow(root, protectedPaths, now).whenComplete(() {
      if (identical(_maintenanceInFlight[root], maintenance)) {
        _maintenanceInFlight.remove(root);
      }
    });
    _maintenanceInFlight[root] = maintenance;
    await maintenance;
  }

  Future<bool> isExpired(File file, {DateTime? now}) async {
    final lifetime = maxAge;
    if (lifetime == null) return false;
    try {
      return (now ?? DateTime.now()).difference(await file.lastModified()) >
          lifetime;
    } catch (_) {
      return true;
    }
  }

  Future<void> touch(File file, {DateTime? at}) async {
    try {
      await file.setLastAccessed(at ?? DateTime.now());
    } catch (_) {
      // Access timestamps are only an eviction hint.
    }
  }

  Future<int> sizeBytes() async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } catch (_) {
        // Cache entries can disappear while statistics are collected.
      }
    }
    return total;
  }

  Future<void> _maintainNow(
    String root,
    Set<String> protectedPaths,
    DateTime now,
  ) async {
    onScan?.call();
    _lastMaintenance[root] = now;
    if (!await directory.exists()) {
      _knownSizeBytes[root] = 0;
      return;
    }

    final groups = <String, _DiskGroup>{};
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          final key =
              groupKey?.call(entity) ?? path.normalize(entity.absolute.path);
          final timestamp = stat.accessed.isAfter(stat.modified)
              ? stat.accessed
              : stat.modified;
          groups
              .putIfAbsent(key, () => _DiskGroup(key))
              .add(entity, stat.size, timestamp);
        } catch (_) {
          // Ignore entries removed concurrently with the cache scan.
        }
      }
    } on FileSystemException {
      _knownSizeBytes.remove(root);
      return;
    }

    var totalBytes = groups.values.fold<int>(
      0,
      (total, group) => total + group.bytes,
    );
    final ordered = groups.values.toList()
      ..sort((left, right) {
        final age = left.lastUsed.compareTo(right.lastUsed);
        return age != 0 ? age : left.key.compareTo(right.key);
      });

    final lifetime = maxAge;
    if (lifetime != null) {
      for (final group in ordered) {
        if (now.difference(group.lastUsed) <= lifetime) continue;
        if (_isProtected(group, protectedPaths)) continue;
        if (await _deleteGroup(group, root, protectedPaths)) {
          totalBytes -= group.bytes;
          group.deleted = true;
        }
      }
    }

    for (final group in ordered) {
      if (totalBytes <= maxBytes) break;
      if (group.deleted || _isProtected(group, protectedPaths)) continue;
      if (await _deleteGroup(group, root, protectedPaths)) {
        totalBytes -= group.bytes;
        group.deleted = true;
      }
    }
    _knownSizeBytes[root] = totalBytes < 0 ? 0 : totalBytes;
  }

  Future<bool> _deleteGroup(
    _DiskGroup group,
    String root,
    Set<String> protectedPaths,
  ) async {
    // Re-read the caller-owned set immediately before mutation. Active-reader
    // registration can change while the directory scan is awaiting I/O.
    if (_isProtected(group, protectedPaths)) return false;
    for (final file in group.files) {
      if (_isProtected(group, protectedPaths)) return false;
      try {
        if (await file.exists()) {
          await file.delete();
        }
        await _deleteEmptyParents(file.parent, root);
      } catch (_) {
        // A failed eviction is harmless; later maintenance can retry it.
      }
    }
    for (final file in group.files) {
      try {
        if (await file.exists()) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  Future<void> _deleteEmptyParents(Directory directory, String root) async {
    var current = directory;
    while (path.isWithin(root, current.absolute.path)) {
      try {
        if (!await current.list(followLinks: false).isEmpty) return;
        await current.delete();
        current = current.parent;
      } catch (_) {
        return;
      }
    }
  }

  bool _isProtected(_DiskGroup group, Set<String> protectedPaths) {
    if (protectedPaths.isEmpty) return false;
    for (final protectedPath in protectedPaths) {
      final protected = path.normalize(path.absolute(protectedPath));
      for (final file in group.files) {
        final candidate = path.normalize(file.absolute.path);
        if (candidate == protected ||
            path.isWithin(candidate, protected) ||
            path.isWithin(protected, candidate)) {
          return true;
        }
      }
    }
    return false;
  }
}

class _DiskGroup {
  _DiskGroup(this.key);

  final String key;
  final List<File> files = [];
  int bytes = 0;
  DateTime lastUsed = DateTime.fromMillisecondsSinceEpoch(0);
  bool deleted = false;

  void add(File file, int size, DateTime usedAt) {
    files.add(file);
    bytes += size;
    if (usedAt.isAfter(lastUsed)) lastUsed = usedAt;
  }
}
