import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../core/cache_disk_budget.dart';

/// Owns derived TXT/EPUB resources. A lazy reader must retain its resource group
/// until it closes; clearing an open book defers only that group's deletion.
class NativeReaderCacheStore {
  NativeReaderCacheStore({this.maxDiskBytes = 512 * 1024 * 1024});

  static final instance = NativeReaderCacheStore();
  final int maxDiskBytes;
  final _owners = <Object, Set<String>>{};
  final _protectedPaths = <String>{};
  final _pendingDeletes = <String>{};
  final _memoryClearers = <VoidCallback>{};
  final _budgets = <String, CacheDiskBudget>{};
  final _maintainAfterRelease = <Object>{};
  Future<void>? _deletionQueue;
  int _generation = 0;

  int get generation => _generation;

  @visibleForTesting
  bool get hasRetainedResources => _owners.isNotEmpty;

  /// Waits for queued deletion/maintenance, including work appended while the
  /// current operation finishes. Readers and writers retain resources separately.
  Future<void> flushPendingOperations() async {
    while (true) {
      final pending = _deletionQueue;
      if (pending == null) return;
      await pending;
    }
  }

  void registerMemoryClearer(VoidCallback clear) => _memoryClearers.add(clear);

  void retain(Object owner, String resourcePath) {
    final normalized = path.normalize(path.absolute(resourcePath));
    (_owners[owner] ??= {}).add(normalized);
    _protectedPaths.addAll(_resourcePaths(normalized));
  }

  Future<void> acquire(Object owner, String resourcePath) async {
    // A newly opened reader waits for an already-started eviction before it
    // observes files. Existing readers retain synchronously and are protected.
    await flushPendingOperations();
    retain(owner, resourcePath);
  }

  void discardWhenReleased(String resourcePath) {
    _pendingDeletes.addAll(
      _resourcePaths(path.normalize(path.absolute(resourcePath))),
    );
  }

  /// A second reader can reuse the parsed book while keeping its files alive
  /// independently of the bounded reopen cache.
  void retainFrom(Object owner, Object existingOwner) {
    for (final resource in _owners[existingOwner] ?? const <String>{}) {
      retain(owner, resource);
    }
  }

  Future<void> release(Object owner, {bool enforceBudget = false}) {
    _owners.remove(owner);
    final maintain = _maintainAfterRelease.remove(owner) || enforceBudget;
    if (enforceBudget) _maintainAfterRelease.addAll(_owners.keys);
    _protectedPaths
      ..clear()
      ..addAll(_owners.values.expand((paths) => paths).expand(_resourcePaths));
    return _serialize(() async {
      for (final candidate in _pendingDeletes.toList()) {
        if (_isProtected(candidate)) continue;
        if (await _delete(candidate)) _pendingDeletes.remove(candidate);
      }
      if (maintain) {
        for (final budget in _budgets.values) {
          await budget.maintain(protectedPaths: _protectedPaths, force: true);
        }
      }
    });
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final previous = _deletionQueue;
    final deletion = previous == null
        ? Future<void>.sync(operation)
        : previous.then((_) => operation());
    // Keep future releases usable after a filesystem failure; callers still
    // receive the failed operation and can report it.
    late final Future<void> settled;
    settled = deletion
        .catchError((Object error) {
          debugPrint('Deferred reader cache deletion failed: $error');
        })
        .whenComplete(() {
          if (identical(_deletionQueue, settled)) _deletionQueue = null;
        });
    _deletionQueue = settled;
    return deletion;
  }

  Future<void> maintain(Directory directory, {bool force = false}) async {
    final budget = _budgets.putIfAbsent(
      directory.absolute.path,
      () => CacheDiskBudget(
        directory: directory,
        maxBytes: maxDiskBytes,
        groupKey: (entry) {
          final relative = path.split(
            path.relative(entry.path, from: directory.path),
          );
          return relative.length > 1
              ? path.join(directory.path, relative.first)
              : _groupPath(entry.path);
        },
      ),
    );
    await _serialize(
      () => budget.maintain(protectedPaths: _protectedPaths, force: force),
    );
  }

  void scheduleMaintenance(Directory directory, {bool force = false}) {
    unawaited(
      maintain(directory, force: force).catchError((Object error) {
        debugPrint('Reader cache maintenance failed: $error');
      }),
    );
  }

  Future<void> clearDirectory(Directory directory) async {
    _generation++;
    for (final clear in _memoryClearers.toList()) {
      clear();
    }
    // Remember retained paths even if an isolate has not created its output
    // yet. Its eventual write must be deleted when the last reader releases it.
    _pendingDeletes.addAll(
      _protectedPaths.where(
        (resource) => path.isWithin(directory.absolute.path, resource),
      ),
    );
    await _serialize(() => _clearEntry(directory.path));
  }

  Future<void> _clearEntry(String candidate) async {
    if (_isProtected(candidate)) {
      final normalized = path.normalize(path.absolute(candidate));
      // Preserve an entire retained EPUB directory or TXT resource group.
      if (_protectedPaths.any(
        (resource) =>
            resource == normalized ||
            path.isWithin(resource, normalized) ||
            _groupPath(normalized) == resource,
      )) {
        _pendingDeletes.add(normalized);
        return;
      }
      if (await FileSystemEntity.type(candidate, followLinks: false) ==
          FileSystemEntityType.directory) {
        await for (final entry in Directory(
          candidate,
        ).list(followLinks: false)) {
          await _clearEntry(entry.path);
        }
      }
      return;
    }
    await _delete(candidate);
  }

  bool _isProtected(String candidate) {
    final normalized = path.normalize(path.absolute(candidate));
    return _protectedPaths.any(
      (resource) =>
          resource == normalized ||
          path.isWithin(resource, normalized) ||
          path.isWithin(normalized, resource) ||
          _groupPath(normalized) == resource,
    );
  }

  static String _groupPath(String value) => value.replaceFirst(
    RegExp(r'\.json(?:\.(?:index|data))?(?:\.tmp)?$'),
    '.json',
  );

  static Iterable<String> _resourcePaths(String value) sync* {
    yield value;
    if (value.endsWith('.json')) {
      yield '$value.index';
      yield '$value.data';
      yield '$value.tmp';
      yield '$value.index.tmp';
      yield '$value.data.tmp';
    }
  }

  Future<bool> _delete(String candidate) async {
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (_isProtected(candidate)) {
      _pendingDeletes.add(candidate);
      return false;
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(candidate).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(candidate).delete();
    } else if (type == FileSystemEntityType.link) {
      await Link(candidate).delete();
    }
    return true;
  }
}
