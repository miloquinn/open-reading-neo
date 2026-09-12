// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../book_sources/services/source_chapter_state.dart';
import '../../models/book.dart';
import '../books/book_storage_codec.dart';
import '../books/txt_content_change_bus.dart';
import '../books/txt_edit_reference_service.dart';
import '../books/txt_edit_service.dart';
import '../core/database_service.dart';
import 'reading_progress_sync_service.dart';
import 'storage/sync_storage.dart';
import 'sync_models.dart';

enum BookContentSyncStatus {
  localOnly,
  paused,
  pending,
  syncing,
  synced,
  updateAvailable,
  conflict,
  failed,
}

enum BookContentConflictChoice { keepLocal, useRemote }

class BookContentState {
  const BookContentState({
    required this.bookUid,
    required this.localBookId,
    required this.localPath,
    required this.remotePath,
    required this.status,
    this.localHash,
    this.baseHash,
    this.remoteVersion,
    this.error,
    this.pendingRemoteHash,
    this.enabled = true,
  });
  final String bookUid;
  final int? localBookId;
  final String localPath;
  final String remotePath;
  final BookContentSyncStatus status;
  final String? localHash;
  final String? baseHash;
  final String? remoteVersion;
  final String? error;
  final String? pendingRemoteHash;
  final bool enabled;
}

class BookContentConflict {
  const BookContentConflict({
    required this.id,
    required this.bookUid,
    required this.spaceKey,
    required this.localHash,
    required this.remoteHash,
    required this.localSnapshotPath,
    required this.remoteSnapshotPath,
    required this.remoteVersion,
    required this.headVersion,
    required this.createdAt,
  });
  final int id;
  final String bookUid;
  final String spaceKey;
  final String localHash;
  final String remoteHash;
  final String localSnapshotPath;
  final String remoteSnapshotPath;
  final String remoteVersion;
  final String? headVersion;
  final DateTime createdAt;
}

class BookContentRevision {
  const BookContentRevision({
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

class BookContentReconcileResult {
  const BookContentReconcileResult({
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

/// Provider-neutral synchronization for complete, directly readable book
/// files. There is one mutable current file, one CAS head and immutable,
/// readable history. A content hash is a revision, never a book identity.
class BookContentSyncService {
  BookContentSyncService({
    SyncStorageProvider? storageProvider,
    DatabaseService? databaseService,
    Future<Database> Function()? database,
    Future<Directory> Function()? stateDirectory,
    DateTime Function()? now,
    void Function(TxtContentChanged event)? onContentChanged,
    TxtEditReferenceService? referenceService,
    SourceChapterStateStore? sourceStateStore,
    Future<void> Function(File backup)? committedBackupCleanup,
  }) : _storageProvider = storageProvider ?? _noStorage,
       _databaseService = databaseService ?? DatabaseService(),
       _databaseProvider = database,
       _stateDirectory = stateDirectory ?? _defaultStateDirectory,
       _now = now ?? DateTime.now,
       _committedBackupCleanup = committedBackupCleanup ?? _deleteBackup,
       _onContentChanged =
           onContentChanged ?? TxtContentChangeBus.instance.notify {
    _referenceService =
        referenceService ??
        TxtEditReferenceService(databaseProvider: () => _database);
    _sourceStateStore = sourceStateStore ?? const SourceChapterStateStore();
  }

  final SyncStorageProvider _storageProvider;
  final DatabaseService _databaseService;
  final Future<Database> Function()? _databaseProvider;
  final Future<Directory> Function() _stateDirectory;
  final DateTime Function() _now;
  final Future<void> Function(File backup) _committedBackupCleanup;
  final void Function(TxtContentChanged event) _onContentChanged;
  late final TxtEditReferenceService _referenceService;
  late final SourceChapterStateStore _sourceStateStore;
  Future<BookContentReconcileResult>? _activeReconcile;

  Future<Database> get _database =>
      _databaseProvider?.call() ?? _databaseService.database;

  static Future<SyncStorage?> _noStorage() async => null;
  static Future<Directory> _defaultStateDirectory() async => Directory(
    path.join(
      (await getApplicationSupportDirectory()).path,
      'sync',
      'book_content',
    ),
  );
  static Future<void> _deleteBackup(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<void> recoverLocalState() async {
    final db = await _database;
    await _ensureSchema(db);
    await _recoverJournals(db);
  }

  Future<void> join(Book book, {required String bookUid}) async {
    _validateBook(book, bookUid);
    final source = File(book.filePath);
    if (!await source.exists()) throw _notFound();
    final db = await _database;
    await _ensureSchema(db);
    await _recoverJournals(db);
    final old = await _binding(db, bookUid);
    final snapshot = await _snapshot(source, bookUid, origin: 'local');
    final sourceBundle = await _sourceBundle(book, expectedBookUid: bookUid);
    final storage = await _storageProvider();
    final spaceKey = storage?.spaceKey ?? old?.spaceKey ?? '';
    final folder = old?.folderName ?? _folderName(book, bookUid);
    final original = path.basename(book.filePath);
    final extension = _extension(book.format, original);
    await db.transaction((txn) async {
      await _archiveIfSpaceChanged(txn, old, spaceKey);
      await txn.insert('book_content_bindings', {
        'book_uid': bookUid,
        'local_book_id': book.id,
        'local_path': book.filePath,
        'folder_name': folder,
        'original_file_name': old?.originalFileName ?? original,
        'format': book.format.toLowerCase(),
        'current_path': old?.currentPath ?? 'books/$folder/current.$extension',
        'space_key': spaceKey,
        'enabled': old?.enabled == false ? 0 : 1,
        'status': old?.enabled == false
            ? BookContentSyncStatus.paused.name
            : BookContentSyncStatus.pending.name,
        'local_hash': snapshot.hash,
        'source_state_hash': sourceBundle.hash,
        'base_source_state_hash': old?.spaceKey == spaceKey
            ? old?.baseSourceStateHash
            : null,
        'base_hash': old?.spaceKey == spaceKey ? old?.baseHash : null,
        'remote_version': old?.spaceKey == spaceKey ? old?.remoteVersion : null,
        'head_version': old?.spaceKey == spaceKey ? old?.headVersion : null,
        'created_at': old?.createdAt ?? _utcNow(),
        'updated_at': _utcNow(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _recordRevision(txn, bookUid, snapshot, 'local');
      await _putJob(txn, bookUid, snapshot, sourceBundle.hash);
    });
  }

  Future<void> enqueueLocalUpdate(
    Book book, {
    required String bookUid,
    String origin = 'local',
  }) async {
    _validateBook(book, bookUid);
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null) return join(book, bookUid: bookUid);
    final snapshot = await _snapshot(
      File(book.filePath),
      bookUid,
      origin: origin,
    );
    final sourceBundle = await _sourceBundle(book, expectedBookUid: bookUid);
    await db.transaction((txn) async {
      await _recordRevision(txn, bookUid, snapshot, origin);
      final changed =
          snapshot.hash != binding.baseHash ||
          sourceBundle.hash != binding.baseSourceStateHash;
      if (changed) {
        await _putJob(txn, bookUid, snapshot, sourceBundle.hash);
      }
      await txn.update(
        'book_content_bindings',
        {
          'local_hash': snapshot.hash,
          'source_state_hash': sourceBundle.hash,
          'status': binding.enabled
              ? (!changed
                    ? BookContentSyncStatus.synced.name
                    : BookContentSyncStatus.pending.name)
              : BookContentSyncStatus.paused.name,
          'error': null,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ?',
        whereArgs: [bookUid],
      );
    });
  }

  Future<BookContentReconcileResult> reconcile({
    String? bookUid,
    bool Function()? shouldContinue,
  }) {
    final active = _activeReconcile;
    if (active != null) return active;
    final future = _runReconcile(bookUid, shouldContinue);
    _activeReconcile = future;
    return future.whenComplete(() {
      if (identical(_activeReconcile, future)) _activeReconcile = null;
    });
  }

  Future<BookContentReconcileResult> _runReconcile(
    String? bookUid,
    bool Function()? shouldContinue,
  ) async {
    final db = await _database;
    await _ensureSchema(db);
    await _recoverJournals(db);
    var bindings = await _bindings(db, bookUid);
    if (bindings.where((b) => b.enabled).isEmpty) return _emptyResult;
    final storage = await _storageProvider();
    if (storage == null) {
      for (final b in bindings.where((b) => b.enabled)) {
        await _setState(db, b.bookUid, BookContentSyncStatus.localOnly);
      }
      return _emptyResult;
    }
    if (!storage.capabilities.strongVersions) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.serverIncompatible,
        'Book content sync requires strong conditional object versions.',
      );
    }
    var up = 0, down = 0, conflicts = 0, failed = 0, bytes = 0;
    for (var binding in bindings.where((b) => b.enabled)) {
      if (shouldContinue?.call() == false) break;
      try {
        binding = await _activateSpace(db, binding, storage.spaceKey);
        final result = await _reconcileBook(db, storage, binding);
        if (result.uploaded) up++;
        if (result.downloaded) down++;
        if (result.conflict) conflicts++;
        bytes += result.uploadedBytes;
      } catch (error) {
        failed++;
        await _setState(
          db,
          binding.bookUid,
          BookContentSyncStatus.failed,
          error: _safeError(error),
        );
      }
    }
    return BookContentReconcileResult(
      uploaded: up,
      downloaded: down,
      conflicts: conflicts,
      failed: failed,
      uploadedBytes: bytes,
    );
  }

  static const _emptyResult = BookContentReconcileResult(
    uploaded: 0,
    downloaded: 0,
    conflicts: 0,
    failed: 0,
  );

  Future<_Outcome> _reconcileBook(
    Database db,
    SyncStorage storage,
    _Binding binding,
  ) async {
    final local = File(binding.localPath);
    if (!await local.exists()) throw _notFound();
    final localSnapshot = await _snapshot(
      local,
      binding.bookUid,
      origin: 'local',
    );
    final localBook = await _bookForBinding(db, binding);
    final sourceBundle = localBook == null
        ? const _SourceBundle(null, <SourceStateAsset>[])
        : await _sourceBundle(localBook, expectedBookUid: binding.bookUid);
    binding = binding.copyWith(
      localHash: localSnapshot.hash,
      sourceStateHash: sourceBundle.hash,
    );
    await db.update(
      'book_content_bindings',
      {
        'local_hash': localSnapshot.hash,
        'source_state_hash': sourceBundle.hash,
        'status': BookContentSyncStatus.syncing.name,
        'error': null,
        'updated_at': _utcNow(),
      },
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );

    final remotePaths = _RemotePaths(binding);
    final infos = await Future.wait([
      storage.stat(remotePaths.current),
      storage.stat(remotePaths.head),
    ]);
    final currentInfo = infos[0];
    final headInfo = infos[1];
    if (currentInfo == null && headInfo == null) {
      return _push(db, storage, binding, localSnapshot, null, null);
    }
    if (currentInfo == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'book.json exists but the readable current book is missing.',
      );
    }
    var remote = await _readRemote(storage, binding, currentInfo, headInfo);
    final job = await _job(db, binding.bookUid);

    // A process may stop after publishing current but before publishing its
    // head. Only the exact durable pending revision is allowed to repair it.
    if (job?.targetHash == remote.snapshot.hash &&
        localSnapshot.hash == remote.snapshot.hash &&
        remote.headHash != remote.snapshot.hash) {
      return _finishPendingHead(db, storage, binding, localSnapshot, remote);
    }
    if (!remote.headMatchesCurrent) {
      if (binding.observedMismatchVersion != remote.currentInfo.version.value) {
        await _stageRemote(
          db,
          binding,
          remote,
          BookContentSyncStatus.updateAvailable,
        );
        await db.update(
          'book_content_bindings',
          {
            'observed_mismatch_version': remote.currentInfo.version.value,
            'observed_mismatch_at': _utcNow(),
          },
          where: 'book_uid = ?',
          whereArgs: [binding.bookUid],
        );
        return const _Outcome();
      }
      remote = await _adoptExternalCurrent(storage, binding, remote);
    }
    if (localSnapshot.hash == remote.snapshot.hash &&
        sourceBundle.hash == remote.sourceStateHash) {
      await _markSynced(
        db,
        binding,
        localSnapshot.hash,
        remote.currentInfo.version,
        remote.headInfo?.version,
        localSnapshot.size,
        remote.sourceStateHash,
      );
      return const _Outcome();
    }
    if (localSnapshot.hash == remote.snapshot.hash) {
      if (sourceBundle.hash == null && remote.sourceStateHash != null) {
        return _acceptRemote(db, binding, remote);
      }
      if (sourceBundle.hash != null && remote.sourceStateHash == null) {
        return _publishSourceAndHead(
          db,
          storage,
          binding,
          localSnapshot,
          sourceBundle,
          remote,
        );
      }
      if (binding.baseSourceStateHash == remote.sourceStateHash) {
        return _publishSourceAndHead(
          db,
          storage,
          binding,
          localSnapshot,
          sourceBundle,
          remote,
        );
      }
      if (binding.baseSourceStateHash == sourceBundle.hash) {
        return _acceptRemote(db, binding, remote);
      }
      return _recordConflict(db, binding, localSnapshot, remote);
    }
    if (binding.baseHash == remote.snapshot.hash) {
      return _push(
        db,
        storage,
        binding,
        localSnapshot,
        remote.currentInfo,
        remote.headInfo,
      );
    }
    if (binding.baseHash == localSnapshot.hash) {
      return _acceptRemote(db, binding, remote);
    }
    return _recordConflict(db, binding, localSnapshot, remote);
  }

  Future<_Outcome> _push(
    Database db,
    SyncStorage storage,
    _Binding binding,
    _Snapshot snapshot,
    SyncObjectInfo? currentInfo,
    SyncObjectInfo? headInfo,
  ) async {
    final remotePaths = _RemotePaths(binding);
    final history = remotePaths.history(snapshot.hash);
    await _ensureImmutable(storage, history, snapshot);
    final localBook = await _bookForBinding(db, binding);
    final sourceBundle = localBook == null
        ? const _SourceBundle(null, <SourceStateAsset>[])
        : await _sourceBundle(localBook, expectedBookUid: binding.bookUid);
    // Publish immutable/hash-bound source assets before current. If the
    // process stops after current, an old head is never paired with new text.
    await _publishSourceAssets(storage, binding, sourceBundle);
    final currentWrite = currentInfo == null
        ? await storage.create(
            remotePaths.current,
            snapshot.file.openRead(),
            length: snapshot.size,
            contentType: _contentType(binding.format),
          )
        : await storage.compareAndSwap(
            remotePaths.current,
            snapshot.file.openRead(),
            length: snapshot.size,
            contentType: _contentType(binding.format),
            expectedVersion: currentInfo.version,
          );
    await _verifyObject(
      storage,
      remotePaths.current,
      snapshot.hash,
      currentWrite.info.version,
    );
    final headBytes = _headBytes(
      binding,
      snapshot,
      history,
      currentWrite.info.version,
      sourceBundle.hash,
      await _sourceDigests(sourceBundle),
    );
    final headWrite = headInfo == null
        ? await storage.create(
            remotePaths.head,
            Stream.value(headBytes),
            length: headBytes.length,
            contentType: 'application/json; charset=utf-8',
          )
        : await storage.compareAndSwap(
            remotePaths.head,
            Stream.value(headBytes),
            length: headBytes.length,
            contentType: 'application/json; charset=utf-8',
            expectedVersion: headInfo.version,
          );
    await _verifyHead(
      storage,
      remotePaths.head,
      headWrite.info.version,
      snapshot.hash,
      currentWrite.info.version,
      currentPath: binding.currentPath,
      size: snapshot.size,
      historyPath: history.value,
    );
    await _markSynced(
      db,
      binding,
      snapshot.hash,
      currentWrite.info.version,
      headWrite.info.version,
      snapshot.size,
      sourceBundle.hash,
    );
    return _Outcome(uploaded: true, uploadedBytes: snapshot.size);
  }

  Future<_Outcome> _finishPendingHead(
    Database db,
    SyncStorage storage,
    _Binding binding,
    _Snapshot snapshot,
    _Remote remote,
  ) async {
    final paths = _RemotePaths(binding);
    final history = paths.history(snapshot.hash);
    await _ensureImmutable(storage, history, snapshot);
    final localBook = await _bookForBinding(db, binding);
    final sourceBundle = localBook == null
        ? const _SourceBundle(null, <SourceStateAsset>[])
        : await _sourceBundle(localBook, expectedBookUid: binding.bookUid);
    await _publishSourceAssets(storage, binding, sourceBundle);
    final bytes = _headBytes(
      binding,
      snapshot,
      history,
      remote.currentInfo.version,
      sourceBundle.hash,
      await _sourceDigests(sourceBundle),
    );
    final write = remote.headInfo == null
        ? await storage.create(
            paths.head,
            Stream.value(bytes),
            length: bytes.length,
            contentType: 'application/json; charset=utf-8',
          )
        : await storage.compareAndSwap(
            paths.head,
            Stream.value(bytes),
            length: bytes.length,
            contentType: 'application/json; charset=utf-8',
            expectedVersion: remote.headInfo!.version,
          );
    await _verifyHead(
      storage,
      paths.head,
      write.info.version,
      snapshot.hash,
      remote.currentInfo.version,
      currentPath: binding.currentPath,
      size: snapshot.size,
      historyPath: history.value,
    );
    await _markSynced(
      db,
      binding,
      snapshot.hash,
      remote.currentInfo.version,
      write.info.version,
      snapshot.size,
      sourceBundle.hash,
    );
    return const _Outcome();
  }

  Future<_Remote> _readRemote(
    SyncStorage storage,
    _Binding binding,
    SyncObjectInfo currentInfo,
    SyncObjectInfo? headInfo,
  ) async {
    Map<String, dynamic>? head;
    SyncTextRead? headRead;
    if (headInfo != null) {
      headRead = await storage.readText(
        _RemotePaths(binding).head,
        expectedVersion: headInfo.version,
      );
      try {
        head = (jsonDecode(headRead.text) as Map).cast<String, dynamic>();
      } catch (_) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'book.json is not valid JSON.',
        );
      }
      if (head['schema_version'] != 1 || head['book_uid'] != binding.bookUid) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'book.json does not describe this book.',
        );
      }
    }
    final snapshot = await _downloadSnapshot(
      storage,
      SyncPath(binding.currentPath),
      binding.bookUid,
      currentInfo.version,
      origin: head == null || head['current_sha256'] != null
          ? 'remote'
          : 'external_cloud_edit',
    );
    final headMatchesCurrent =
        head?['current_sha256'] == snapshot.hash &&
        head?['current_version'] == currentInfo.version.value &&
        head?['current_path'] == binding.currentPath &&
        head?['current_size'] == snapshot.size;
    final remoteSource = headMatchesCurrent
        ? await _readSourceSidecar(
            storage,
            binding,
            head?['source_state_sha256'] as String?,
            (head?['source_assets'] as List? ?? const <Object>[]),
          )
        : null;
    return _Remote(
      snapshot: snapshot,
      currentInfo: currentInfo,
      headInfo: headRead?.info,
      headHash: head?['current_sha256'] as String?,
      headMatchesCurrent: headMatchesCurrent,
      sourceStateHash: remoteSource?.hash,
      sourceStateJson: remoteSource?.json,
      sourceAssets: remoteSource?.assets ?? const <String, List<int>>{},
    );
  }

  Future<_Outcome> _acceptRemote(
    Database db,
    _Binding binding,
    _Remote remote,
  ) async {
    if (_isBusy(binding.localBookId)) {
      await _stageRemote(
        db,
        binding,
        remote,
        BookContentSyncStatus.updateAvailable,
      );
      return const _Outcome();
    }
    await _applyRemote(db, binding, remote);
    return const _Outcome(downloaded: true);
  }

  Future<_Remote> _adoptExternalCurrent(
    SyncStorage storage,
    _Binding binding,
    _Remote remote,
  ) async {
    final paths = _RemotePaths(binding);
    final history = paths.history(remote.snapshot.hash);
    await _ensureImmutable(storage, history, remote.snapshot);
    final bytes = _headBytes(
      binding,
      remote.snapshot,
      history,
      remote.currentInfo.version,
      remote.sourceStateHash,
      remote.sourceAssets.entries
          .map(
            (entry) => _SourceAssetDigest(
              'source/revisions/${remote.sourceStateHash}/${entry.key.substring('source/'.length)}',
              sha256.convert(entry.value).toString(),
              entry.key,
            ),
          )
          .toList(growable: false),
    );
    final write = remote.headInfo == null
        ? await storage.create(
            paths.head,
            Stream.value(bytes),
            length: bytes.length,
            contentType: 'application/json; charset=utf-8',
          )
        : await storage.compareAndSwap(
            paths.head,
            Stream.value(bytes),
            length: bytes.length,
            contentType: 'application/json; charset=utf-8',
            expectedVersion: remote.headInfo!.version,
          );
    await _verifyHead(
      storage,
      paths.head,
      write.info.version,
      remote.snapshot.hash,
      remote.currentInfo.version,
      currentPath: binding.currentPath,
      size: remote.snapshot.size,
      historyPath: history.value,
    );
    return _Remote(
      snapshot: remote.snapshot,
      currentInfo: remote.currentInfo,
      headInfo: write.info,
      headHash: remote.snapshot.hash,
      headMatchesCurrent: true,
      sourceStateHash: remote.sourceStateHash,
      sourceStateJson: remote.sourceStateJson,
      sourceAssets: remote.sourceAssets,
    );
  }

  Future<_Outcome> _recordConflict(
    Database db,
    _Binding binding,
    _Snapshot local,
    _Remote remote,
  ) async {
    await db.transaction((txn) async {
      await txn.insert('book_content_conflicts', {
        'book_uid': binding.bookUid,
        'space_key': binding.spaceKey,
        'local_hash': local.hash,
        'remote_hash': remote.snapshot.hash,
        'local_snapshot_path': local.file.path,
        'remote_snapshot_path': remote.snapshot.file.path,
        'remote_version': remote.currentInfo.version.value,
        'head_version': remote.headInfo?.version.value,
        'created_at': _utcNow(),
      });
      await _stageRemote(txn, binding, remote, BookContentSyncStatus.conflict);
    });
    return const _Outcome(conflict: true);
  }

  Future<void> _stageRemote(
    DatabaseExecutor db,
    _Binding binding,
    _Remote remote,
    BookContentSyncStatus status,
  ) => db.update(
    'book_content_bindings',
    {
      'status': status.name,
      'pending_remote_hash': remote.snapshot.hash,
      'pending_remote_path': remote.snapshot.file.path,
      'pending_remote_version': remote.currentInfo.version.value,
      'pending_head_version': remote.headInfo?.version.value,
      'pending_source_state_hash': remote.sourceStateHash,
      'pending_source_state_json': remote.sourceStateJson,
      'pending_source_assets_json': remote.sourceAssets.isEmpty
          ? null
          : jsonEncode(
              remote.sourceAssets.map(
                (key, bytes) => MapEntry(key, base64Encode(bytes)),
              ),
            ),
      'error': null,
      'updated_at': _utcNow(),
    },
    where: 'book_uid = ?',
    whereArgs: [binding.bookUid],
  );

  Future<List<BookContentState>> listStates() async {
    final db = await _database;
    await _ensureSchema(db);
    return (await _bindings(db, null)).map((b) => b.publicState).toList();
  }

  Future<List<BookContentConflict>> listConflicts({String? bookUid}) async {
    final db = await _database;
    await _ensureSchema(db);
    final rows = await db.query(
      'book_content_conflicts',
      where: bookUid == null
          ? 'resolved_at IS NULL'
          : 'book_uid = ? AND resolved_at IS NULL',
      whereArgs: bookUid == null ? null : [bookUid],
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(_conflictFromRow).toList();
  }

  Future<List<BookContentRevision>> listHistory(String bookUid) async {
    final db = await _database;
    await _ensureSchema(db);
    final rows = await db.query(
      'book_content_revisions',
      where: 'book_uid = ?',
      whereArgs: [bookUid],
      orderBy: 'created_at DESC',
    );
    return rows
        .map(
          (row) => BookContentRevision(
            bookUid: row['book_uid'] as String,
            hash: row['content_hash'] as String,
            snapshotPath: row['snapshot_path'] as String,
            origin: row['origin'] as String,
            createdAt: DateTime.parse(row['created_at'] as String),
          ),
        )
        .toList();
  }

  Future<void> setEnabled(String bookUid, bool enabled) async {
    final db = await _database;
    await _ensureSchema(db);
    await db.update(
      'book_content_bindings',
      {
        'enabled': enabled ? 1 : 0,
        'status': enabled
            ? BookContentSyncStatus.pending.name
            : BookContentSyncStatus.paused.name,
        'error': null,
        'updated_at': _utcNow(),
      },
      where: 'book_uid = ?',
      whereArgs: [bookUid],
    );
    await db.update(
      'sync_book_files',
      {'sync_enabled': enabled ? 1 : 0, 'updated_at': _utcNow()},
      where: 'book_uid = ?',
      whereArgs: [bookUid],
    );
  }

  Future<void> resolveConflict(
    int conflictId,
    BookContentConflictChoice choice,
  ) async {
    final db = await _database;
    await _ensureSchema(db);
    final rows = await db.query(
      'book_content_conflicts',
      where: 'id = ? AND resolved_at IS NULL',
      whereArgs: [conflictId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final conflict = _conflictFromRow(rows.single);
    final binding = await _binding(db, conflict.bookUid);
    if (binding == null) return;
    if (choice == BookContentConflictChoice.useRemote) {
      if (_isBusy(binding.localBookId)) {
        await _setState(
          db,
          binding.bookUid,
          BookContentSyncStatus.updateAvailable,
        );
      } else {
        final storage = await _storageProvider();
        if (storage == null) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.invalidConfiguration,
            'Cloud storage is not configured.',
          );
        }
        await _applyRemote(
          db,
          binding,
          await _remoteFromConflict(storage, binding, conflict),
        );
      }
    } else {
      final file = File(conflict.localSnapshotPath);
      if (!await file.exists() || await _hashFile(file) != conflict.localHash) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.localDataCorrupt,
          'The local conflict snapshot is unavailable or damaged.',
        );
      }
      final snapshot = _Snapshot(file, conflict.localHash, await file.length());
      await db.transaction((txn) async {
        await _putJob(txn, binding.bookUid, snapshot, binding.sourceStateHash);
        await txn.update(
          'book_content_bindings',
          {
            'local_hash': conflict.localHash,
            'base_hash': conflict.remoteHash,
            'remote_version': conflict.remoteVersion,
            'status': BookContentSyncStatus.pending.name,
            'pending_remote_hash': null,
            'pending_remote_path': null,
            'pending_remote_version': null,
            'pending_head_version': null,
            'updated_at': _utcNow(),
          },
          where: 'book_uid = ?',
          whereArgs: [binding.bookUid],
        );
      });
    }
    await db.update(
      'book_content_conflicts',
      {'resolved_at': _utcNow(), 'resolution': choice.name},
      where: 'id = ?',
      whereArgs: [conflictId],
    );
  }

  Future<bool> applyAvailableUpdate(String bookUid) async {
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding == null || binding.pendingRemotePath == null) return false;
    if (_isBusy(binding.localBookId)) return false;
    final file = File(binding.pendingRemotePath!);
    if (!await file.exists() ||
        await _hashFile(file) != binding.pendingRemoteHash ||
        binding.pendingRemoteVersion == null) {
      await _setState(
        db,
        bookUid,
        BookContentSyncStatus.failed,
        error: 'The staged cloud revision is unavailable or damaged.',
      );
      return false;
    }
    final remote = _Remote(
      snapshot: _Snapshot(
        file,
        binding.pendingRemoteHash!,
        await file.length(),
      ),
      currentInfo: SyncObjectInfo(
        path: SyncPath(binding.currentPath),
        version: SyncObjectVersion(binding.pendingRemoteVersion!),
        length: await file.length(),
      ),
      headInfo: binding.pendingHeadVersion == null
          ? null
          : SyncObjectInfo(
              path: _RemotePaths(binding).head,
              version: SyncObjectVersion(binding.pendingHeadVersion!),
              length: 0,
            ),
      headHash: binding.pendingRemoteHash,
      headMatchesCurrent: true,
      sourceStateHash: binding.pendingSourceStateHash,
      sourceStateJson: binding.pendingSourceStateJson,
      sourceAssets: binding.pendingSourceAssets,
    );
    await _applyRemote(db, binding, remote);
    return true;
  }

  Future<bool> applyPendingRemote(String bookUid) =>
      applyAvailableUpdate(bookUid);

  Future<_Remote> _remoteFromConflict(
    SyncStorage storage,
    _Binding binding,
    BookContentConflict conflict,
  ) async {
    final paths = _RemotePaths(binding);
    final current = await storage.stat(paths.current);
    final head = await storage.stat(paths.head);
    if (current?.version.value != conflict.remoteVersion ||
        head?.version.value != conflict.headVersion) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The cloud book changed again while the conflict was open.',
      );
    }
    final remote = await _readRemote(storage, binding, current!, head);
    if (remote.snapshot.hash != conflict.remoteHash ||
        remote.headHash != conflict.remoteHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The cloud conflict revision no longer matches its snapshot.',
      );
    }
    return remote;
  }

  Future<_SourceBundle> _sourceBundle(
    Book book, {
    required String expectedBookUid,
  }) async {
    SourceChapterState? state;
    try {
      state = await _sourceStateStore.load(book);
    } catch (_) {
      return const _SourceBundle(null, <SourceStateAsset>[]);
    }
    if (state != null) {
      final contentHash = await _hashFile(File(book.filePath));
      if (state.bookUid != expectedBookUid ||
          state.materializedContentHash != contentHash ||
          (book.sourceId != null && state.sourceId != book.sourceId) ||
          (book.sourceBookId != null &&
              state.sourceBookId != book.sourceBookId)) {
        return const _SourceBundle(null, <SourceStateAsset>[]);
      }
    }
    final assets = await _sourceStateStore.enumerateAssets(book);
    if (assets.isEmpty) return const _SourceBundle(null, <SourceStateAsset>[]);
    final hashes = <String>[];
    for (final asset in assets) {
      hashes.add('${asset.relativePath}:${await _hashFile(asset.file)}');
    }
    return _SourceBundle(
      sha256.convert(utf8.encode(hashes.join('\n'))).toString(),
      assets,
    );
  }

  Future<List<_SourceAssetDigest>> _sourceDigests(_SourceBundle bundle) async {
    final result = <_SourceAssetDigest>[];
    for (final asset in bundle.assets) {
      final remotePath = bundle.hash == null
          ? asset.relativePath
          : 'source/revisions/${bundle.hash}/${asset.relativePath.substring('source/'.length)}';
      result.add(
        _SourceAssetDigest(
          remotePath,
          await _hashFile(asset.file),
          asset.relativePath,
        ),
      );
    }
    return result;
  }

  Future<Book?> _bookForBinding(Database db, _Binding binding) async {
    if (binding.localBookId == null) return null;
    final rows = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [binding.localBookId],
      limit: 1,
    );
    return rows.isEmpty ? null : bookFromStorageMap(rows.single);
  }

  Future<void> _restoreSourceAssets(
    Book book,
    Map<String, List<int>> assets,
  ) async {
    final directory = _sourceStateStore.assetDirectoryFor(book);
    for (final entry in assets.entries) {
      if (!entry.key.startsWith('source/history/')) continue;
      final relative = entry.key.substring('source/history/'.length);
      if (relative.isEmpty ||
          path.isAbsolute(relative) ||
          path.split(relative).any((segment) => segment == '..')) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'A source asset has an unsafe path.',
        );
      }
      final target = File(path.join(directory.path, relative));
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        if (sha256.convert(await target.readAsBytes()).toString() !=
            sha256.convert(entry.value).toString()) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'A source history asset conflicts with a local immutable asset.',
          );
        }
        continue;
      }
      await target.writeAsBytes(entry.value, flush: true);
    }
  }

  Future<void> _publishSourceAssets(
    SyncStorage storage,
    _Binding binding,
    _SourceBundle bundle,
  ) async {
    for (final asset in bundle.assets) {
      final relative = bundle.hash == null
          ? asset.relativePath
          : 'source/revisions/${bundle.hash}/${asset.relativePath.substring('source/'.length)}';
      final remote = SyncPath('books/${binding.folderName}/$relative');
      final snapshot = _Snapshot(
        asset.file,
        await _hashFile(asset.file),
        await asset.file.length(),
      );
      await _ensureImmutable(storage, remote, snapshot);
    }
  }

  Future<_RemoteSource?> _readSourceSidecar(
    SyncStorage storage,
    _Binding binding,
    String? expectedBundleHash,
    List<dynamic> rawAssets,
  ) async {
    if (expectedBundleHash == null) return null;
    final digests = rawAssets
        .map((raw) {
          final json = (raw as Map).cast<String, dynamic>();
          return _SourceAssetDigest(
            json['path'] as String,
            json['sha256'] as String,
            json['restore_path'] as String,
          );
        })
        .toList(growable: false);
    final calculated = sha256
        .convert(
          utf8.encode(
            digests
                .map((asset) => '${asset.restorePath}:${asset.hash}')
                .join('\n'),
          ),
        )
        .toString();
    if (calculated != expectedBundleHash ||
        !digests.any((asset) => asset.restorePath == 'source/book.json')) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The source asset manifest does not match book.json.',
      );
    }
    final assets = <String, List<int>>{};
    for (final digest in digests) {
      final remote = SyncPath('books/${binding.folderName}/${digest.path}');
      final info = await storage.stat(remote);
      if (info == null) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'book.json references a missing source asset.',
        );
      }
      final temp = await _temporaryFile('source');
      try {
        final sink = temp.openWrite();
        try {
          await storage.download(remote, sink, expectedVersion: info.version);
        } finally {
          await sink.close();
        }
        final bytes = await temp.readAsBytes();
        if (sha256.convert(bytes).toString() != digest.hash) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'A source asset failed checksum verification.',
          );
        }
        assets[digest.restorePath] = bytes;
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
    final json = utf8.decode(assets['source/book.json']!);
    return _RemoteSource(expectedBundleHash, json, assets);
  }

  Future<_Outcome> _publishSourceAndHead(
    Database db,
    SyncStorage storage,
    _Binding binding,
    _Snapshot snapshot,
    _SourceBundle bundle,
    _Remote remote,
  ) async {
    await _publishSourceAssets(storage, binding, bundle);
    final paths = _RemotePaths(binding);
    final history = paths.history(snapshot.hash);
    await _ensureImmutable(storage, history, snapshot);
    final bytes = _headBytes(
      binding,
      snapshot,
      history,
      remote.currentInfo.version,
      bundle.hash,
      await _sourceDigests(bundle),
    );
    final write = remote.headInfo == null
        ? await storage.create(
            paths.head,
            Stream.value(bytes),
            length: bytes.length,
            contentType: 'application/json; charset=utf-8',
          )
        : await storage.compareAndSwap(
            paths.head,
            Stream.value(bytes),
            length: bytes.length,
            contentType: 'application/json; charset=utf-8',
            expectedVersion: remote.headInfo!.version,
          );
    await _verifyHead(
      storage,
      paths.head,
      write.info.version,
      snapshot.hash,
      remote.currentInfo.version,
      currentPath: binding.currentPath,
      size: snapshot.size,
      historyPath: history.value,
    );
    await _markSynced(
      db,
      binding,
      snapshot.hash,
      remote.currentInfo.version,
      write.info.version,
      snapshot.size,
      bundle.hash,
    );
    return const _Outcome();
  }

  Future<void> _ensureImmutable(
    SyncStorage storage,
    SyncPath remotePath,
    _Snapshot snapshot,
  ) async {
    var info = await storage.stat(remotePath);
    if (info == null) {
      try {
        final write = await storage.create(
          remotePath,
          snapshot.file.openRead(),
          length: snapshot.size,
          contentType: _contentType(path.extension(snapshot.file.path)),
        );
        info = write.info;
      } on SyncStorageException catch (error) {
        if (error.code != SyncStorageErrorCode.versionConflict) rethrow;
        info = await storage.stat(remotePath);
      }
    }
    if (info == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'A cloud history revision disappeared during verification.',
      );
    }
    await _verifyObject(storage, remotePath, snapshot.hash, info.version);
  }

  Future<void> _verifyObject(
    SyncStorage storage,
    SyncPath remotePath,
    String expectedHash,
    SyncObjectVersion expectedVersion,
  ) async {
    final temp = await _temporaryFile('verify');
    try {
      final sink = temp.openWrite();
      try {
        await storage.download(
          remotePath,
          sink,
          expectedVersion: expectedVersion,
        );
      } finally {
        await sink.close();
      }
      if (await _hashFile(temp) != expectedHash) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The cloud object failed checksum verification.',
        );
      }
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<void> _verifyHead(
    SyncStorage storage,
    SyncPath path,
    SyncObjectVersion version,
    String expectedHash,
    SyncObjectVersion currentVersion, {
    required String currentPath,
    required int size,
    required String historyPath,
  }) async {
    final read = await storage.readText(path, expectedVersion: version);
    final json = (jsonDecode(read.text) as Map).cast<String, dynamic>();
    if (json['current_sha256'] != expectedHash ||
        json['current_version'] != currentVersion.value ||
        json['current_path'] != currentPath ||
        json['current_size'] != size ||
        json['history_path'] != historyPath) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'book.json does not match the verified readable current file.',
      );
    }
  }

  Future<_Snapshot> _downloadSnapshot(
    SyncStorage storage,
    SyncPath remotePath,
    String bookUid,
    SyncObjectVersion expectedVersion, {
    required String origin,
  }) async {
    final temp = await _temporaryFile('remote');
    final sink = temp.openWrite();
    late SyncDownload result;
    try {
      result = await storage.download(
        remotePath,
        sink,
        expectedVersion: expectedVersion,
      );
    } finally {
      await sink.close();
    }
    if (result.info.version != expectedVersion) {
      if (await temp.exists()) await temp.delete();
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The cloud book changed while it was being read.',
      );
    }
    final hash = await _hashFile(temp);
    final revision = await _revisionFile(
      bookUid,
      hash,
      path.extension(remotePath.value),
    );
    if (!await revision.exists()) await temp.copy(revision.path);
    await temp.delete();
    if (await _hashFile(revision) != hash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'A downloaded revision snapshot is damaged.',
      );
    }
    final snapshot = _Snapshot(revision, hash, await revision.length());
    await _recordRevision(await _database, bookUid, snapshot, origin);
    return snapshot;
  }

  Future<_Snapshot> _snapshot(
    File source,
    String bookUid, {
    required String origin,
  }) async {
    if (!await source.exists()) throw _notFound();
    final hash = await _hashFile(source);
    final revision = await _revisionFile(
      bookUid,
      hash,
      path.extension(source.path),
    );
    if (!await revision.exists()) {
      await source.copy(revision.path);
    } else if (await _hashFile(revision) != hash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'A local revision snapshot is damaged.',
      );
    }
    return _Snapshot(revision, hash, await revision.length());
  }

  Future<void> _applyRemote(
    Database db,
    _Binding binding,
    _Remote remote,
  ) async {
    final target = File(binding.localPath);
    final incoming = File('${target.path}.sync-${_nonce()}.part');
    final backup = File('${target.path}.sync-${_nonce()}.backup');
    await remote.snapshot.file.copy(incoming.path);
    if (await _hashFile(incoming) != remote.snapshot.hash) {
      await incoming.delete();
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'The downloaded book failed local checksum verification.',
      );
    }
    final originalHash = await target.exists() ? await _hashFile(target) : null;
    final localBook = await _bookForBinding(db, binding);
    final sourceSidecar = localBook == null
        ? null
        : _sourceStateStore.sidecarFor(localBook);
    final sourceSidecarExisted =
        sourceSidecar != null && await sourceSidecar.exists();
    final sourceBackup = sourceSidecar == null
        ? null
        : File('${sourceSidecar.path}.sync-${_nonce()}.backup');
    if (sourceSidecarExisted) await sourceSidecar.copy(sourceBackup!.path);
    final journalId = await db.insert('book_content_apply_journal', {
      'book_uid': binding.bookUid,
      'target_path': target.path,
      'backup_path': backup.path,
      'incoming_path': incoming.path,
      'remote_hash': remote.snapshot.hash,
      'original_hash': originalHash,
      'remote_version': remote.currentInfo.version.value,
      'source_path': sourceSidecar?.path,
      'source_backup_path': sourceBackup?.path,
      'source_existed': sourceSidecarExisted ? 1 : 0,
      'phase': 'prepared',
      'created_at': _utcNow(),
    });
    var committed = false;
    try {
      if (await target.exists()) await target.rename(backup.path);
      await incoming.rename(target.path);
      if (localBook != null && remote.sourceStateJson != null) {
        await _restoreSourceAssets(localBook, remote.sourceAssets);
        await _sourceStateStore.importSidecar(
          book: localBook,
          json: remote.sourceStateJson!,
        );
      } else if (localBook != null &&
          sourceSidecar != null &&
          await sourceSidecar.exists()) {
        final staleDirectory = _sourceStateStore.assetDirectoryFor(localBook);
        await staleDirectory.create(recursive: true);
        final staleHash = await _hashFile(sourceSidecar);
        final stale = File(
          path.join(staleDirectory.path, 'stale-sidecar-$staleHash.json'),
        );
        if (!await stale.exists()) await sourceSidecar.copy(stale.path);
        await sourceSidecar.delete();
      }
      await db.update(
        'book_content_apply_journal',
        {'phase': 'replaced'},
        where: 'id = ?',
        whereArgs: [journalId],
      );
      await db.transaction((txn) async {
        if (binding.format == 'txt') {
          await _invalidateTxtReferences(
            txn,
            binding.localBookId,
            remote.snapshot.hash,
          );
        } else {
          await _invalidateBookCaches(
            txn,
            binding.localBookId,
            remote.snapshot.hash,
          );
        }
        await _markSyncedInTransaction(
          txn,
          binding,
          remote.snapshot.hash,
          remote.currentInfo.version,
          remote.headInfo?.version,
          remote.snapshot.size,
          remote.sourceStateHash,
        );
      });
      committed = true;
    } catch (_) {
      if (!committed && await backup.exists()) {
        if (await target.exists()) await target.delete();
        await backup.rename(target.path);
      }
      if (!committed && sourceSidecar != null) {
        if (!sourceSidecarExisted) {
          if (await sourceSidecar.exists()) await sourceSidecar.delete();
        } else if (sourceBackup != null && await sourceBackup.exists()) {
          await sourceBackup.copy(sourceSidecar.path);
        }
      }
      rethrow;
    } finally {
      if (await incoming.exists()) await incoming.delete();
    }
    try {
      await db.update(
        'book_content_apply_journal',
        {'phase': 'committed'},
        where: 'id = ?',
        whereArgs: [journalId],
      );
      await _committedBackupCleanup(backup);
      if (sourceBackup != null && await sourceBackup.exists()) {
        await sourceBackup.delete();
      }
      await db.delete(
        'book_content_apply_journal',
        where: 'id = ?',
        whereArgs: [journalId],
      );
    } catch (_) {
      // A later recovery pass completes cleanup without rolling back bytes.
    }
    if (binding.localBookId != null) {
      final rows = await db.query(
        'books',
        where: 'id = ?',
        whereArgs: [binding.localBookId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        _onContentChanged(
          TxtContentChanged(
            book: await bookFromStorageMap(rows.single),
            contentHash: remote.snapshot.hash,
            modifiedAt: _now(),
            origin: TxtContentChangeOrigin.remoteApply,
          ),
        );
      }
    }
  }

  Future<void> _recoverJournals(Database db) async {
    final rows = await db.query('book_content_apply_journal', orderBy: 'id');
    for (final row in rows) {
      final id = row['id'] as int;
      final target = File(row['target_path'] as String);
      final backup = File(row['backup_path'] as String);
      final incoming = File(row['incoming_path'] as String);
      final remoteHash = row['remote_hash'] as String;
      final sourcePath = row['source_path'] as String?;
      final sourceBackupPath = row['source_backup_path'] as String?;
      final sourceExisted = (row['source_existed'] as int? ?? 0) != 0;
      final binding = await _binding(db, row['book_uid'] as String);
      final targetHash = await target.exists() ? await _hashFile(target) : null;
      if (targetHash == remoteHash && binding?.baseHash == remoteHash) {
        try {
          if (await backup.exists()) await backup.delete();
          if (await incoming.exists()) await incoming.delete();
          if (sourceBackupPath != null) {
            final sourceBackup = File(sourceBackupPath);
            if (await sourceBackup.exists()) await sourceBackup.delete();
          }
          await db.delete(
            'book_content_apply_journal',
            where: 'id = ?',
            whereArgs: [id],
          );
        } catch (_) {}
        continue;
      }
      if (await backup.exists()) {
        final expected = row['original_hash'] as String?;
        if (expected != null && await _hashFile(backup) != expected) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.localDataCorrupt,
            'The rollback copy failed checksum verification.',
          );
        }
        if (await target.exists()) await target.delete();
        await backup.rename(target.path);
        await _invalidateBookCaches(db, binding?.localBookId, expected);
      }
      if (await incoming.exists()) await incoming.delete();
      if (sourcePath != null) {
        final source = File(sourcePath);
        final sourceBackup = sourceBackupPath == null
            ? null
            : File(sourceBackupPath);
        if (sourceExisted &&
            sourceBackup != null &&
            await sourceBackup.exists()) {
          await sourceBackup.copy(source.path);
          await sourceBackup.delete();
        } else if (!sourceExisted && await source.exists()) {
          await source.delete();
        }
      }
      await db.delete(
        'book_content_apply_journal',
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> _invalidateTxtReferences(
    DatabaseExecutor db,
    int? bookId,
    String hash,
  ) async {
    if (bookId == null) return;
    final tables = await _tableNames(db);
    final columns = await _columnNames(db, 'books');
    if (tables.containsAll(const {'book_notes', 'bookmarks'}) &&
        columns.containsAll(const {
          'id',
          'title',
          'author',
          'filePath',
          'format',
          'importDate',
          'last_canonical_locator',
          'last_rendered_locator',
          'layout_signature',
        })) {
      final rows = await db.query(
        'books',
        where: 'id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final book = await bookFromStorageMap(rows.single);
        await _referenceService.commitRevisionInTransaction(
          db,
          book: book,
          commit: TxtEditCommit(
            contentHash: hash,
            modifiedAt: _now(),
            textEncoding: await _detectTextEncoding(File(book.filePath)),
            invalidateAllReferences: true,
          ),
        );
        return;
      }
    }
    await _invalidateBookCaches(db, bookId, hash);
  }

  Future<void> _invalidateBookCaches(
    DatabaseExecutor db,
    int? bookId,
    String? hash,
  ) async {
    if (bookId == null) return;
    final columns = await _columnNames(db, 'books');
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
      await db.update('books', values, where: 'id = ?', whereArgs: [bookId]);
    }
  }

  Future<void> _markSynced(
    Database db,
    _Binding binding,
    String hash,
    SyncObjectVersion currentVersion,
    SyncObjectVersion? headVersion,
    int size,
    String? sourceStateHash,
  ) => db.transaction(
    (txn) => _markSyncedInTransaction(
      txn,
      binding,
      hash,
      currentVersion,
      headVersion,
      size,
      sourceStateHash,
    ),
  );

  Future<void> _markSyncedInTransaction(
    DatabaseExecutor db,
    _Binding binding,
    String hash,
    SyncObjectVersion currentVersion,
    SyncObjectVersion? headVersion,
    int size,
    String? sourceStateHash,
  ) async {
    // A missing head version means current is readable but not committed.
    if (headVersion == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The current book has no verified book.json commit.',
      );
    }
    await db.update(
      'book_content_bindings',
      {
        'status': BookContentSyncStatus.synced.name,
        'local_hash': hash,
        'base_hash': hash,
        'remote_version': currentVersion.value,
        'head_version': headVersion.value,
        'source_state_hash': sourceStateHash,
        'base_source_state_hash': sourceStateHash,
        'pending_remote_hash': null,
        'pending_remote_path': null,
        'pending_remote_version': null,
        'pending_head_version': null,
        'pending_source_state_hash': null,
        'pending_source_state_json': null,
        'pending_source_assets_json': null,
        'observed_mismatch_version': null,
        'observed_mismatch_at': null,
        'error': null,
        'updated_at': _utcNow(),
      },
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    await db.delete(
      'book_content_jobs',
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    await db.insert('sync_book_files', {
      'book_uid': binding.bookUid,
      'local_book_id': binding.localBookId,
      'blob_sha256': hash,
      'file_name': binding.originalFileName,
      'file_size': size,
      'remote_path': binding.currentPath,
      'sync_enabled': binding.enabled ? 1 : 0,
      'updated_at': _utcNow(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  List<int> _headBytes(
    _Binding binding,
    _Snapshot snapshot,
    SyncPath history,
    SyncObjectVersion currentVersion,
    String? sourceStateHash,
    List<_SourceAssetDigest> sourceAssets,
  ) => utf8.encode(
    jsonEncode({
      'protocol': 'open-reading-book-content',
      'schema_version': 1,
      'book_uid': binding.bookUid,
      'folder_name': binding.folderName,
      'title': binding.title,
      'author': binding.author,
      'format': binding.format,
      'original_file_name': binding.originalFileName,
      'current_path': binding.currentPath,
      'current_sha256': snapshot.hash,
      'current_size': snapshot.size,
      'current_revision': snapshot.hash,
      'current_version': currentVersion.value,
      'source_state_sha256': sourceStateHash,
      'source_assets': sourceAssets
          .map(
            (asset) => {
              'path': asset.path,
              'sha256': asset.hash,
              'restore_path': asset.restorePath,
            },
          )
          .toList(growable: false),
      'history_path': history.value,
      'updated_at': _utcNow(),
    }),
  );

  Future<_Binding> _activateSpace(
    Database db,
    _Binding binding,
    String spaceKey,
  ) async {
    if (binding.spaceKey == spaceKey) return binding;
    await db.transaction((txn) async {
      await _archiveIfSpaceChanged(txn, binding, spaceKey);
      await txn.update(
        'book_content_bindings',
        {
          'space_key': spaceKey,
          'base_hash': null,
          'remote_version': null,
          'head_version': null,
          'pending_remote_hash': null,
          'pending_remote_path': null,
          'pending_remote_version': null,
          'pending_head_version': null,
          'pending_source_state_hash': null,
          'pending_source_state_json': null,
          'pending_source_assets_json': null,
          'observed_mismatch_version': null,
          'observed_mismatch_at': null,
          'status': BookContentSyncStatus.pending.name,
          'updated_at': _utcNow(),
        },
        where: 'book_uid = ?',
        whereArgs: [binding.bookUid],
      );
    });
    return binding.copyWith(
      spaceKey: spaceKey,
      status: BookContentSyncStatus.pending,
      clearRemote: true,
    );
  }

  Future<void> _archiveIfSpaceChanged(
    DatabaseExecutor db,
    _Binding? binding,
    String spaceKey,
  ) async {
    if (binding == null ||
        binding.spaceKey.isEmpty ||
        binding.spaceKey == spaceKey) {
      return;
    }
    await db.insert('book_content_archived_bindings', {
      'book_uid': binding.bookUid,
      'space_key': binding.spaceKey,
      'base_hash': binding.baseHash,
      'remote_version': binding.remoteVersion,
      'head_version': binding.headVersion,
      'archived_at': _utcNow(),
    });
  }

  Future<void> _ensureSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_content_bindings(
        book_uid TEXT PRIMARY KEY,
        local_book_id INTEGER,
        local_path TEXT NOT NULL,
        folder_name TEXT NOT NULL,
        original_file_name TEXT NOT NULL,
        format TEXT NOT NULL,
        current_path TEXT NOT NULL,
        space_key TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL,
        local_hash TEXT,
        base_hash TEXT,
        remote_version TEXT,
        head_version TEXT,
        pending_remote_hash TEXT,
        pending_remote_path TEXT,
        pending_remote_version TEXT,
        pending_head_version TEXT,
        source_state_hash TEXT,
        base_source_state_hash TEXT,
        pending_source_state_hash TEXT,
        pending_source_state_json TEXT,
        pending_source_assets_json TEXT,
        observed_mismatch_version TEXT,
        observed_mismatch_at TEXT,
        error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_content_jobs(
        book_uid TEXT PRIMARY KEY,
        target_hash TEXT NOT NULL,
        snapshot_path TEXT NOT NULL,
        source_state_hash TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_content_revisions(
        book_uid TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        snapshot_path TEXT NOT NULL,
        origin TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY(book_uid, content_hash)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_content_conflicts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uid TEXT NOT NULL,
        space_key TEXT NOT NULL,
        local_hash TEXT NOT NULL,
        remote_hash TEXT NOT NULL,
        local_snapshot_path TEXT NOT NULL,
        remote_snapshot_path TEXT NOT NULL,
        remote_version TEXT NOT NULL,
        source_path TEXT,
        source_backup_path TEXT,
        source_existed INTEGER NOT NULL DEFAULT 0,
        head_version TEXT,
        created_at TEXT NOT NULL,
        resolved_at TEXT,
        resolution TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_content_apply_journal(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uid TEXT NOT NULL,
        target_path TEXT NOT NULL,
        backup_path TEXT NOT NULL,
        incoming_path TEXT NOT NULL,
        remote_hash TEXT NOT NULL,
        original_hash TEXT,
        remote_version TEXT NOT NULL,
        source_path TEXT,
        source_backup_path TEXT,
        source_existed INTEGER NOT NULL DEFAULT 0,
        phase TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS book_content_archived_bindings(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_uid TEXT NOT NULL,
        space_key TEXT NOT NULL,
        base_hash TEXT,
        remote_version TEXT,
        head_version TEXT,
        archived_at TEXT NOT NULL
      )
    ''');
    await _ensureColumns(db, 'book_content_bindings', const {
      'source_state_hash': 'TEXT',
      'base_source_state_hash': 'TEXT',
      'pending_source_state_hash': 'TEXT',
      'pending_source_state_json': 'TEXT',
      'pending_source_assets_json': 'TEXT',
      'observed_mismatch_version': 'TEXT',
      'observed_mismatch_at': 'TEXT',
    });
    await _ensureColumns(db, 'book_content_jobs', const {
      'source_state_hash': 'TEXT',
    });
    await _ensureColumns(db, 'book_content_apply_journal', const {
      'source_path': 'TEXT',
      'source_backup_path': 'TEXT',
      'source_existed': 'INTEGER NOT NULL DEFAULT 0',
    });
  }

  Future<void> _ensureColumns(
    Database db,
    String table,
    Map<String, String> definitions,
  ) async {
    final columns = await _columnNames(db, table);
    for (final entry in definitions.entries) {
      if (!columns.contains(entry.key)) {
        await db.execute(
          'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}',
        );
      }
    }
  }

  Future<List<_Binding>> _bindings(Database db, String? bookUid) async {
    final rows = await db.rawQuery('''
      SELECT c.*, b.title AS book_title, b.author AS book_author
      FROM book_content_bindings c
      LEFT JOIN books b ON b.id = c.local_book_id
      ${bookUid == null ? '' : 'WHERE c.book_uid = ?'}
      ORDER BY c.created_at
    ''', bookUid == null ? null : [bookUid]);
    return rows.map(_Binding.fromRow).toList();
  }

  Future<_Binding?> _binding(Database db, String bookUid) async {
    final rows = await _bindings(db, bookUid);
    return rows.isEmpty ? null : rows.single;
  }

  Future<_Job?> _job(Database db, String bookUid) async {
    final rows = await db.query(
      'book_content_jobs',
      where: 'book_uid = ?',
      whereArgs: [bookUid],
      limit: 1,
    );
    return rows.isEmpty ? null : _Job.fromRow(rows.single);
  }

  Future<void> _putJob(
    DatabaseExecutor db,
    String bookUid,
    _Snapshot snapshot,
    String? sourceStateHash,
  ) => db.insert('book_content_jobs', {
    'book_uid': bookUid,
    'target_hash': snapshot.hash,
    'snapshot_path': snapshot.file.path,
    'source_state_hash': sourceStateHash,
    'updated_at': _utcNow(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> _recordRevision(
    DatabaseExecutor db,
    String bookUid,
    _Snapshot snapshot,
    String origin,
  ) => db.insert('book_content_revisions', {
    'book_uid': bookUid,
    'content_hash': snapshot.hash,
    'snapshot_path': snapshot.file.path,
    'origin': origin,
    'created_at': _utcNow(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> _setState(
    Database db,
    String bookUid,
    BookContentSyncStatus status, {
    String? error,
  }) => db.update(
    'book_content_bindings',
    {'status': status.name, 'error': error, 'updated_at': _utcNow()},
    where: 'book_uid = ?',
    whereArgs: [bookUid],
  );

  Future<File> _revisionFile(
    String bookUid,
    String hash,
    String extension,
  ) async {
    final dir = Directory(
      path.join(
        (await _rootDirectory()).path,
        'revisions',
        _safeSegment(bookUid),
      ),
    );
    await dir.create(recursive: true);
    final ext = extension.isEmpty ? '.bin' : extension;
    return File(path.join(dir.path, '$hash$ext'));
  }

  Future<File> _temporaryFile(String prefix) async {
    final dir = Directory(
      path.join((await _rootDirectory()).path, 'temporary'),
    );
    await dir.create(recursive: true);
    return File(path.join(dir.path, '$prefix-${_nonce()}.part'));
  }

  Future<Directory> _rootDirectory() async {
    final root = await _stateDirectory();
    await root.create(recursive: true);
    return root;
  }

  Future<Set<String>> _columnNames(DatabaseExecutor db, String table) async =>
      (await db.rawQuery(
        'PRAGMA table_info($table)',
      )).map((row) => row['name'] as String).toSet();
  Future<Set<String>> _tableNames(DatabaseExecutor db) async =>
      (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name'] as String).toSet();

  bool _isBusy(int? bookId) =>
      bookId != null &&
      (ReadingProgressSyncService.instance.isOpening(bookId) ||
          ReadingProgressSyncService.instance.isActive(bookId));

  Future<String> _detectTextEncoding(File file) async {
    final length = await file.length();
    final first = await file
        .openRead(0, min(length, 4))
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    if (first.length >= 2 && first[0] == 0xFF && first[1] == 0xFE) {
      return 'utf-16le';
    }
    if (first.length >= 2 && first[0] == 0xFE && first[1] == 0xFF) {
      return 'utf-16be';
    }
    try {
      await file.openRead().transform(utf8.decoder).drain<void>();
      return 'utf-8';
    } catch (_) {
      if (await _isValidGbk(file)) return 'gb18030';
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'The TXT encoding is neither valid UTF-8, UTF-16 nor GBK.',
      );
    }
  }

  Future<bool> _isValidGbk(File file) async {
    int? lead;
    await for (final chunk in file.openRead()) {
      for (final byte in chunk) {
        if (lead != null) {
          if (byte < 0x40 || byte > 0xFE || byte == 0x7F) return false;
          lead = null;
        } else if (byte > 0x7F) {
          lead = byte;
        }
      }
    }
    return lead == null;
  }

  Future<String> _hashFile(File file) async =>
      '${await sha256.bind(file.openRead()).first}';

  String _folderName(Book book, String uid) {
    final title = _safeSegment(book.title.trim().isEmpty ? '未命名' : book.title);
    final rawAuthor = book.author;
    final author = _safeSegment(rawAuthor.trim().isEmpty ? '未知作者' : rawAuthor);
    final suffix = sha256.convert(utf8.encode(uid)).toString().substring(0, 12);
    return '$title - $author [$suffix]';
  }

  String _extension(String format, String original) {
    final candidate = format.trim().isEmpty
        ? path.extension(original).replaceFirst('.', '')
        : format;
    final safe = candidate.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    return safe.isEmpty ? 'bin' : safe;
  }

  String _safeSegment(String value) {
    final safe = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (safe.isEmpty) return 'book';
    return safe.substring(0, min(80, safe.length));
  }

  String _contentType(String format) =>
      switch (format.toLowerCase().replaceFirst('.', '')) {
        'txt' => 'text/plain',
        'epub' => 'application/epub+zip',
        'pdf' => 'application/pdf',
        'json' => 'application/json',
        _ => 'application/octet-stream',
      };

  String _utcNow() => _now().toUtc().toIso8601String();
  String _nonce() =>
      '${_now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  String _safeError(Object error) => switch (error) {
    SyncStorageException() => error.message,
    WebDavSyncFailure() => error.message,
    _ => error.toString(),
  };

  void _validateBook(Book book, String bookUid) {
    if (bookUid.trim().isEmpty) {
      throw ArgumentError.value(bookUid, 'bookUid', 'Must not be empty.');
    }
    if (book.filePath.trim().isEmpty) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'A local readable book file is required.',
      );
    }
  }

  static WebDavSyncFailure _notFound() => const WebDavSyncFailure(
    WebDavSyncErrorCode.notFound,
    'The local book file no longer exists.',
  );
}

class _RemotePaths {
  const _RemotePaths(this.binding);
  final _Binding binding;
  SyncPath get current => SyncPath(binding.currentPath);
  SyncPath get head => SyncPath('books/${binding.folderName}/book.json');
  SyncPath history(String revision) => SyncPath(
    'books/${binding.folderName}/history/$revision-${_safeName(binding.originalFileName)}',
  );
  static String _safeName(String value) {
    final name = path
        .basename(value)
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    return name.isEmpty ? 'book.bin' : name;
  }
}

class _Snapshot {
  const _Snapshot(this.file, this.hash, this.size);
  final File file;
  final String hash;
  final int size;
}

class _Remote {
  const _Remote({
    required this.snapshot,
    required this.currentInfo,
    required this.headInfo,
    required this.headHash,
    required this.headMatchesCurrent,
    required this.sourceStateHash,
    required this.sourceStateJson,
    required this.sourceAssets,
  });
  final _Snapshot snapshot;
  final SyncObjectInfo currentInfo;
  final SyncObjectInfo? headInfo;
  final String? headHash;
  final bool headMatchesCurrent;
  final String? sourceStateHash;
  final String? sourceStateJson;
  final Map<String, List<int>> sourceAssets;
}

class _SourceBundle {
  const _SourceBundle(this.hash, this.assets);
  final String? hash;
  final List<SourceStateAsset> assets;
}

class _RemoteSource {
  const _RemoteSource(this.hash, this.json, this.assets);
  final String hash;
  final String json;
  final Map<String, List<int>> assets;
}

class _SourceAssetDigest {
  const _SourceAssetDigest(this.path, this.hash, this.restorePath);
  final String path;
  final String hash;
  final String restorePath;
}

class _Outcome {
  const _Outcome({
    this.uploaded = false,
    this.downloaded = false,
    this.conflict = false,
    this.uploadedBytes = 0,
  });
  final bool uploaded;
  final bool downloaded;
  final bool conflict;
  final int uploadedBytes;
}

class _Job {
  const _Job(this.targetHash, this.snapshotPath, this.sourceStateHash);
  factory _Job.fromRow(Map<String, Object?> row) => _Job(
    row['target_hash'] as String,
    row['snapshot_path'] as String,
    row['source_state_hash'] as String?,
  );
  final String targetHash;
  final String snapshotPath;
  final String? sourceStateHash;
}

class _Binding {
  const _Binding({
    required this.bookUid,
    required this.localBookId,
    required this.localPath,
    required this.folderName,
    required this.originalFileName,
    required this.format,
    required this.currentPath,
    required this.spaceKey,
    required this.enabled,
    required this.status,
    required this.createdAt,
    required this.title,
    required this.author,
    this.localHash,
    this.baseHash,
    this.remoteVersion,
    this.headVersion,
    this.pendingRemoteHash,
    this.pendingRemotePath,
    this.pendingRemoteVersion,
    this.pendingHeadVersion,
    this.sourceStateHash,
    this.baseSourceStateHash,
    this.pendingSourceStateHash,
    this.pendingSourceStateJson,
    this.pendingSourceAssetsJson,
    this.observedMismatchVersion,
    this.observedMismatchAt,
    this.error,
  });

  factory _Binding.fromRow(Map<String, Object?> row) => _Binding(
    bookUid: row['book_uid'] as String,
    localBookId: row['local_book_id'] as int?,
    localPath: row['local_path'] as String,
    folderName: row['folder_name'] as String,
    originalFileName: row['original_file_name'] as String,
    format: row['format'] as String,
    currentPath: row['current_path'] as String,
    spaceKey: row['space_key'] as String,
    enabled: (row['enabled'] as int) != 0,
    status: BookContentSyncStatus.values.byName(row['status'] as String),
    createdAt: row['created_at'] as String,
    title: (row['book_title'] as String?) ?? '',
    author: (row['book_author'] as String?) ?? '',
    localHash: row['local_hash'] as String?,
    baseHash: row['base_hash'] as String?,
    remoteVersion: row['remote_version'] as String?,
    headVersion: row['head_version'] as String?,
    pendingRemoteHash: row['pending_remote_hash'] as String?,
    pendingRemotePath: row['pending_remote_path'] as String?,
    pendingRemoteVersion: row['pending_remote_version'] as String?,
    pendingHeadVersion: row['pending_head_version'] as String?,
    sourceStateHash: row['source_state_hash'] as String?,
    baseSourceStateHash: row['base_source_state_hash'] as String?,
    pendingSourceStateHash: row['pending_source_state_hash'] as String?,
    pendingSourceStateJson: row['pending_source_state_json'] as String?,
    pendingSourceAssetsJson: row['pending_source_assets_json'] as String?,
    observedMismatchVersion: row['observed_mismatch_version'] as String?,
    observedMismatchAt: row['observed_mismatch_at'] as String?,
    error: row['error'] as String?,
  );

  final String bookUid;
  final int? localBookId;
  final String localPath;
  final String folderName;
  final String originalFileName;
  final String format;
  final String currentPath;
  final String spaceKey;
  final bool enabled;
  final BookContentSyncStatus status;
  final String createdAt;
  final String title;
  final String author;
  final String? localHash;
  final String? baseHash;
  final String? remoteVersion;
  final String? headVersion;
  final String? pendingRemoteHash;
  final String? pendingRemotePath;
  final String? pendingRemoteVersion;
  final String? pendingHeadVersion;
  final String? sourceStateHash;
  final String? baseSourceStateHash;
  final String? pendingSourceStateHash;
  final String? pendingSourceStateJson;
  final String? pendingSourceAssetsJson;
  final String? observedMismatchVersion;
  final String? observedMismatchAt;
  Map<String, List<int>> get pendingSourceAssets {
    final value = pendingSourceAssetsJson;
    if (value == null || value.isEmpty) return const <String, List<int>>{};
    final json = (jsonDecode(value) as Map).cast<String, dynamic>();
    return json.map(
      (key, encoded) => MapEntry(key, base64Decode(encoded as String)),
    );
  }

  final String? error;

  _Binding copyWith({
    String? localHash,
    String? spaceKey,
    BookContentSyncStatus? status,
    String? sourceStateHash,
    bool clearRemote = false,
  }) => _Binding(
    bookUid: bookUid,
    localBookId: localBookId,
    localPath: localPath,
    folderName: folderName,
    originalFileName: originalFileName,
    format: format,
    currentPath: currentPath,
    spaceKey: spaceKey ?? this.spaceKey,
    enabled: enabled,
    status: status ?? this.status,
    createdAt: createdAt,
    title: title,
    author: author,
    localHash: localHash ?? this.localHash,
    baseHash: clearRemote ? null : baseHash,
    remoteVersion: clearRemote ? null : remoteVersion,
    headVersion: clearRemote ? null : headVersion,
    pendingRemoteHash: clearRemote ? null : pendingRemoteHash,
    pendingRemotePath: clearRemote ? null : pendingRemotePath,
    pendingRemoteVersion: clearRemote ? null : pendingRemoteVersion,
    pendingHeadVersion: clearRemote ? null : pendingHeadVersion,
    sourceStateHash: sourceStateHash ?? this.sourceStateHash,
    baseSourceStateHash: clearRemote ? null : baseSourceStateHash,
    pendingSourceStateHash: clearRemote ? null : pendingSourceStateHash,
    pendingSourceStateJson: clearRemote ? null : pendingSourceStateJson,
    pendingSourceAssetsJson: clearRemote ? null : pendingSourceAssetsJson,
    observedMismatchVersion: clearRemote ? null : observedMismatchVersion,
    observedMismatchAt: clearRemote ? null : observedMismatchAt,
    error: error,
  );

  BookContentState get publicState => BookContentState(
    bookUid: bookUid,
    localBookId: localBookId,
    localPath: localPath,
    remotePath: currentPath,
    status: enabled ? status : BookContentSyncStatus.paused,
    localHash: localHash,
    baseHash: baseHash,
    remoteVersion: remoteVersion,
    error: error,
    pendingRemoteHash: pendingRemoteHash,
    enabled: enabled,
  );
}

BookContentConflict _conflictFromRow(Map<String, Object?> row) =>
    BookContentConflict(
      id: row['id'] as int,
      bookUid: row['book_uid'] as String,
      spaceKey: row['space_key'] as String,
      localHash: row['local_hash'] as String,
      remoteHash: row['remote_hash'] as String,
      localSnapshotPath: row['local_snapshot_path'] as String,
      remoteSnapshotPath: row['remote_snapshot_path'] as String,
      remoteVersion: row['remote_version'] as String,
      headVersion: row['head_version'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
