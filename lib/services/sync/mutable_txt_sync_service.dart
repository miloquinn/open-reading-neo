import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/book.dart';
import '../../utils/fast_gbk_decoder.dart';
import '../books/enhanced_txt_import_service.dart';
import '../books/txt_content_change_bus.dart';
import '../books/txt_edit_reference_service.dart';
import '../books/txt_edit_service.dart';
import '../core/database_service.dart';
import 'secure_sync_config.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'chunked_txt_webdav_transport.dart';
import 'reading_progress_sync_service.dart';
import 'txt_chunk_manifest.dart';
import 'webdav_client.dart';

enum MutableTxtSyncStatus {
  localOnly,
  paused,
  pending,
  syncing,
  synced,
  updateAvailable,
  conflict,
  failed,
}

enum MutableTxtConflictChoice { keepLocal, useRemote }

enum MutableTxtSyncMode { plainV2, chunkedV3 }

class MutableTxtBookState {
  const MutableTxtBookState({
    required this.bookUid,
    required this.localBookId,
    required this.localPath,
    required this.remotePath,
    required this.status,
    this.localHash,
    this.baseHash,
    this.remoteEtag,
    this.error,
    this.pendingRemoteHash,
    this.enabled = true,
    this.mode = MutableTxtSyncMode.plainV2,
  });

  final String bookUid;
  final int? localBookId;
  final String localPath;
  final String remotePath;
  final MutableTxtSyncStatus status;
  final String? localHash;
  final String? baseHash;
  final String? remoteEtag;
  final String? error;
  final String? pendingRemoteHash;
  final bool enabled;
  final MutableTxtSyncMode mode;
}

class MutableTxtConflict {
  const MutableTxtConflict({
    required this.id,
    required this.bookUid,
    required this.spaceKey,
    required this.localHash,
    required this.remoteHash,
    required this.localSnapshotPath,
    required this.remoteSnapshotPath,
    required this.remoteEtag,
    required this.createdAt,
    this.remoteEncoding,
  });

  final int id;
  final String bookUid;
  final String spaceKey;
  final String localHash;
  final String remoteHash;
  final String localSnapshotPath;
  final String remoteSnapshotPath;
  final String remoteEtag;
  final DateTime createdAt;
  final String? remoteEncoding;
}

class MutableTxtRevision {
  const MutableTxtRevision({
    required this.bookUid,
    required this.hash,
    required this.snapshotPath,
    required this.origin,
    required this.createdAt,
  });

  final String bookUid;
  final String hash;
  final String snapshotPath;
  final String origin;
  final DateTime createdAt;
}

class MutableTxtReconcileResult {
  const MutableTxtReconcileResult({
    required this.uploaded,
    required this.downloaded,
    required this.conflicts,
    required this.failed,
    this.uploadedBytes = 0,
  });

  final int uploaded;
  final int downloaded;
  final int conflicts;
  final int failed;
  final int uploadedBytes;
}

/// Synchronizes editable TXT files through isolated WebDAV namespaces.
///
/// A caller must supply a stable [bookUid] when a book joins. Content hashes
/// are revisions and are never used as mutable book identity here. Existing
/// books remain on plain-file v2 unless [enableIncremental] is explicitly used.
class MutableTxtSyncService {
  MutableTxtSyncService({
    SecureSyncConfigStore? configStore,
    DatabaseService? databaseService,
    WebDavClientFactory? clientFactory,
    Future<Database> Function()? database,
    Future<Directory> Function()? stateDirectory,
    DateTime Function()? now,
    void Function(TxtContentChanged event)? onContentChanged,
    TxtEditReferenceService? referenceService,
    Future<void> Function(File backup)? committedBackupCleanup,
  }) : _configStore = configStore ?? SecureSyncConfigStore(),
       _databaseService = databaseService ?? DatabaseService(),
       _clientFactory = clientFactory ?? WebDavClient.standard,
       _databaseProvider = database,
       _stateDirectory = stateDirectory ?? _defaultStateDirectory,
       _now = now ?? DateTime.now,
       _committedBackupCleanup =
           committedBackupCleanup ?? _deleteCommittedBackup,
       _onContentChanged =
           onContentChanged ?? TxtContentChangeBus.instance.notify {
    _referenceService =
        referenceService ??
        TxtEditReferenceService(databaseProvider: () => _database);
  }

  final SecureSyncConfigStore _configStore;
  final DatabaseService _databaseService;
  final WebDavClientFactory _clientFactory;
  final Future<Database> Function()? _databaseProvider;
  final Future<Directory> Function() _stateDirectory;
  final DateTime Function() _now;
  final Future<void> Function(File backup) _committedBackupCleanup;
  final void Function(TxtContentChanged event) _onContentChanged;
  late final TxtEditReferenceService _referenceService;
  Future<void>? _activeReconcile;
  Future<void>? _activeModeChange;
  int _reconcileUploadedBytes = 0;

  Future<Database> get _database =>
      _databaseProvider?.call() ?? _databaseService.database;

  static Future<Directory> _defaultStateDirectory() async {
    final root = await getApplicationSupportDirectory();
    return Directory(path.join(root.path, 'sync', 'mutable_txt'));
  }

  static Future<void> _deleteCommittedBackup(File backup) async {
    if (await backup.exists()) await backup.delete();
  }

  /// Repairs an interrupted remote file replacement without reading sync
  /// configuration, scanning books, or touching the network.
  Future<void> recoverLocalState() async {
    final db = await _database;
    await _ensureSchema(db);
    await _recoverApplyJournals(db);
  }

  Future<void> join(
    Book book, {
    required String bookUid,
    bool incremental = false,
  }) async {
    _validateBook(book, bookUid);
    final db = await _database;
    await _ensureSchema(db);
    await _recoverApplyJournals(db);
    final credentials = await _credentials();
    final spaceKey = _spaceKey(credentials.configuration);
    await _activateBindingSpace(
      db,
      bookUid: bookUid,
      localBookId: book.id,
      localPath: book.filePath,
      spaceKey: spaceKey,
    );
    if (await _binding(db, bookUid) != null) {
      if (incremental) await enableIncremental(bookUid);
      await enqueueLocalUpdate(book, bookUid: bookUid);
      return;
    }
    final source = File(book.filePath);
    final snapshot = await _snapshot(source, bookUid, origin: 'local');
    final legacyRows = await db.query(
      'sync_book_files',
      columns: ['blob_sha256', 'remote_path'],
      where: 'book_uid = ?',
      whereArgs: [bookUid],
      limit: 1,
    );
    final knownV2Baseline =
        !incremental &&
        legacyRows.isNotEmpty &&
        legacyRows.single['blob_sha256'] == snapshot.hash &&
        (legacyRows.single['remote_path'] as String).startsWith('v2:');
    final mode = incremental
        ? MutableTxtSyncMode.chunkedV3
        : MutableTxtSyncMode.plainV2;
    final remotePath = _currentRemotePath(bookUid, mode);
    final now = _utcNow();
    await db.transaction((txn) async {
      await txn.insert('mutable_txt_bindings', {
        'book_uid': bookUid,
        'local_book_id': book.id,
        'local_path': book.filePath,
        'remote_path': remotePath,
        'space_key': spaceKey,
        'protocol_mode': mode.name,
        'local_hash': snapshot.hash,
        'base_hash': knownV2Baseline ? snapshot.hash : null,
        'remote_etag': null,
        'status': knownV2Baseline
            ? MutableTxtSyncStatus.synced.name
            : MutableTxtSyncStatus.pending.name,
        'last_error': null,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (!knownV2Baseline) {
        await _putJob(
          txn,
          bookUid: bookUid,
          snapshot: snapshot,
          baseHash: null,
        );
      }
      await _recordRevision(txn, bookUid, snapshot, 'local');
    });
  }

  /// Explicitly upgrades one binding to the v3 content-addressed protocol.
  ///
  /// The old v2 current.txt remains untouched as a recoverable cloud copy. The
  /// next reconcile publishes a fresh v3 baseline; this is never automatic.
  Future<void> enableIncremental(String bookUid) async {
    final existingChange = _activeModeChange;
    if (existingChange != null) {
      await existingChange;
      return enableIncremental(bookUid);
    }
    final operation = _enableIncrementalAfterReconcile(bookUid);
    _activeModeChange = operation;
    try {
      await operation;
    } finally {
      if (identical(_activeModeChange, operation)) _activeModeChange = null;
    }
  }

  Future<void> _enableIncrementalAfterReconcile(String bookUid) async {
    final activeReconcile = _activeReconcile;
    if (activeReconcile != null) await activeReconcile;
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The TXT sync binding no longer exists.',
      );
    }
    await _requireCurrentSpace(binding);
    if (binding.mode == MutableTxtSyncMode.chunkedV3) return;
    if (binding.status == MutableTxtSyncStatus.conflict ||
        binding.status == MutableTxtSyncStatus.updateAvailable ||
        binding.status == MutableTxtSyncStatus.syncing) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'Resolve or apply the current TXT sync state before enabling incremental sync.',
      );
    }
    final snapshot = await _snapshot(
      File(binding.localPath),
      binding.bookUid,
      origin: 'local',
    );
    await db.transaction((txn) async {
      await txn.update(
        'mutable_txt_bindings',
        {
          'protocol_mode': MutableTxtSyncMode.chunkedV3.name,
          'remote_path': _currentRemotePath(
            binding.bookUid,
            MutableTxtSyncMode.chunkedV3,
          ),
          'local_hash': snapshot.hash,
          'base_hash': null,
          'remote_etag': null,
          'status': binding.enabled
              ? MutableTxtSyncStatus.pending.name
              : MutableTxtSyncStatus.paused.name,
          'last_error': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      await _putJob(
        txn,
        bookUid: binding.bookUid,
        snapshot: snapshot,
        baseHash: null,
      );
      await _recordRevision(txn, binding.bookUid, snapshot, 'local');
    });
  }

  /// Follows a v3 descriptor learned through metadata sync on another device.
  ///
  /// Protocol upgrades are monotonic. A local pending edit keeps its existing
  /// base hash and will conflict normally if the v3 cloud version also moved.
  /// Unresolved conflicts and staged remote versions defer the switch so their
  /// snapshots remain tied to the protocol that created them.
  Future<bool> followRemoteStorage({
    required String bookUid,
    required String remotePath,
    required String contentHash,
    required int fileSize,
  }) async {
    final expectedPath = _currentRemotePath(
      bookUid,
      MutableTxtSyncMode.chunkedV3,
    );
    if (remotePath != expectedPath ||
        !_contentHashPattern.hasMatch(contentHash)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The synced TXT storage descriptor is invalid.',
      );
    }
    final existingChange = _activeModeChange;
    if (existingChange != null) {
      await existingChange;
      return followRemoteStorage(
        bookUid: bookUid,
        remotePath: remotePath,
        contentHash: contentHash,
        fileSize: fileSize,
      );
    }
    final gate = Completer<void>();
    _activeModeChange = gate.future;
    final operation = _followRemoteStorageAfterReconcile(
      bookUid: bookUid,
      remotePath: remotePath,
      contentHash: contentHash,
      fileSize: fileSize,
    );
    try {
      return await operation;
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_activeModeChange, gate.future)) _activeModeChange = null;
    }
  }

  Future<bool> _followRemoteStorageAfterReconcile({
    required String bookUid,
    required String remotePath,
    required String contentHash,
    required int fileSize,
  }) async {
    final activeReconcile = _activeReconcile;
    if (activeReconcile != null) await activeReconcile;
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null) return false;
    await _requireCurrentSpace(binding);
    if (binding.mode == MutableTxtSyncMode.chunkedV3) return true;
    if (binding.status == MutableTxtSyncStatus.conflict ||
        binding.status == MutableTxtSyncStatus.updateAvailable ||
        binding.status == MutableTxtSyncStatus.syncing) {
      return false;
    }
    await db.transaction((txn) async {
      await txn.update(
        'mutable_txt_bindings',
        {
          'protocol_mode': MutableTxtSyncMode.chunkedV3.name,
          'remote_path': remotePath,
          'remote_etag': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      await txn.update(
        'sync_book_files',
        {
          'blob_sha256': contentHash,
          'file_size': fileSize,
          'remote_path': remotePath,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ?',
        whereArgs: [binding.bookUid],
      );
    });
    return true;
  }

  /// Captures an immutable snapshot after the editor has atomically saved.
  Future<void> enqueueLocalUpdate(Book book, {required String bookUid}) async {
    _validateBook(book, bookUid);
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null) {
      return;
    }
    final snapshot = await _snapshot(
      File(book.filePath),
      bookUid,
      origin: 'local',
    );
    if (binding.status == MutableTxtSyncStatus.conflict) {
      await _updateConflictLocal(db, binding, snapshot);
      return;
    }
    if (snapshot.hash == binding.localHash &&
        binding.status != MutableTxtSyncStatus.failed) {
      return;
    }
    await db.transaction((txn) async {
      await txn.update(
        'mutable_txt_bindings',
        {
          'local_book_id': book.id,
          'local_path': book.filePath,
          'local_hash': snapshot.hash,
          'status': binding.enabled
              ? MutableTxtSyncStatus.pending.name
              : MutableTxtSyncStatus.paused.name,
          'last_error': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ?',
        whereArgs: [bookUid],
      );
      await _putJob(
        txn,
        bookUid: bookUid,
        snapshot: snapshot,
        baseHash: binding.baseHash,
      );
      await _recordRevision(txn, bookUid, snapshot, 'local');
    });
  }

  /// Finds edits missed while the process was stopped, then pushes and pulls.
  Future<MutableTxtReconcileResult> reconcile({
    bool allowNetwork = true,
    String? bookUid,
    bool Function()? shouldContinue,
  }) async {
    final modeChange = _activeModeChange;
    if (modeChange != null) await modeChange;
    if (_activeReconcile != null) {
      await _activeReconcile;
      return const MutableTxtReconcileResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        failed: 0,
      );
    }
    late MutableTxtReconcileResult result;
    final completer = _runReconcile(
      allowNetwork: allowNetwork,
      bookUid: bookUid,
      shouldContinue: shouldContinue,
    ).then((value) => result = value);
    _activeReconcile = completer;
    try {
      await completer;
      return result;
    } finally {
      _activeReconcile = null;
    }
  }

  Future<MutableTxtReconcileResult> _runReconcile({
    required bool allowNetwork,
    String? bookUid,
    bool Function()? shouldContinue,
  }) async {
    _reconcileUploadedBytes = 0;
    final db = await _database;
    await _ensureSchema(db);
    await _recoverApplyJournals(db);
    final bindings = await _bindings(db, bookUid: bookUid);
    for (final binding in bindings) {
      if (!binding.enabled) {
        continue;
      }
      final file = File(binding.localPath);
      if (!await file.exists()) continue;
      if (binding.status == MutableTxtSyncStatus.conflict) {
        final hash = await _hashFile(file);
        if (hash != binding.localHash) {
          await _updateConflictLocal(
            db,
            binding,
            await _snapshot(file, binding.bookUid, origin: 'local'),
          );
        }
        continue;
      }
      final hash = await _hashFile(file);
      if (hash != binding.localHash) {
        final snapshot = await _snapshot(
          file,
          binding.bookUid,
          origin: 'local',
        );
        await db.transaction((txn) async {
          await txn.update(
            'mutable_txt_bindings',
            {
              'local_hash': hash,
              'status': MutableTxtSyncStatus.pending.name,
              'last_error': null,
              'updated_at': _utcNow(),
            },
            where: 'book_uid = ?',
            whereArgs: [binding.bookUid],
          );
          await _putJob(
            txn,
            bookUid: binding.bookUid,
            snapshot: snapshot,
            baseHash: binding.baseHash,
          );
          await _recordRevision(txn, binding.bookUid, snapshot, 'local');
        });
      }
    }
    if (!allowNetwork) {
      return const MutableTxtReconcileResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        failed: 0,
      );
    }

    final credentials = await _credentials();
    final scope = await _configStore.readScope();
    if (!scope.bookFiles) {
      return const MutableTxtReconcileResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        failed: 0,
      );
    }
    await _discoverLegacyBindings(db);
    final client = _clientFactory(credentials);
    final currentSpaceKey = _spaceKey(credentials.configuration);
    if (shouldContinue?.call() == false) {
      return const MutableTxtReconcileResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        failed: 0,
      );
    }
    await _ensureMutableCapabilities(db, client, currentSpaceKey);
    var uploaded = 0;
    var downloaded = 0;
    var conflicts = 0;
    var failed = 0;
    for (final stale in await _bindings(db, bookUid: bookUid)) {
      if (shouldContinue?.call() == false) break;
      if (!stale.enabled || stale.status == MutableTxtSyncStatus.conflict) {
        continue;
      }
      if (stale.spaceKey != currentSpaceKey) continue;
      try {
        final outcome = await _reconcileBook(
          db,
          client,
          stale.bookUid,
          shouldContinue: shouldContinue,
        );
        uploaded += outcome == _BookOutcome.uploaded ? 1 : 0;
        downloaded += outcome == _BookOutcome.downloaded ? 1 : 0;
        conflicts += outcome == _BookOutcome.conflict ? 1 : 0;
      } catch (error) {
        failed++;
        await db.update(
          'mutable_txt_bindings',
          {
            'status': MutableTxtSyncStatus.failed.name,
            'last_error': '$error',
            'updated_at': _utcNow(),
          },
          where: 'book_uid = ?',
          whereArgs: [stale.bookUid],
        );
      }
    }
    return MutableTxtReconcileResult(
      uploaded: uploaded,
      downloaded: downloaded,
      conflicts: conflicts,
      failed: failed,
      uploadedBytes: _reconcileUploadedBytes,
    );
  }

  Future<List<MutableTxtBookState>> listStates() async {
    final db = await _database;
    await _ensureSchema(db);
    final spaceKey = await _currentSpaceKeyOrNull();
    if (spaceKey == null) return const [];
    return (await _bindings(db))
        .where((binding) => binding.spaceKey == spaceKey)
        .map((binding) => binding.publicState)
        .toList();
  }

  Future<List<MutableTxtConflict>> listConflicts({String? bookUid}) async {
    final db = await _database;
    await _ensureSchema(db);
    final spaceKey = await _currentSpaceKeyOrNull();
    if (spaceKey == null) return const [];
    final rows = await db.query(
      'mutable_txt_conflicts',
      where: bookUid == null
          ? 'space_key = ? AND resolved_at IS NULL'
          : 'space_key = ? AND book_uid = ? AND resolved_at IS NULL',
      whereArgs: bookUid == null ? [spaceKey] : [spaceKey, bookUid],
      orderBy: 'created_at DESC',
    );
    return rows.map(_conflictFromRow).toList(growable: false);
  }

  Future<List<MutableTxtRevision>> listHistory(String bookUid) async {
    final db = await _database;
    await _ensureSchema(db);
    final rows = await db.query(
      'mutable_txt_revisions',
      where: 'book_uid = ?',
      whereArgs: [bookUid],
      orderBy: 'created_at DESC',
    );
    return rows
        .map(
          (row) => MutableTxtRevision(
            bookUid: row['book_uid'] as String,
            hash: row['content_hash'] as String,
            snapshotPath: row['snapshot_path'] as String,
            origin: row['origin'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
        )
        .toList(growable: false);
  }

  Future<void> setEnabled(String bookUid, bool enabled) async {
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The TXT sync binding no longer exists.',
      );
    }
    await _requireCurrentSpace(binding);
    final pendingRows = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM mutable_txt_jobs WHERE book_uid = ?',
      [bookUid],
    );
    final pending = (pendingRows.single['count'] as int) > 0;
    await db.transaction((txn) async {
      await txn.update(
        'mutable_txt_bindings',
        {
          'sync_enabled': enabled ? 1 : 0,
          'status': enabled
              ? (pending
                    ? MutableTxtSyncStatus.pending.name
                    : MutableTxtSyncStatus.synced.name)
              : MutableTxtSyncStatus.paused.name,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ?',
        whereArgs: [bookUid],
      );
      await txn.update(
        'sync_book_files',
        {'sync_enabled': enabled ? 1 : 0, 'updated_at': _utcNow()},
        where: 'book_uid = ?',
        whereArgs: [bookUid],
      );
    });
  }

  Future<void> resolveConflict(
    int conflictId,
    MutableTxtConflictChoice choice,
  ) async {
    final db = await _database;
    await _ensureSchema(db);
    final spaceKey = await _currentSpaceKeyOrNull();
    if (spaceKey == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'WebDAV is not configured for this TXT conflict.',
      );
    }
    final rows = await db.query(
      'mutable_txt_conflicts',
      where: 'id = ? AND space_key = ? AND resolved_at IS NULL',
      whereArgs: [conflictId, spaceKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The TXT conflict no longer exists.',
      );
    }
    final conflict = _conflictFromRow(rows.single);
    final binding = await _binding(db, conflict.bookUid);
    if (binding == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The TXT sync binding no longer exists.',
      );
    }
    await _requireCurrentSpace(binding);
    if (conflict.spaceKey != binding.spaceKey) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The TXT conflict belongs to another WebDAV space.',
      );
    }
    final currentHash = await _hashFile(File(binding.localPath));
    if (currentHash != conflict.localHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The local TXT changed after the conflict was created.',
      );
    }
    if (choice == MutableTxtConflictChoice.useRemote) {
      if (conflict.remoteEtag == '"deleted"') {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.invalidConfiguration,
          'A missing cloud file cannot silently delete the local TXT. Keep the local copy or use the explicit delete flow.',
        );
      }
      await _applyRemoteSnapshot(
        db,
        binding,
        _Snapshot(
          File(conflict.remoteSnapshotPath),
          conflict.remoteHash,
          await File(conflict.remoteSnapshotPath).length(),
          textEncoding: conflict.remoteEncoding,
        ),
        conflict.remoteEtag,
      );
      await db.transaction((txn) async {
        await txn.update(
          'mutable_txt_conflicts',
          {'resolved_at': _utcNow(), 'resolution': 'remote'},
          where: 'id = ? AND space_key = ?',
          whereArgs: [conflictId, spaceKey],
        );
      });
      return;
    }

    final localSnapshot = _Snapshot(
      File(conflict.localSnapshotPath),
      conflict.localHash,
      await File(conflict.localSnapshotPath).length(),
    );
    await db.transaction((txn) async {
      await _putJob(
        txn,
        bookUid: conflict.bookUid,
        snapshot: localSnapshot,
        baseHash: conflict.remoteHash,
        expectedEtag: conflict.remoteEtag,
        force: true,
      );
      await txn.update(
        'mutable_txt_bindings',
        {
          'base_hash': conflict.remoteHash,
          'remote_etag': conflict.remoteEtag,
          'status': MutableTxtSyncStatus.pending.name,
          'last_error': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [conflict.bookUid, spaceKey],
      );
      await txn.update(
        'mutable_txt_conflicts',
        {'resolved_at': _utcNow(), 'resolution': 'local'},
        where: 'id = ? AND space_key = ?',
        whereArgs: [conflictId, spaceKey],
      );
    });
  }

  /// Applies a staged remote revision after the reader/editor releases it.
  Future<bool> applyAvailableUpdate(String bookUid) async {
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null ||
        binding.pendingRemotePath == null ||
        binding.pendingRemoteHash == null ||
        binding.pendingRemoteEtag == null) {
      return false;
    }
    await _requireCurrentSpace(binding);
    if (_isBookBusy(binding.localBookId)) return false;
    final local = File(binding.localPath);
    if (await _hashFile(local) != binding.baseHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The local TXT changed before the remote update was applied.',
      );
    }
    final remote = File(binding.pendingRemotePath!);
    if (!await remote.exists() ||
        await _hashFile(remote) != binding.pendingRemoteHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'The staged remote TXT update is missing or damaged.',
      );
    }
    await _applyRemoteSnapshot(
      db,
      binding,
      _Snapshot(
        remote,
        binding.pendingRemoteHash!,
        await remote.length(),
        textEncoding: binding.pendingRemoteEncoding,
      ),
      binding.pendingRemoteEtag!,
    );
    return true;
  }

  Future<bool> applyPendingRemote(String bookUid) =>
      applyAvailableUpdate(bookUid);

  /// Resolves the encoding sidecar tied to immutable [contentHash] and
  /// validates [file] against it before a first-device import.
  Future<String> validatedRemoteRevisionEncoding({
    required WebDavClient client,
    required String bookUid,
    required String contentHash,
    required File file,
  }) => _remoteRevisionEncoding(client, bookUid, contentHash, file);

  /// Downloads and verifies the current v3 version for first-device import.
  Future<String> downloadIncrementalFile({
    required WebDavClient client,
    required String bookUid,
    required String expectedHash,
    required int expectedSize,
    required File destination,
  }) async {
    const transport = ChunkedTxtWebDavTransport();
    final remote = await transport.readCurrent(
      client,
      _identitySegment(bookUid),
    );
    if (remote == null ||
        remote.manifest.contentSha256 != expectedHash ||
        remote.manifest.byteLength != expectedSize) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The cloud TXT manifest does not match its library metadata.',
      );
    }
    await transport.download(
      client: client,
      manifest: remote.manifest,
      store: await _chunkStore(),
      destination: destination,
    );
    final encoding = await _validatedManifestEncoding(
      remote.manifest,
      destination,
    );
    return encoding;
  }

  Future<_BookOutcome> _reconcileBook(
    Database db,
    WebDavClient client,
    String bookUid, {
    bool Function()? shouldContinue,
  }) async {
    var binding = await _binding(db, bookUid);
    if (binding == null) return _BookOutcome.unchanged;
    final jobRows = await db.query(
      'mutable_txt_jobs',
      where: 'book_uid = ?',
      whereArgs: [bookUid],
      limit: 1,
    );
    if (jobRows.isNotEmpty) {
      return _push(
        db,
        client,
        binding,
        _Job.fromRow(jobRows.single),
        shouldContinue: shouldContinue,
      );
    }
    binding = (await _binding(db, bookUid))!;
    return _pull(db, client, binding, shouldContinue: shouldContinue);
  }

  Future<_BookOutcome> _push(
    Database db,
    WebDavClient client,
    _Binding binding,
    _Job job, {
    bool Function()? shouldContinue,
  }) async {
    if (binding.mode == MutableTxtSyncMode.chunkedV3) {
      return _pushChunked(
        db,
        client,
        binding,
        job,
        shouldContinue: shouldContinue,
      );
    }
    final snapshot = File(job.snapshotPath);
    if (!await snapshot.exists() ||
        await _hashFile(snapshot) != job.snapshotHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'A queued TXT snapshot is missing or damaged.',
      );
    }
    final textEncoding = await _encodingForBinding(db, binding, snapshot);
    await _validateFileForEncoding(snapshot, textEncoding);
    await db.update(
      'mutable_txt_bindings',
      {'status': MutableTxtSyncStatus.syncing.name, 'updated_at': _utcNow()},
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    final segment = _identitySegment(binding.bookUid);
    if (shouldContinue?.call() == false) {
      await _setPending(db, binding.bookUid);
      return _BookOutcome.unchanged;
    }
    await client.ensureMutableProtocolPath(['books', segment]);
    await client.ensureMutableProtocolPath(['revisions', segment]);
    final revisionUri = client.mutablePath([
      'revisions',
      segment,
      '${job.snapshotHash}.txt',
    ]);
    try {
      if (shouldContinue?.call() == false) {
        await _setPending(db, binding.bookUid);
        return _BookOutcome.unchanged;
      }
      await client.putFileConditionally(
        revisionUri,
        snapshot,
        ifNoneMatch: true,
      );
    } on WebDavSyncFailure catch (error) {
      if (error.code != WebDavSyncErrorCode.conflict ||
          !await _remoteMatches(client, revisionUri, job.snapshotHash)) {
        rethrow;
      }
    }
    if (shouldContinue?.call() == false) {
      await _setPending(db, binding.bookUid);
      return _BookOutcome.unchanged;
    }
    await _publishRevisionMetadata(
      client,
      binding.bookUid,
      job.snapshotHash,
      textEncoding,
    );

    final currentUri = client.mutablePath(['books', segment, 'current.txt']);
    final remote = await client.resourceState(currentUri);
    String? writeEtag;
    if (!remote.exists) {
      if (job.baseHash != null && !job.force) {
        return _createDeletionConflict(db, binding, job, client, currentUri);
      }
      writeEtag = null;
    } else {
      final etag = _requireStrongEtag(remote.etag);
      final remoteSnapshot = await _downloadSnapshot(
        client,
        currentUri,
        binding.bookUid,
        origin: 'remote',
      );
      if (remoteSnapshot.hash == job.snapshotHash) {
        await _markSynced(
          db,
          binding,
          job.snapshotHash,
          etag,
          job.snapshotPath,
        );
        return _BookOutcome.unchanged;
      }
      final mayReplace = job.force
          ? etag == job.expectedEtag
          : job.baseHash == remoteSnapshot.hash;
      if (!mayReplace) {
        return _recordConflict(db, binding, job, remoteSnapshot, etag);
      }
      writeEtag = etag;
    }

    if (shouldContinue?.call() == false) {
      await _setPending(db, binding.bookUid);
      return _BookOutcome.unchanged;
    }
    late final WebDavConditionalWriteResult written;
    try {
      written = await client.putFileConditionally(
        currentUri,
        snapshot,
        ifMatch: writeEtag,
        ifNoneMatch: writeEtag == null,
      );
    } on WebDavSyncFailure catch (error) {
      if (error.code != WebDavSyncErrorCode.conflict) rethrow;
      final latest = await client.resourceState(currentUri);
      if (!latest.exists) {
        return _createDeletionConflict(db, binding, job, client, currentUri);
      }
      final latestEtag = _requireStrongEtag(latest.etag);
      final latestSnapshot = await _downloadSnapshot(
        client,
        currentUri,
        binding.bookUid,
        origin: 'remote',
      );
      if (latestSnapshot.hash == job.snapshotHash) {
        await _markSynced(
          db,
          binding,
          job.snapshotHash,
          latestEtag,
          job.snapshotPath,
        );
        return _BookOutcome.unchanged;
      }
      return _recordConflict(db, binding, job, latestSnapshot, latestEtag);
    }
    if (!await _remoteMatches(client, currentUri, job.snapshotHash)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The published TXT did not pass checksum verification.',
      );
    }
    await _markSynced(
      db,
      binding,
      job.snapshotHash,
      written.etag,
      job.snapshotPath,
    );
    return _BookOutcome.uploaded;
  }

  Future<_BookOutcome> _pushChunked(
    Database db,
    WebDavClient client,
    _Binding binding,
    _Job job, {
    bool Function()? shouldContinue,
  }) async {
    final snapshot = File(job.snapshotPath);
    if (!await snapshot.exists() ||
        await _hashFile(snapshot) != job.snapshotHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'A queued TXT snapshot is missing or damaged.',
      );
    }
    final textEncoding = await _encodingForBinding(db, binding, snapshot);
    await _validateFileForEncoding(snapshot, textEncoding);
    final store = await _chunkStore();
    final manifest = await store.capture(snapshot, textEncoding: textEncoding);
    if (manifest.contentSha256 != job.snapshotHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'The TXT chunk manifest does not match its queued snapshot.',
      );
    }
    await db.update(
      'mutable_txt_bindings',
      {'status': MutableTxtSyncStatus.syncing.name, 'updated_at': _utcNow()},
      where: 'book_uid = ? AND space_key = ?',
      whereArgs: [binding.bookUid, binding.spaceKey],
    );
    if (shouldContinue?.call() == false) {
      await _setPending(db, binding.bookUid);
      return _BookOutcome.unchanged;
    }

    const transport = ChunkedTxtWebDavTransport();
    final segment = _identitySegment(binding.bookUid);
    var remote = await transport.readCurrent(client, segment);
    if (remote == null) {
      if (job.baseHash != null && !job.force) {
        return _createDeletionConflict(
          db,
          binding,
          job,
          client,
          transport.currentUri(client, segment),
        );
      }
    } else {
      if (remote.manifest.contentSha256 == job.snapshotHash) {
        if (!_sameChunkManifest(remote.manifest, manifest)) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'The cloud TXT manifest hash matches but its chunks do not.',
          );
        }
        await _markSynced(
          db,
          binding,
          job.snapshotHash,
          remote.etag,
          job.snapshotPath,
        );
        return _BookOutcome.unchanged;
      }
      final mayReplace = job.force
          ? remote.etag == job.expectedEtag
          : job.baseHash == remote.manifest.contentSha256;
      if (!mayReplace) {
        late final _Snapshot remoteSnapshot;
        try {
          remoteSnapshot = await _downloadChunkedSnapshot(
            client,
            binding.bookUid,
            remote.manifest,
            shouldContinue: shouldContinue,
          );
        } on ChunkedTxtTransferPaused {
          await _setPending(db, binding.bookUid);
          return _BookOutcome.unchanged;
        }
        return _recordConflict(db, binding, job, remoteSnapshot, remote.etag);
      }
    }

    try {
      final published = await transport.publish(
        client: client,
        bookSegment: segment,
        manifest: manifest,
        store: store,
        expectedEtag: remote?.etag,
        create: remote == null,
        trustedRemoteChunkHashes:
            remote?.manifest.chunks.map((chunk) => chunk.sha256).toSet() ??
            const {},
        shouldContinue: shouldContinue,
      );
      _reconcileUploadedBytes += published.uploadedChunkBytes;
      await _markSynced(
        db,
        binding,
        job.snapshotHash,
        published.etag,
        job.snapshotPath,
      );
      return _BookOutcome.uploaded;
    } on ChunkedTxtTransferPaused {
      await _setPending(db, binding.bookUid);
      return _BookOutcome.unchanged;
    } on WebDavSyncFailure catch (error) {
      if (error.code != WebDavSyncErrorCode.conflict) rethrow;
      remote = await transport.readCurrent(client, segment);
      if (remote == null) {
        return _createDeletionConflict(
          db,
          binding,
          job,
          client,
          transport.currentUri(client, segment),
        );
      }
      if (remote.manifest.contentSha256 == job.snapshotHash) {
        if (!_sameChunkManifest(remote.manifest, manifest)) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'The cloud TXT manifest hash matches but its chunks do not.',
          );
        }
        await _markSynced(
          db,
          binding,
          job.snapshotHash,
          remote.etag,
          job.snapshotPath,
        );
        return _BookOutcome.unchanged;
      }
      late final _Snapshot remoteSnapshot;
      try {
        remoteSnapshot = await _downloadChunkedSnapshot(
          client,
          binding.bookUid,
          remote.manifest,
          shouldContinue: shouldContinue,
        );
      } on ChunkedTxtTransferPaused {
        await _setPending(db, binding.bookUid);
        return _BookOutcome.unchanged;
      }
      return _recordConflict(db, binding, job, remoteSnapshot, remote.etag);
    }
  }

  Future<_BookOutcome> _pull(
    Database db,
    WebDavClient client,
    _Binding binding, {
    bool Function()? shouldContinue,
  }) async {
    if (binding.mode == MutableTxtSyncMode.chunkedV3) {
      return _pullChunked(db, client, binding, shouldContinue: shouldContinue);
    }
    if (shouldContinue?.call() == false) return _BookOutcome.unchanged;
    final currentUri = client.mutablePath([
      'books',
      _identitySegment(binding.bookUid),
      'current.txt',
    ]);
    final remote = await client.resourceState(currentUri);
    if (!remote.exists) return _BookOutcome.unchanged;
    final etag = _requireStrongEtag(remote.etag);
    if (etag == binding.remoteEtag) return _BookOutcome.unchanged;
    final remoteSnapshot = await _downloadSnapshot(
      client,
      currentUri,
      binding.bookUid,
      origin: 'remote',
    );
    final local = File(binding.localPath);
    final localHash = await _hashFile(local);
    if (remoteSnapshot.hash == localHash) {
      await _updateBookEncoding(
        db,
        binding.localBookId,
        remoteSnapshot.textEncoding!,
      );
      await _markSynced(db, binding, localHash, etag, null);
      return _BookOutcome.unchanged;
    }
    if (binding.baseHash != localHash) {
      final localSnapshot = await _snapshot(
        local,
        binding.bookUid,
        origin: 'local',
      );
      final job = _Job(
        snapshotPath: localSnapshot.file.path,
        snapshotHash: localSnapshot.hash,
        baseHash: binding.baseHash,
        expectedEtag: binding.remoteEtag,
        force: false,
      );
      await _recordRevision(db, binding.bookUid, localSnapshot, 'local');
      return _recordConflict(db, binding, job, remoteSnapshot, etag);
    }
    final oldSnapshot = await _snapshot(
      local,
      binding.bookUid,
      origin: 'local',
    );
    await _recordRevision(db, binding.bookUid, oldSnapshot, 'local');
    await _recordRevision(db, binding.bookUid, remoteSnapshot, 'remote');
    if (_isBookBusy(binding.localBookId) || shouldContinue?.call() == false) {
      await db.update(
        'mutable_txt_bindings',
        {
          'pending_remote_hash': remoteSnapshot.hash,
          'pending_remote_path': remoteSnapshot.file.path,
          'pending_remote_etag': etag,
          'pending_remote_encoding': remoteSnapshot.textEncoding,
          'status': MutableTxtSyncStatus.updateAvailable.name,
          'last_error': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      return _BookOutcome.unchanged;
    }
    await _applyRemoteSnapshot(db, binding, remoteSnapshot, etag);
    return _BookOutcome.downloaded;
  }

  Future<_BookOutcome> _pullChunked(
    Database db,
    WebDavClient client,
    _Binding binding, {
    bool Function()? shouldContinue,
  }) async {
    if (shouldContinue?.call() == false) return _BookOutcome.unchanged;
    const transport = ChunkedTxtWebDavTransport();
    final remote = await transport.readCurrent(
      client,
      _identitySegment(binding.bookUid),
    );
    if (remote == null || remote.etag == binding.remoteEtag) {
      return _BookOutcome.unchanged;
    }
    final local = File(binding.localPath);
    final localHash = await _hashFile(local);
    if (remote.manifest.contentSha256 == localHash) {
      await _updateBookEncoding(
        db,
        binding.localBookId,
        remote.manifest.textEncoding ??
            await _detectValidatedTextEncoding(local),
      );
      await _markSynced(db, binding, localHash, remote.etag, null);
      return _BookOutcome.unchanged;
    }
    late final _Snapshot remoteSnapshot;
    try {
      remoteSnapshot = await _downloadChunkedSnapshot(
        client,
        binding.bookUid,
        remote.manifest,
        shouldContinue: shouldContinue,
      );
    } on ChunkedTxtTransferPaused {
      return _BookOutcome.unchanged;
    }
    if (binding.baseHash != localHash) {
      final localSnapshot = await _snapshot(
        local,
        binding.bookUid,
        origin: 'local',
      );
      final job = _Job(
        snapshotPath: localSnapshot.file.path,
        snapshotHash: localSnapshot.hash,
        baseHash: binding.baseHash,
        expectedEtag: binding.remoteEtag,
        force: false,
      );
      await _recordRevision(db, binding.bookUid, localSnapshot, 'local');
      return _recordConflict(db, binding, job, remoteSnapshot, remote.etag);
    }
    final oldSnapshot = await _snapshot(
      local,
      binding.bookUid,
      origin: 'local',
    );
    await _recordRevision(db, binding.bookUid, oldSnapshot, 'local');
    await _recordRevision(db, binding.bookUid, remoteSnapshot, 'remote');
    if (_isBookBusy(binding.localBookId) || shouldContinue?.call() == false) {
      await db.update(
        'mutable_txt_bindings',
        {
          'pending_remote_hash': remoteSnapshot.hash,
          'pending_remote_path': remoteSnapshot.file.path,
          'pending_remote_etag': remote.etag,
          'pending_remote_encoding': remoteSnapshot.textEncoding,
          'status': MutableTxtSyncStatus.updateAvailable.name,
          'last_error': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      return _BookOutcome.unchanged;
    }
    await _applyRemoteSnapshot(db, binding, remoteSnapshot, remote.etag);
    return _BookOutcome.downloaded;
  }

  Future<_Snapshot> _downloadChunkedSnapshot(
    WebDavClient client,
    String bookUid,
    TxtChunkManifest manifest, {
    bool Function()? shouldContinue,
  }) async {
    final destination = await _revisionFile(bookUid, manifest.contentSha256);
    if (await destination.exists() &&
        await _hashFile(destination) == manifest.contentSha256) {
      final encoding = await _validatedManifestEncoding(manifest, destination);
      return _Snapshot(
        destination,
        manifest.contentSha256,
        manifest.byteLength,
        textEncoding: encoding,
      );
    }
    if (await destination.exists()) await destination.delete();
    final partial = File('${destination.path}.${_safeNonce()}.chunked');
    const transport = ChunkedTxtWebDavTransport();
    try {
      await transport.download(
        client: client,
        manifest: manifest,
        store: await _chunkStore(),
        destination: partial,
        shouldContinue: shouldContinue,
      );
      final encoding = await _validatedManifestEncoding(manifest, partial);
      await partial.rename(destination.path);
      return _Snapshot(
        destination,
        manifest.contentSha256,
        manifest.byteLength,
        textEncoding: encoding,
      );
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<String> _validatedManifestEncoding(
    TxtChunkManifest manifest,
    File file,
  ) async {
    final declared = manifest.textEncoding;
    final encoding = declared == null
        ? await _detectValidatedTextEncoding(file)
        : EnhancedTxtImportService.normalizeEncoding(declared);
    if (encoding == 'auto') {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The TXT chunk manifest declares an unsupported encoding.',
      );
    }
    await _validateFileForEncoding(file, encoding);
    return encoding;
  }

  bool _sameChunkManifest(TxtChunkManifest remote, TxtChunkManifest local) {
    final remoteEncoding = EnhancedTxtImportService.normalizeEncoding(
      remote.textEncoding,
    );
    final localEncoding = EnhancedTxtImportService.normalizeEncoding(
      local.textEncoding,
    );
    if (remote.contentSha256 != local.contentSha256 ||
        remote.byteLength != local.byteLength ||
        remoteEncoding == 'auto' ||
        remoteEncoding != localEncoding ||
        remote.minChunkBytes != local.minChunkBytes ||
        remote.averageChunkBytes != local.averageChunkBytes ||
        remote.maxChunkBytes != local.maxChunkBytes ||
        remote.chunks.length != local.chunks.length) {
      return false;
    }
    for (var index = 0; index < local.chunks.length; index++) {
      final a = remote.chunks[index];
      final b = local.chunks[index];
      if (a.sha256 != b.sha256 ||
          a.offset != b.offset ||
          a.length != b.length) {
        return false;
      }
    }
    return true;
  }

  Future<_BookOutcome> _createDeletionConflict(
    Database db,
    _Binding binding,
    _Job job,
    WebDavClient client,
    Uri currentUri,
  ) async {
    final root = await _rootDirectory();
    final marker = File(path.join(root.path, 'remote-deleted.txt'));
    if (!await marker.exists()) await marker.writeAsBytes(const []);
    return _recordConflict(
      db,
      binding,
      job,
      _Snapshot(marker, sha256.convert(const []).toString(), 0),
      '"deleted"',
    );
  }

  Future<_BookOutcome> _recordConflict(
    Database db,
    _Binding binding,
    _Job job,
    _Snapshot remote,
    String remoteEtag,
  ) async {
    await db.transaction((txn) async {
      await txn.insert('mutable_txt_conflicts', {
        'book_uid': binding.bookUid,
        'space_key': binding.spaceKey,
        'base_hash': job.baseHash,
        'local_hash': job.snapshotHash,
        'remote_hash': remote.hash,
        'local_snapshot_path': job.snapshotPath,
        'remote_snapshot_path': remote.file.path,
        'remote_etag': remoteEtag,
        'remote_encoding': remote.textEncoding,
        'created_at': _utcNow(),
        'resolved_at': null,
        'resolution': null,
      });
      await txn.update(
        'mutable_txt_bindings',
        {
          'status': MutableTxtSyncStatus.conflict.name,
          'last_error': null,
          'pending_remote_hash': null,
          'pending_remote_path': null,
          'pending_remote_etag': null,
          'pending_remote_encoding': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      await txn.delete(
        'mutable_txt_jobs',
        where: 'book_uid = ?',
        whereArgs: [binding.bookUid],
      );
      await _recordRevision(txn, binding.bookUid, remote, 'remote');
    });
    return _BookOutcome.conflict;
  }

  Future<void> _markSynced(
    Database db,
    _Binding binding,
    String hash,
    String etag,
    String? snapshotPath,
  ) => db.transaction(
    (txn) => _markSyncedInTransaction(txn, binding, hash, etag),
  );

  Future<void> _markSyncedInTransaction(
    DatabaseExecutor txn,
    _Binding binding,
    String hash,
    String etag,
  ) async {
    await txn.update(
      'mutable_txt_bindings',
      {
        'local_hash': hash,
        'base_hash': hash,
        'remote_etag': etag,
        'status': MutableTxtSyncStatus.synced.name,
        'last_error': null,
        'pending_remote_hash': null,
        'pending_remote_path': null,
        'pending_remote_etag': null,
        'pending_remote_encoding': null,
        'updated_at': _utcNow(),
      },
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    await txn.delete(
      'mutable_txt_jobs',
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    final fileValues = <String, Object?>{
      'book_uid': binding.bookUid,
      'local_book_id': binding.localBookId,
      'blob_sha256': hash,
      'file_name': path.basename(binding.localPath),
      'file_size': await File(binding.localPath).length(),
      'remote_path': binding.remotePath,
      'sync_enabled': 1,
      'updated_at': _utcNow(),
    };
    final existingFiles = await txn.query(
      'sync_book_files',
      columns: ['book_uid'],
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
      limit: 1,
    );
    if (existingFiles.isEmpty) {
      await txn.insert('sync_book_files', fileValues);
    } else {
      await txn.update(
        'sync_book_files',
        fileValues,
        where: 'book_uid = ?',
        whereArgs: [binding.bookUid],
      );
    }
  }

  Future<bool> _remoteMatches(
    WebDavClient client,
    Uri uri,
    String expectedHash,
  ) async {
    final snapshot = await _downloadSnapshot(
      client,
      uri,
      'verification',
      origin: 'verify',
      recordInHistory: false,
      loadRevisionMetadata: false,
    );
    try {
      return snapshot.hash == expectedHash;
    } finally {
      if (await snapshot.file.exists()) await snapshot.file.delete();
    }
  }

  Future<_Snapshot> _downloadSnapshot(
    WebDavClient client,
    Uri uri,
    String bookUid, {
    required String origin,
    bool recordInHistory = true,
    bool loadRevisionMetadata = true,
  }) async {
    final root = await _rootDirectory();
    final partial = File(
      path.join(
        root.path,
        '.download-${_safeNonce()}-${_identitySegment(bookUid)}.part',
      ),
    );
    await client.downloadFile(uri, partial);
    final size = await partial.length();
    final hash = await _hashFile(partial);
    final textEncoding = loadRevisionMetadata
        ? await _remoteRevisionEncoding(client, bookUid, hash, partial)
        : await _detectValidatedTextEncoding(partial);
    if (!recordInHistory) {
      return _Snapshot(partial, hash, size, textEncoding: textEncoding);
    }
    final destination = await _revisionFile(bookUid, hash);
    if (!await destination.exists()) {
      await partial.copy(destination.path);
    }
    await partial.delete();
    return _Snapshot(destination, hash, size, textEncoding: textEncoding);
  }

  Future<_Snapshot> _snapshot(
    File source,
    String bookUid, {
    required String origin,
  }) async {
    if (!await source.exists()) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The local TXT file no longer exists.',
      );
    }
    final size = await source.length();
    final hash = await _hashFile(source);
    final destination = await _revisionFile(bookUid, hash);
    if (!await destination.exists()) {
      final partial = File('${destination.path}.${_safeNonce()}.part');
      await source.openRead().pipe(partial.openWrite());
      if (await _hashFile(partial) != hash) {
        await partial.delete();
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.localDataCorrupt,
          'The TXT snapshot failed checksum verification.',
        );
      }
      await partial.rename(destination.path);
    }
    return _Snapshot(destination, hash, size);
  }

  Future<File> _revisionFile(String bookUid, String hash) async {
    final root = await _rootDirectory();
    final directory = Directory(
      path.join(root.path, 'revisions', _identitySegment(bookUid)),
    );
    await directory.create(recursive: true);
    return File(path.join(directory.path, '$hash.txt'));
  }

  Future<TxtChunkStore> _chunkStore() async {
    final root = await _rootDirectory();
    return TxtChunkStore(Directory(path.join(root.path, 'chunks')));
  }

  Future<Directory> _rootDirectory() async {
    final directory = await _stateDirectory();
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _applyRemoteSnapshot(
    Database db,
    _Binding binding,
    _Snapshot snapshot,
    String etag,
  ) async {
    final remoteEncoding =
        snapshot.textEncoding ??
        await _detectValidatedTextEncoding(snapshot.file);
    final target = File(binding.localPath);
    final incoming = File('${target.path}.sync-${_safeNonce()}.part');
    final backup = File('${target.path}.sync-${_safeNonce()}.backup');
    await snapshot.file.openRead().pipe(incoming.openWrite());
    if (await _hashFile(incoming) != snapshot.hash) {
      await incoming.delete();
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'The downloaded TXT failed local checksum verification.',
      );
    }
    final originalHash = await _hashFile(target);
    final journalId = await db.insert('mutable_txt_apply_journal', {
      'book_uid': binding.bookUid,
      'target_path': target.path,
      'backup_path': backup.path,
      'incoming_path': incoming.path,
      'remote_hash': snapshot.hash,
      'original_hash': originalHash,
      'remote_etag': etag,
      'phase': 'prepared',
      'created_at': _utcNow(),
    });
    var businessCommitted = false;
    try {
      await target.rename(backup.path);
      await incoming.rename(target.path);
      await db.update(
        'mutable_txt_apply_journal',
        {'phase': 'replaced'},
        where: 'id = ?',
        whereArgs: [journalId],
      );
      await db.transaction((txn) async {
        await _invalidateBookCaches(
          txn,
          binding.localBookId,
          snapshot.hash,
          textEncoding: remoteEncoding,
        );
        await _markSyncedInTransaction(txn, binding, snapshot.hash, etag);
      });
      businessCommitted = true;
    } catch (_) {
      if (!businessCommitted) {
        if (await target.exists() && await backup.exists()) {
          await target.delete();
        }
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
      }
      rethrow;
    } finally {
      if (await incoming.exists()) await incoming.delete();
    }
    try {
      await db.update(
        'mutable_txt_apply_journal',
        {'phase': 'committed'},
        where: 'id = ?',
        whereArgs: [journalId],
      );
      await _committedBackupCleanup(backup);
      await db.delete(
        'mutable_txt_apply_journal',
        where: 'id = ?',
        whereArgs: [journalId],
      );
    } catch (_) {
      // Business state and file bytes are committed together. Recovery sees
      // the matching base hash and completes backup/journal cleanup later.
    }
    try {
      await _notifyRemoteApplied(db, binding.localBookId);
    } catch (_) {
      // Cache invalidation is committed in the database even if a listener
      // cannot be notified during this cycle.
    }
  }

  Future<void> _recoverApplyJournals(Database db) async {
    final rows = await db.query('mutable_txt_apply_journal', orderBy: 'id');
    for (final row in rows) {
      final id = row['id'] as int;
      final target = File(row['target_path'] as String);
      final backup = File(row['backup_path'] as String);
      final incoming = File(row['incoming_path'] as String);
      final remoteHash = row['remote_hash'] as String;
      final originalHash = row['original_hash'] as String?;
      final binding = await _binding(db, row['book_uid'] as String);
      final targetHash = await target.exists() ? await _hashFile(target) : null;
      String? businessHash;
      var requiresBusinessHash = false;
      if (binding?.localBookId != null) {
        final columns = (await db.rawQuery(
          'PRAGMA table_info(books)',
        )).map((column) => column['name'] as String).toSet();
        if (columns.contains('content_hash')) {
          requiresBusinessHash = true;
          final books = await db.query(
            'books',
            columns: ['content_hash'],
            where: 'id = ?',
            whereArgs: [binding!.localBookId],
            limit: 1,
          );
          businessHash = books.isEmpty
              ? null
              : books.single['content_hash'] as String?;
        }
      }
      final committed =
          targetHash == remoteHash &&
          binding?.baseHash == remoteHash &&
          (!requiresBusinessHash || businessHash == remoteHash);
      if (committed) {
        try {
          if (await backup.exists()) await backup.delete();
          if (await incoming.exists()) await incoming.delete();
          await db.delete(
            'mutable_txt_apply_journal',
            where: 'id = ?',
            whereArgs: [id],
          );
        } catch (_) {
          // The committed target is usable. Keep the journal so a later
          // startup can retry cleanup without rolling the file back.
        }
        continue;
      }
      if (await backup.exists()) {
        final backupHash = await _hashFile(backup);
        final expectedOriginalHash = originalHash ?? binding?.localHash;
        if (expectedOriginalHash != null &&
            backupHash != expectedOriginalHash) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.localDataCorrupt,
            'The TXT rollback copy failed checksum verification.',
          );
        }
        if (await target.exists()) await target.delete();
        await backup.rename(target.path);
        await db.transaction((txn) async {
          await _restoreBookCachesAfterRollback(txn, binding?.localBookId);
        });
      }
      if (await incoming.exists()) await incoming.delete();
      await db.delete(
        'mutable_txt_apply_journal',
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> _invalidateBookCaches(
    DatabaseExecutor db,
    int? localBookId,
    String hash, {
    required String textEncoding,
  }) async {
    if (localBookId == null) return;
    final columns = (await db.rawQuery(
      'PRAGMA table_info(books)',
    )).map((row) => row['name'] as String).toSet();
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name'] as String).toSet();
    if (columns.containsAll(const {
          'id',
          'title',
          'author',
          'filePath',
          'format',
          'importDate',
          'text_encoding',
          'last_canonical_locator',
          'last_rendered_locator',
          'layout_signature',
        }) &&
        tables.contains('book_notes') &&
        tables.contains('bookmarks')) {
      final rows = await db.query(
        'books',
        where: 'id = ?',
        whereArgs: [localBookId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final book = Book.fromMap(rows.single);
        await _referenceService.commitRevisionInTransaction(
          db,
          book: book,
          commit: TxtEditCommit(
            contentHash: hash,
            modifiedAt: _now(),
            textEncoding: textEncoding,
            invalidateAllReferences: true,
          ),
        );
        return;
      }
    }
    final values = <String, Object?>{};
    if (columns.contains('content_hash')) values['content_hash'] = hash;
    if (columns.contains('file_modified_time')) {
      values['file_modified_time'] = _now().millisecondsSinceEpoch;
    }
    if (columns.contains('cached_content')) values['cached_content'] = null;
    if (columns.contains('cached_pages')) values['cached_pages'] = null;
    if (columns.contains('table_of_contents')) {
      values['table_of_contents'] = null;
    }
    if (values.isNotEmpty) {
      await db.update(
        'books',
        values,
        where: 'id = ?',
        whereArgs: [localBookId],
      );
    }
    if (columns.contains('text_encoding')) {
      await db.update(
        'books',
        {'text_encoding': textEncoding},
        where: 'id = ?',
        whereArgs: [localBookId],
      );
    }
  }

  Future<void> _restoreBookCachesAfterRollback(
    DatabaseExecutor db,
    int? localBookId,
  ) async {
    if (localBookId == null) return;
    final columns = (await db.rawQuery(
      'PRAGMA table_info(books)',
    )).map((row) => row['name'] as String).toSet();
    final values = <String, Object?>{};
    if (columns.contains('cached_content')) values['cached_content'] = null;
    if (columns.contains('cached_pages')) values['cached_pages'] = null;
    if (columns.contains('table_of_contents')) {
      values['table_of_contents'] = null;
    }
    if (values.isNotEmpty) {
      await db.update(
        'books',
        values,
        where: 'id = ?',
        whereArgs: [localBookId],
      );
    }
  }

  Future<void> _updateBookEncoding(
    DatabaseExecutor db,
    int? localBookId,
    String textEncoding,
  ) async {
    if (localBookId == null) return;
    final columns = (await db.rawQuery(
      'PRAGMA table_info(books)',
    )).map((row) => row['name'] as String).toSet();
    if (!columns.contains('text_encoding')) return;
    await db.update(
      'books',
      {'text_encoding': textEncoding},
      where: 'id = ?',
      whereArgs: [localBookId],
    );
  }

  Future<String> _encodingForBinding(
    Database db,
    _Binding binding,
    File snapshot,
  ) async {
    if (binding.localBookId != null) {
      final columns = (await db.rawQuery(
        'PRAGMA table_info(books)',
      )).map((row) => row['name'] as String).toSet();
      if (columns.contains('text_encoding')) {
        final rows = await db.query(
          'books',
          columns: ['text_encoding'],
          where: 'id = ?',
          whereArgs: [binding.localBookId],
          limit: 1,
        );
        final encoding = EnhancedTxtImportService.normalizeEncoding(
          rows.isEmpty ? null : rows.single['text_encoding'] as String?,
        );
        if (encoding != 'auto') return encoding;
      }
    }
    return _detectValidatedTextEncoding(snapshot);
  }

  Future<void> _publishRevisionMetadata(
    WebDavClient client,
    String bookUid,
    String hash,
    String textEncoding,
  ) async {
    final uri = client.mutablePath([
      'revisions',
      _identitySegment(bookUid),
      '$hash.json',
    ]);
    final payload = jsonEncode({
      'version': 1,
      'sha256': hash,
      'textEncoding': textEncoding,
    });
    final root = await _rootDirectory();
    final file = File(path.join(root.path, '.metadata-${_safeNonce()}.json'));
    await file.writeAsString(payload, flush: true);
    try {
      try {
        await client.putFileConditionally(uri, file, ifNoneMatch: true);
      } on WebDavSyncFailure catch (error) {
        if (error.code != WebDavSyncErrorCode.conflict) rethrow;
        final existing = await client.getText(uri);
        final parsed = existing == null ? null : jsonDecode(existing);
        if (parsed is! Map ||
            parsed['version'] != 1 ||
            parsed['sha256'] != hash ||
            parsed['textEncoding'] != textEncoding) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'The immutable TXT revision metadata does not match its bytes.',
          );
        }
      }
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<String> _remoteRevisionEncoding(
    WebDavClient client,
    String bookUid,
    String hash,
    File file,
  ) async {
    final uri = client.mutablePath([
      'revisions',
      _identitySegment(bookUid),
      '$hash.json',
    ]);
    String? raw;
    try {
      raw = await client.getText(uri, allowNotFound: true);
    } on WebDavSyncFailure catch (error) {
      if (error.statusCode == 404 ||
          error.code == WebDavSyncErrorCode.notFound) {
        return _detectValidatedTextEncoding(file);
      }
      rethrow;
    }
    if (raw == null) return _detectValidatedTextEncoding(file);
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map ||
          parsed['version'] != 1 ||
          parsed['sha256'] != hash ||
          parsed['textEncoding'] is! String) {
        throw const FormatException();
      }
      final encoding = EnhancedTxtImportService.normalizeEncoding(
        parsed['textEncoding'] as String,
      );
      if (encoding == 'auto') throw const FormatException();
      await _validateFileForEncoding(file, encoding);
      return encoding;
    } on FormatException {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The TXT revision metadata is invalid.',
      );
    }
  }

  Future<void> _validateFileForEncoding(File file, String encoding) async {
    if (encoding == 'utf8') {
      try {
        await utf8.decoder.bind(file.openRead()).drain<void>();
        return;
      } on FormatException {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The remote TXT is not valid UTF-8.',
        );
      }
    }
    if (encoding == 'gbk') {
      if (await _isValidGbkFile(file)) return;
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The remote TXT is not valid GBK.',
      );
    }
    if (encoding == 'utf16le' || encoding == 'utf16be') {
      if (await _isValidUtf16File(file, littleEndian: encoding == 'utf16le')) {
        return;
      }
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The remote UTF-16 TXT has invalid code units.',
      );
    }
    throw const WebDavSyncFailure(
      WebDavSyncErrorCode.corruptRemoteData,
      'The TXT revision declares an unsupported encoding.',
    );
  }

  Future<String> _detectValidatedTextEncoding(File file) async {
    final handle = await file.open();
    late final Uint8List sample;
    try {
      sample = await handle.read(256 * 1024 + 4);
    } finally {
      await handle.close();
    }
    final hasUtf16LeBom =
        sample.length >= 2 && sample[0] == 0xff && sample[1] == 0xfe;
    final hasUtf16BeBom =
        sample.length >= 2 && sample[0] == 0xfe && sample[1] == 0xff;
    if (hasUtf16LeBom || hasUtf16BeBom) {
      final littleEndian = hasUtf16LeBom;
      if (await _isValidUtf16File(file, littleEndian: littleEndian)) {
        return hasUtf16LeBom ? 'utf16le' : 'utf16be';
      }
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The remote UTF-16 TXT has an incomplete code unit.',
      );
    }
    try {
      await utf8.decoder.bind(file.openRead()).drain<void>();
      return 'utf8';
    } on FormatException {
      final detected = EnhancedTxtImportService().detectEncoding(sample);
      if ((detected == 'utf16le' || detected == 'utf16be') &&
          _looksLikeUtf16WithoutBom(
            sample,
            littleEndian: detected == 'utf16le',
          ) &&
          await _isValidUtf16File(file, littleEndian: detected == 'utf16le')) {
        return detected;
      }
      if (detected == 'gbk' && await _isValidGbkFile(file)) return 'gbk';
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'Mutable TXT sync requires valid UTF-8 or validated UTF-16 bytes.',
      );
    }
  }

  Future<bool> _isValidGbkFile(File file) async {
    int? lead;
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (lead case final first?) {
          final pair = Uint8List.fromList([first, byte]);
          if (decodeGbkFast(pair, lenient: false).contains('\uFFFD')) {
            return false;
          }
          lead = null;
        } else if (byte <= 0x7f) {
          continue;
        } else {
          lead = byte;
        }
      }
    }
    return lead == null;
  }

  Future<bool> _isValidUtf16File(
    File file, {
    required bool littleEndian,
  }) async {
    int? firstByte;
    int? pendingHighSurrogate;
    var firstUnit = true;
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (firstByte == null) {
          firstByte = byte;
          continue;
        }
        final unit = littleEndian
            ? firstByte | (byte << 8)
            : (firstByte << 8) | byte;
        firstByte = null;
        if (firstUnit) {
          firstUnit = false;
          if (unit == 0xfeff) continue;
          if (unit == 0xfffe) return false;
        }
        if (pendingHighSurrogate != null) {
          if (unit < 0xdc00 || unit > 0xdfff) return false;
          pendingHighSurrogate = null;
        } else if (unit >= 0xd800 && unit <= 0xdbff) {
          pendingHighSurrogate = unit;
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
          return false;
        }
      }
    }
    return firstByte == null && pendingHighSurrogate == null;
  }

  bool _looksLikeUtf16WithoutBom(
    Uint8List sample, {
    required bool littleEndian,
  }) {
    if (sample.length < 8) return false;
    var evenZeros = 0;
    var oddZeros = 0;
    final pairs = sample.length ~/ 2;
    for (var index = 0; index + 1 < sample.length; index += 2) {
      if (sample[index] == 0) evenZeros++;
      if (sample[index + 1] == 0) oddZeros++;
    }
    final expectedZeros = littleEndian ? oddZeros : evenZeros;
    final unexpectedZeros = littleEndian ? evenZeros : oddZeros;
    return expectedZeros / pairs >= 0.25 && unexpectedZeros / pairs <= 0.05;
  }

  bool _isBookBusy(int? bookId) =>
      bookId != null &&
      (ReadingProgressSyncService.instance.isOpening(bookId) ||
          ReadingProgressSyncService.instance.isActive(bookId));

  Future<void> _notifyRemoteApplied(Database db, int? bookId) async {
    if (bookId == null) return;
    try {
      final rows = await db.query(
        'books',
        where: 'id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final book = Book.fromMap(rows.single);
      _onContentChanged(
        TxtContentChanged(
          book: book,
          contentHash: await _hashFile(File(book.filePath)),
          modifiedAt: _now(),
          origin: TxtContentChangeOrigin.remoteApply,
        ),
      );
    } catch (_) {
      // The file commit is authoritative. A UI notification failure must not
      // turn a verified remote apply into another upload or rollback.
    }
  }

  Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_bindings(
        book_uid TEXT PRIMARY KEY,
        local_book_id INTEGER,
        local_path TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        space_key TEXT NOT NULL,
        local_hash TEXT,
        base_hash TEXT,
        remote_etag TEXT,
        status TEXT NOT NULL,
        sync_enabled INTEGER NOT NULL DEFAULT 1,
        last_error TEXT,
        pending_remote_hash TEXT,
        pending_remote_path TEXT,
        pending_remote_etag TEXT,
        pending_remote_encoding TEXT,
        updated_at TEXT NOT NULL,
        protocol_mode TEXT NOT NULL DEFAULT 'plainV2'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_jobs(
        book_uid TEXT PRIMARY KEY,
        snapshot_path TEXT NOT NULL,
        snapshot_hash TEXT NOT NULL,
        base_hash TEXT,
        expected_etag TEXT,
        force_write INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    final bindingColumns = (await db.rawQuery(
      'PRAGMA table_info(mutable_txt_bindings)',
    )).map((row) => row['name'] as String).toSet();
    const extraBindingColumns = <String, String>{
      'space_key': "TEXT NOT NULL DEFAULT ''",
      'pending_remote_hash': 'TEXT',
      'pending_remote_path': 'TEXT',
      'pending_remote_etag': 'TEXT',
      'pending_remote_encoding': 'TEXT',
      'sync_enabled': 'INTEGER NOT NULL DEFAULT 1',
      'protocol_mode': "TEXT NOT NULL DEFAULT 'plainV2'",
    };
    for (final entry in extraBindingColumns.entries) {
      if (!bindingColumns.contains(entry.key)) {
        try {
          await db.execute(
            'ALTER TABLE mutable_txt_bindings ADD COLUMN ${entry.key} ${entry.value}',
          );
        } on DatabaseException {
          final currentColumns = (await db.rawQuery(
            'PRAGMA table_info(mutable_txt_bindings)',
          )).map((row) => row['name'] as String).toSet();
          if (!currentColumns.contains(entry.key)) rethrow;
        }
      }
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_revisions(
        book_uid TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        snapshot_path TEXT NOT NULL,
        origin TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY(book_uid, content_hash)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_conflicts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uid TEXT NOT NULL,
        space_key TEXT NOT NULL,
        base_hash TEXT,
        local_hash TEXT NOT NULL,
        remote_hash TEXT NOT NULL,
        local_snapshot_path TEXT NOT NULL,
        remote_snapshot_path TEXT NOT NULL,
        remote_etag TEXT NOT NULL,
        remote_encoding TEXT,
        created_at TEXT NOT NULL,
        resolved_at TEXT,
        resolution TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_mutable_txt_conflicts_open
      ON mutable_txt_conflicts(book_uid, resolved_at)
    ''');
    final conflictColumns = (await db.rawQuery(
      'PRAGMA table_info(mutable_txt_conflicts)',
    )).map((row) => row['name'] as String).toSet();
    if (!conflictColumns.contains('space_key')) {
      await db.execute(
        "ALTER TABLE mutable_txt_conflicts ADD COLUMN space_key TEXT NOT NULL DEFAULT ''",
      );
    }
    if (!conflictColumns.contains('remote_encoding')) {
      await db.execute(
        'ALTER TABLE mutable_txt_conflicts ADD COLUMN remote_encoding TEXT',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_spaces(
        space_key TEXT PRIMARY KEY,
        preconditions_verified_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_apply_journal(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uid TEXT NOT NULL,
        target_path TEXT NOT NULL,
        backup_path TEXT NOT NULL,
        incoming_path TEXT NOT NULL,
        remote_hash TEXT NOT NULL,
        original_hash TEXT,
        remote_etag TEXT NOT NULL,
        phase TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    final journalColumns = (await db.rawQuery(
      'PRAGMA table_info(mutable_txt_apply_journal)',
    )).map((row) => row['name'] as String).toSet();
    if (!journalColumns.contains('original_hash')) {
      await db.execute(
        'ALTER TABLE mutable_txt_apply_journal ADD COLUMN original_hash TEXT',
      );
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS mutable_txt_archived_bindings(
        space_key TEXT NOT NULL,
        book_uid TEXT NOT NULL,
        binding_json TEXT NOT NULL,
        job_json TEXT,
        archived_at TEXT NOT NULL,
        PRIMARY KEY(space_key, book_uid)
      )
    ''');
  }

  Future<List<_Binding>> _bindings(Database db, {String? bookUid}) async =>
      (await db.query(
        'mutable_txt_bindings',
        where: bookUid == null ? null : 'book_uid = ?',
        whereArgs: bookUid == null ? null : [bookUid],
        orderBy: 'book_uid',
      )).map(_Binding.fromRow).toList(growable: false);

  Future<_Binding?> _binding(Database db, String bookUid) async {
    final rows = await _bindings(db, bookUid: bookUid);
    return rows.isEmpty ? null : rows.single;
  }

  Future<void> _discoverLegacyBindings(Database db) async {
    final bookColumns = (await db.rawQuery(
      'PRAGMA table_info(books)',
    )).map((row) => row['name'] as String).toSet();
    if (!bookColumns.containsAll(const {
      'id',
      'format',
      'filePath',
      'title',
      'importDate',
    })) {
      return;
    }
    final rows = await db.rawQuery('''
      SELECT b.*, f.book_uid AS legacy_book_uid
      FROM sync_book_files f
      JOIN books b ON b.id = f.local_book_id
      LEFT JOIN mutable_txt_bindings m ON m.book_uid = f.book_uid
      WHERE f.sync_enabled = 1
        AND lower(b.format) = 'txt'
        AND m.book_uid IS NULL
    ''');
    for (final row in rows) {
      try {
        await join(
          Book.fromMap(row),
          bookUid: row['legacy_book_uid'] as String,
        );
      } catch (_) {
        // A missing/provider-owned file remains in the legacy protocol until
        // it becomes readable; unrelated bindings can still reconcile.
      }
    }
  }

  Future<void> _ensureMutableCapabilities(
    Database db,
    WebDavClient client,
    String spaceKey,
  ) async {
    final rows = await db.query(
      'mutable_txt_spaces',
      where: 'space_key = ?',
      whereArgs: [spaceKey],
      limit: 1,
    );
    if (rows.isNotEmpty) return;
    await client.verifyMutableWritePreconditions();
    await db.insert('mutable_txt_spaces', {
      'space_key': spaceKey,
      'preconditions_verified_at': _utcNow(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> _currentSpaceKeyOrNull() async {
    try {
      final credentials = await _configStore.readCredentials();
      return credentials == null ? null : _spaceKey(credentials.configuration);
    } catch (_) {
      return null;
    }
  }

  Future<void> _requireCurrentSpace(_Binding binding) async {
    final current = await _currentSpaceKeyOrNull();
    if (current == null || current != binding.spaceKey) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'This TXT binding belongs to another WebDAV space.',
      );
    }
  }

  Future<void> _activateBindingSpace(
    Database db, {
    required String bookUid,
    required int? localBookId,
    required String localPath,
    required String spaceKey,
  }) async {
    await db.transaction((txn) async {
      final activeRows = await txn.query(
        'mutable_txt_bindings',
        where: 'book_uid = ?',
        whereArgs: [bookUid],
        limit: 1,
      );
      if (activeRows.isNotEmpty && activeRows.single['space_key'] == spaceKey) {
        return;
      }
      if (activeRows.isNotEmpty) {
        final jobRows = await txn.query(
          'mutable_txt_jobs',
          where: 'book_uid = ?',
          whereArgs: [bookUid],
          limit: 1,
        );
        final active = Map<String, Object?>.from(activeRows.single);
        await txn.insert(
          'mutable_txt_archived_bindings',
          {
            'space_key': active['space_key'],
            'book_uid': bookUid,
            'binding_json': jsonEncode(active),
            'job_json': jobRows.isEmpty ? null : jsonEncode(jobRows.single),
            'archived_at': _utcNow(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.delete(
          'mutable_txt_jobs',
          where: 'book_uid = ?',
          whereArgs: [bookUid],
        );
        await txn.delete(
          'mutable_txt_bindings',
          where: 'book_uid = ?',
          whereArgs: [bookUid],
        );
      }
      final archivedRows = await txn.query(
        'mutable_txt_archived_bindings',
        where: 'space_key = ? AND book_uid = ?',
        whereArgs: [spaceKey, bookUid],
        limit: 1,
      );
      if (archivedRows.isEmpty) return;
      final archived = archivedRows.single;
      final binding =
          (jsonDecode(archived['binding_json'] as String) as Map)
              .cast<String, Object?>()
            ..['local_book_id'] = localBookId
            ..['local_path'] = localPath;
      await txn.insert('mutable_txt_bindings', binding);
      final rawJob = archived['job_json'] as String?;
      if (rawJob != null) {
        await txn.insert(
          'mutable_txt_jobs',
          (jsonDecode(rawJob) as Map).cast<String, Object?>(),
        );
      }
      await txn.delete(
        'mutable_txt_archived_bindings',
        where: 'space_key = ? AND book_uid = ?',
        whereArgs: [spaceKey, bookUid],
      );
    });
    await _repairMissingPendingJob(db, bookUid);
  }

  Future<void> _repairMissingPendingJob(Database db, String bookUid) async {
    final binding = await _binding(db, bookUid);
    if (binding == null || binding.status != MutableTxtSyncStatus.pending) {
      return;
    }
    final jobs = await db.query(
      'mutable_txt_jobs',
      where: 'book_uid = ?',
      whereArgs: [bookUid],
      limit: 1,
    );
    if (jobs.isNotEmpty) return;
    final revisions = await db.query(
      'mutable_txt_revisions',
      where: 'book_uid = ? AND content_hash = ?',
      whereArgs: [bookUid, binding.localHash],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    _Snapshot snapshot;
    if (revisions.isNotEmpty) {
      final file = File(revisions.single['snapshot_path'] as String);
      if (await file.exists() && await _hashFile(file) == binding.localHash) {
        snapshot = _Snapshot(file, binding.localHash!, await file.length());
      } else {
        snapshot = await _snapshot(
          File(binding.localPath),
          binding.bookUid,
          origin: 'local',
        );
      }
    } else {
      snapshot = await _snapshot(
        File(binding.localPath),
        binding.bookUid,
        origin: 'local',
      );
    }
    await db.transaction((txn) async {
      if (snapshot.hash != binding.localHash) {
        await txn.update(
          'mutable_txt_bindings',
          {'local_hash': snapshot.hash, 'updated_at': _utcNow()},
          where: 'book_uid = ? AND space_key = ?',
          whereArgs: [binding.bookUid, binding.spaceKey],
        );
      }
      await _putJob(
        txn,
        bookUid: binding.bookUid,
        snapshot: snapshot,
        baseHash: binding.baseHash,
        expectedEtag: binding.remoteEtag,
      );
      await _recordRevision(txn, binding.bookUid, snapshot, 'local');
    });
  }

  Future<void> _putJob(
    DatabaseExecutor db, {
    required String bookUid,
    required _Snapshot snapshot,
    required String? baseHash,
    String? expectedEtag,
    bool force = false,
  }) => db.insert('mutable_txt_jobs', {
    'book_uid': bookUid,
    'snapshot_path': snapshot.file.path,
    'snapshot_hash': snapshot.hash,
    'base_hash': baseHash,
    'expected_etag': expectedEtag,
    'force_write': force ? 1 : 0,
    'created_at': _utcNow(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _recordRevision(
    DatabaseExecutor db,
    String bookUid,
    _Snapshot snapshot,
    String origin,
  ) => db.insert('mutable_txt_revisions', {
    'book_uid': bookUid,
    'content_hash': snapshot.hash,
    'snapshot_path': snapshot.file.path,
    'origin': origin,
    'created_at': _utcNow(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> _updateConflictLocal(
    Database db,
    _Binding binding,
    _Snapshot snapshot,
  ) async {
    await db.transaction((txn) async {
      await txn.update(
        'mutable_txt_conflicts',
        {
          'local_hash': snapshot.hash,
          'local_snapshot_path': snapshot.file.path,
        },
        where: 'book_uid = ? AND space_key = ? AND resolved_at IS NULL',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      await txn.update(
        'mutable_txt_bindings',
        {
          'local_hash': snapshot.hash,
          'status': MutableTxtSyncStatus.conflict.name,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ? AND space_key = ?',
        whereArgs: [binding.bookUid, binding.spaceKey],
      );
      await _recordRevision(txn, binding.bookUid, snapshot, 'local');
    });
  }

  Future<void> _setPending(Database db, String bookUid) => db.update(
    'mutable_txt_bindings',
    {'status': MutableTxtSyncStatus.pending.name, 'updated_at': _utcNow()},
    where: 'book_uid = ?',
    whereArgs: [bookUid],
  );

  Future<StoredSyncCredentials> _credentials() async {
    final credentials = await _configStore.readCredentials();
    if (credentials == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.authentication,
        'WebDAV is not configured or its secure password is unavailable.',
      );
    }
    return credentials;
  }

  void _validateBook(Book book, String bookUid) {
    if (bookUid.trim().isEmpty ||
        book.isOnline ||
        book.format.toLowerCase() != 'txt') {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Mutable file sync currently supports local TXT books with stable identity.',
      );
    }
  }

  String _utcNow() => _now().toUtc().toIso8601String();
  String _safeNonce() =>
      '$pid-${_now().microsecondsSinceEpoch}-'
      '${Random.secure().nextInt(1 << 32)}';
}

String _spaceKey(WebDavSyncConfiguration configuration) => sha256
    .convert(
      utf8.encode(
        '${configuration.serverUrl.trim()}\n${configuration.username.trim()}\n${configuration.rootPath.trim()}',
      ),
    )
    .toString();

final _contentHashPattern = RegExp(r'^[0-9a-f]{64}$');

String _currentRemotePath(
  String bookUid, [
  MutableTxtSyncMode mode = MutableTxtSyncMode.plainV2,
]) => mode == MutableTxtSyncMode.chunkedV3
    ? 'v3:books/${_identitySegment(bookUid)}/current.json'
    : 'v2:books/${_identitySegment(bookUid)}/current.txt';

String _identitySegment(String bookUid) =>
    base64Url.encode(utf8.encode(bookUid)).replaceAll('=', '');

String _requireStrongEtag(String? etag) {
  final value = etag?.trim();
  if (value == null || value.isEmpty || value.startsWith('W/')) {
    throw const WebDavSyncFailure(
      WebDavSyncErrorCode.serverIncompatible,
      'Safe editable TXT sync requires a strong WebDAV ETag.',
    );
  }
  return value;
}

Future<String> _hashFile(File file) async =>
    '${await sha256.bind(file.openRead()).first}';

MutableTxtConflict _conflictFromRow(Map<String, Object?> row) =>
    MutableTxtConflict(
      id: row['id'] as int,
      bookUid: row['book_uid'] as String,
      spaceKey: row['space_key'] as String,
      localHash: row['local_hash'] as String,
      remoteHash: row['remote_hash'] as String,
      localSnapshotPath: row['local_snapshot_path'] as String,
      remoteSnapshotPath: row['remote_snapshot_path'] as String,
      remoteEtag: row['remote_etag'] as String,
      remoteEncoding: row['remote_encoding'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );

class _Snapshot {
  const _Snapshot(this.file, this.hash, this.size, {this.textEncoding});

  final File file;
  final String hash;
  final int size;
  final String? textEncoding;
}

class _Binding {
  const _Binding({
    required this.bookUid,
    required this.localBookId,
    required this.localPath,
    required this.remotePath,
    required this.localHash,
    required this.baseHash,
    required this.remoteEtag,
    required this.status,
    required this.error,
    required this.spaceKey,
    required this.pendingRemoteHash,
    required this.pendingRemotePath,
    required this.pendingRemoteEtag,
    required this.pendingRemoteEncoding,
    required this.enabled,
    required this.mode,
  });

  factory _Binding.fromRow(Map<String, Object?> row) => _Binding(
    bookUid: row['book_uid'] as String,
    localBookId: row['local_book_id'] as int?,
    localPath: row['local_path'] as String,
    remotePath: row['remote_path'] as String,
    localHash: row['local_hash'] as String?,
    baseHash: row['base_hash'] as String?,
    remoteEtag: row['remote_etag'] as String?,
    status: MutableTxtSyncStatus.values.byName(row['status'] as String),
    error: row['last_error'] as String?,
    spaceKey: row['space_key'] as String,
    pendingRemoteHash: row['pending_remote_hash'] as String?,
    pendingRemotePath: row['pending_remote_path'] as String?,
    pendingRemoteEtag: row['pending_remote_etag'] as String?,
    pendingRemoteEncoding: row['pending_remote_encoding'] as String?,
    enabled: row['sync_enabled'] == 1,
    mode: MutableTxtSyncMode.values.byName(
      (row['protocol_mode'] as String?) ?? MutableTxtSyncMode.plainV2.name,
    ),
  );

  final String bookUid;
  final int? localBookId;
  final String localPath;
  final String remotePath;
  final String? localHash;
  final String? baseHash;
  final String? remoteEtag;
  final MutableTxtSyncStatus status;
  final String? error;
  final String spaceKey;
  final String? pendingRemoteHash;
  final String? pendingRemotePath;
  final String? pendingRemoteEtag;
  final String? pendingRemoteEncoding;
  final bool enabled;
  final MutableTxtSyncMode mode;

  MutableTxtBookState get publicState => MutableTxtBookState(
    bookUid: bookUid,
    localBookId: localBookId,
    localPath: localPath,
    remotePath: remotePath,
    status: status,
    localHash: localHash,
    baseHash: baseHash,
    remoteEtag: remoteEtag,
    error: error,
    pendingRemoteHash: pendingRemoteHash,
    enabled: enabled,
    mode: mode,
  );
}

class _Job {
  const _Job({
    required this.snapshotPath,
    required this.snapshotHash,
    required this.baseHash,
    required this.expectedEtag,
    required this.force,
  });

  factory _Job.fromRow(Map<String, Object?> row) => _Job(
    snapshotPath: row['snapshot_path'] as String,
    snapshotHash: row['snapshot_hash'] as String,
    baseHash: row['base_hash'] as String?,
    expectedEtag: row['expected_etag'] as String?,
    force: row['force_write'] == 1,
  );

  final String snapshotPath;
  final String snapshotHash;
  final String? baseHash;
  final String? expectedEtag;
  final bool force;
}

enum _BookOutcome { unchanged, uploaded, downloaded, conflict }
