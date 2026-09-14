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
import 'book_revision_repository.dart';
import 'storage/immutable_object_store.dart';
import 'storage/sync_storage.dart';
import 'sync_models.dart';
import 'sync_space.dart';

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
    this.downloadedBytes = 0,
  });
  final int uploaded;
  final int downloaded;
  final int conflicts;
  final int failed;
  final int uploadedBytes;
  final int downloadedBytes;
}

/// Coordinates immutable cloud revisions with transactional local files.
/// Cloud persistence lives in BookRevisionRepository; this service owns local
/// recovery, reading references, source sidecars and explicit conflict choices.
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
  ImmutableObjectStore? _activeObjects;
  bool Function()? _shouldContinue;
  final Map<String, _LocalObservation> _localObservations = {};

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
    final spaceKey = storage == null
        ? old?.spaceKey ?? ''
        : await _spaceKey(storage);
    final folder = BookRevisionRepository.folder(bookUid);
    final original = path.basename(book.filePath);
    await db.transaction((txn) async {
      await _archiveIfSpaceChanged(txn, old, spaceKey);
      await txn.insert('book_content_bindings', {
        'book_uid': bookUid,
        'local_book_id': book.id,
        'local_path': book.filePath,
        'folder_name': folder,
        'original_file_name': old?.originalFileName ?? original,
        'format': book.format.toLowerCase(),
        'current_path':
            old?.currentPath ?? 'books/$folder/revisions/unpublished.json',
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
    bool respectBackoff = false,
  }) {
    final active = _activeReconcile;
    if (active != null) return active;
    final future = _runReconcile(bookUid, shouldContinue, respectBackoff);
    _activeReconcile = future;
    return future.whenComplete(() {
      if (identical(_activeReconcile, future)) _activeReconcile = null;
    });
  }

  Future<BookContentReconcileResult> _runReconcile(
    String? bookUid,
    bool Function()? shouldContinue,
    bool respectBackoff,
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
    final activeSpace = await _spaceKey(storage);
    _activeObjects = await _objects(storage, knownSpace: activeSpace);
    _shouldContinue = shouldContinue;
    var up = 0, down = 0, conflicts = 0, failed = 0;
    for (var binding in bindings.where((b) => b.enabled)) {
      if (shouldContinue?.call() == false) break;
      try {
        binding = await _activateSpace(db, binding, activeSpace);
        final retries = await db.query(
          'book_content_bindings',
          columns: ['retry_after'],
          where: 'book_uid = ?',
          whereArgs: [binding.bookUid],
        );
        final retryAt = DateTime.tryParse(
          retries.single['retry_after'] as String? ?? '',
        );
        if (respectBackoff && retryAt != null && retryAt.isAfter(_now())) {
          continue;
        }
        final result = await _reconcileBook(db, storage, binding);
        if (result.uploaded) up++;
        if (result.downloaded) down++;
        if (result.conflict) conflicts++;
      } catch (error) {
        failed++;
        final rows = await db.query(
          'book_content_bindings',
          columns: ['failure_count'],
          where: 'book_uid = ?',
          whereArgs: [binding.bookUid],
        );
        final failures = ((rows.single['failure_count'] as int? ?? 0) + 1)
            .clamp(1, 6);
        await db.update(
          'book_content_bindings',
          {
            'failure_count': failures,
            'retry_after': _now()
                .add(Duration(seconds: 5 * (1 << failures)))
                .toUtc()
                .toIso8601String(),
          },
          where: 'book_uid = ?',
          whereArgs: [binding.bookUid],
        );
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
      uploadedBytes: _activeObjects!.uploadedBytes,
      downloadedBytes: _activeObjects!.downloadedBytes,
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
      allowCached: true,
    );
    final localBook = await _bookForBinding(db, binding);
    final sourceBundle = localBook == null
        ? const _SourceBundle(null, <SourceStateAsset>[])
        : await _sourceBundle(
            localBook,
            expectedBookUid: binding.bookUid,
            contentHash: localSnapshot.hash,
          );
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

    final repository = BookRevisionRepository(_activeObjects!);
    final tips = await repository.tips(
      binding.bookUid,
      knownRevision: binding.remoteVersion,
    );
    if (tips.isEmpty) {
      return _pushRevision(
        db,
        repository,
        binding,
        localSnapshot,
        sourceBundle,
        [],
      );
    }
    final localChanged =
        localSnapshot.hash != binding.baseHash ||
        sourceBundle.hash != binding.baseSourceStateHash;
    if (tips.length == 1) {
      final tip = tips.single;
      if (localSnapshot.hash == tip.hash &&
          sourceBundle.hash == tip.sourceHash) {
        await _markSynced(
          db,
          binding,
          tip.hash,
          SyncObjectVersion(tip.id),
          SyncObjectVersion(tip.id),
          tip.size,
          tip.sourceHash,
        );
        return const _Outcome();
      }
      if (tip.id == binding.remoteVersion && localChanged) {
        return _pushRevision(
          db,
          repository,
          binding,
          localSnapshot,
          sourceBundle,
          tips,
        );
      }
      if (localSnapshot.hash == tip.hash &&
          sourceBundle.hash != null &&
          tip.sourceHash == null) {
        return _pushRevision(
          db,
          repository,
          binding,
          localSnapshot,
          sourceBundle,
          tips,
        );
      }
      if (!localChanged ||
          (localSnapshot.hash == tip.hash && sourceBundle.hash == null)) {
        return _acceptRemote(
          db,
          binding,
          await _readRevision(repository, binding, tip),
        );
      }
    }
    final remoteTip = tips.firstWhere(
      (tip) => tip.id != binding.remoteVersion,
      orElse: () => tips.first,
    );
    return _recordConflict(
      db,
      binding,
      localSnapshot,
      await _readRevision(repository, binding, remoteTip),
      remoteTips: tips.map((tip) => tip.id).toList(),
    );
  }

  Future<String> _spaceKey(SyncStorage storage) async =>
      '${storage.spaceKey}\u0000${await SyncSpace.ensure(storage)}';

  Future<ImmutableObjectStore> _objects(
    SyncStorage storage, {
    String? knownSpace,
  }) async {
    final namespace = sha256
        .convert(utf8.encode(knownSpace ?? await _spaceKey(storage)))
        .toString();
    return ImmutableObjectStore(
      storage,
      Directory(path.join((await _rootDirectory()).path, 'objects', namespace)),
    );
  }

  Future<_Outcome> _pushRevision(
    Database db,
    BookRevisionRepository repository,
    _Binding binding,
    _Snapshot snapshot,
    _SourceBundle source,
    List<BookRevision> parents,
  ) async {
    await _publishSourceAssets(repository.storage, binding, source);
    final assets = await _sourceDigests(source);
    final revision = await repository.publish(
      bookUid: binding.bookUid,
      file: snapshot.file,
      hash: snapshot.hash,
      format: binding.format,
      fileName: binding.originalFileName,
      parents: parents.map((r) => r.id).toList(),
      base: parents.isEmpty ? null : parents.first,
      shouldContinue: _shouldContinue,
      metadata: {
        'source_state_sha256': source.hash,
        'source_assets': assets
            .map(
              (asset) => {
                'path': asset.path,
                'sha256': asset.hash,
                'restore_path': asset.restorePath,
              },
            )
            .toList(),
      },
    );
    await _markSynced(
      db,
      binding,
      snapshot.hash,
      SyncObjectVersion(revision.id),
      SyncObjectVersion(revision.id),
      snapshot.size,
      source.hash,
    );
    return _Outcome(uploaded: true, uploadedBytes: snapshot.size);
  }

  Future<_Remote> _readRevision(
    BookRevisionRepository repository,
    _Binding binding,
    BookRevision revision,
  ) async {
    final file = await _revisionFile(
      binding.bookUid,
      revision.hash,
      path.extension(binding.originalFileName),
    );
    if (!await file.exists() || await _hashFile(file) != revision.hash) {
      final partial = await _temporaryFile('reconstruct');
      try {
        await repository.materialize(revision, partial);
        await partial.copy(file.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    final snapshot = _Snapshot(file, revision.hash, revision.size);
    await _recordRevision(await _database, binding.bookUid, snapshot, 'remote');
    final source = await _readSourceSidecar(
      repository.storage,
      binding,
      revision.sourceHash,
      revision.sourceAssets,
    );
    return _Remote(
      snapshot: snapshot,
      revisionId: revision.id,
      sourceStateHash: source?.hash,
      sourceStateJson: source?.json,
      sourceAssets: source?.assets ?? const {},
    );
  }

  Future<BookRevision> downloadRevision(
    String bookUid,
    String remotePath,
    File destination,
  ) async {
    final storage = await _storageProvider();
    if (storage == null) {
      throw const SyncStorageException(
        SyncStorageErrorCode.authentication,
        'Cloud storage is not configured.',
      );
    }
    final id = path.posix.basenameWithoutExtension(remotePath);
    if (BookRevisionRepository.revisionPath(bookUid, id).value != remotePath) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'The book descriptor references an invalid revision path.',
      );
    }
    final repository = BookRevisionRepository(await _objects(storage));
    final revision = await repository.read(bookUid, id);
    await repository.materialize(revision, destination);
    return revision;
  }

  /// Explicit export, never a second automatic synchronization lane.
  Future<String> exportBook(String bookUid) async {
    final db = await _database;
    await _ensureSchema(db);
    final binding = await _binding(db, bookUid);
    if (binding?.remoteVersion == null) {
      throw const SyncStorageException(
        SyncStorageErrorCode.notFound,
        'Sync the book before exporting it.',
      );
    }
    final storage = await _storageProvider();
    if (storage == null) {
      throw const SyncStorageException(
        SyncStorageErrorCode.authentication,
        'Cloud storage is not configured.',
      );
    }
    final objects = await _objects(storage);
    final repository = BookRevisionRepository(objects);
    final revision = await repository.read(bookUid, binding!.remoteVersion!);
    final temporary = await _temporaryFile('export');
    try {
      await repository.materialize(revision, temporary);
      final book = await _bookForBinding(db, binding);
      final name = (book?.title ?? 'Book').replaceAll(
        RegExp(r'[\\/:*?"<>|\x00-\x1F]'),
        '_',
      );
      final remote = SyncPath(
        'exports/$name-${binding.folderName.substring(0, 12)}/${revision.id}.${binding.format}',
      );
      await objects.putFile(remote, temporary, revision.hash);
      return remote.value;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
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

  Future<_Outcome> _recordConflict(
    Database db,
    _Binding binding,
    _Snapshot local,
    _Remote remote, {
    required List<String> remoteTips,
  }) async {
    await db.transaction((txn) async {
      await txn.delete(
        'book_content_conflicts',
        where:
            'book_uid = ? AND resolved_at IS NULL AND local_hash = ? AND remote_version = ?',
        whereArgs: [binding.bookUid, local.hash, remote.revisionId],
      );
      await txn.insert('book_content_conflicts', {
        'book_uid': binding.bookUid,
        'space_key': binding.spaceKey,
        'local_hash': local.hash,
        'remote_hash': remote.snapshot.hash,
        'local_snapshot_path': local.file.path,
        'remote_snapshot_path': remote.snapshot.file.path,
        'remote_version': remote.revisionId,
        'head_version': remote.revisionId,
        'remote_tips_json': jsonEncode(remoteTips..sort()),
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
      'pending_remote_version': remote.revisionId,
      'pending_head_version': remote.revisionId,
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
    if (_isBusy(binding.localBookId)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'Close the book before resolving its content conflict.',
      );
    }
    final storage = await _storageProvider();
    if (storage == null) {
      throw const SyncStorageException(
        SyncStorageErrorCode.authentication,
        'Cloud storage is not configured.',
      );
    }
    _activeObjects = await _objects(storage);
    final repository = BookRevisionRepository(_activeObjects!);
    final tips = await repository.tips(
      binding.bookUid,
      knownRevision: binding.remoteVersion,
    );
    final observed =
        (jsonDecode(rows.single['remote_tips_json'] as String? ?? '[]') as List)
            .cast<String>()
          ..sort();
    final currentTips = tips.map((tip) => tip.id).toList()..sort();
    if (!tips.any((tip) => tip.id == conflict.remoteVersion) ||
        jsonEncode(observed) != jsonEncode(currentTips)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The cloud book changed again. Refresh its conflict before choosing.',
      );
    }
    final latestLocal = File(binding.localPath);
    if (!await latestLocal.exists() ||
        await _hashFile(latestLocal) != conflict.localHash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The local book changed again. Refresh its conflict before choosing.',
      );
    }
    if (choice == BookContentConflictChoice.useRemote) {
      final selected = tips.singleWhere(
        (tip) => tip.id == conflict.remoteVersion,
      );
      final remote = await _readRevision(repository, binding, selected);
      // Publish the explicit merge before replacing local content. A failed
      // network commit must not leave a silently half-resolved local choice.
      final merged = await repository.publish(
        bookUid: binding.bookUid,
        file: remote.snapshot.file,
        hash: remote.snapshot.hash,
        format: binding.format,
        fileName: binding.originalFileName,
        parents: currentTips,
        base: selected,
        metadata: {
          'source_state_sha256': selected.sourceHash,
          'source_assets': selected.sourceAssets,
        },
      );
      await _applyRemote(
        db,
        binding,
        await _readRevision(repository, binding, merged),
      );
    } else {
      final book = await _bookForBinding(db, binding);
      final source = book == null
          ? const _SourceBundle(null, [])
          : await _sourceBundle(book, expectedBookUid: binding.bookUid);
      final snapshot = await _snapshot(
        latestLocal,
        binding.bookUid,
        origin: 'resolution',
      );
      await _pushRevision(db, repository, binding, snapshot, source, tips);
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
      revisionId: binding.pendingRemoteVersion!,
      sourceStateHash: binding.pendingSourceStateHash,
      sourceStateJson: binding.pendingSourceStateJson,
      sourceAssets: binding.pendingSourceAssets,
    );
    await _applyRemote(db, binding, remote);
    return true;
  }

  Future<bool> applyPendingRemote(String bookUid) =>
      applyAvailableUpdate(bookUid);

  Future<_SourceBundle> _sourceBundle(
    Book book, {
    required String expectedBookUid,
    String? contentHash,
  }) async {
    SourceChapterState? state;
    try {
      state = await _sourceStateStore.load(book);
    } catch (_) {
      return const _SourceBundle(null, <SourceStateAsset>[]);
    }
    if (state != null) {
      contentHash ??= await _hashFile(File(book.filePath));
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
      final objects = _activeObjects ?? await _objects(storage);
      final file = await objects.readFile(remote, digest.hash);
      assets[digest.restorePath] = await file.readAsBytes();
    }
    final json = utf8.decode(assets['source/book.json']!);
    return _RemoteSource(expectedBundleHash, json, assets);
  }

  Future<void> _ensureImmutable(
    SyncStorage storage,
    SyncPath remote,
    _Snapshot snapshot,
  ) async {
    final objects = _activeObjects ?? await _objects(storage);
    await objects.putFile(remote, snapshot.file, snapshot.hash);
  }

  Future<_Snapshot> _snapshot(
    File source,
    String bookUid, {
    required String origin,
    bool allowCached = false,
  }) async {
    if (!await source.exists()) throw _notFound();
    final stat = await source.stat();
    final observation = _localObservations[bookUid];
    if (allowCached &&
        observation != null &&
        observation.matches(source, stat, _now()) &&
        await observation.snapshot.file.exists()) {
      return observation.snapshot;
    }
    final hash = await _hashFile(source);
    final revision = await _revisionFile(
      bookUid,
      hash,
      path.extension(source.path),
    );
    if (!await revision.exists()) {
      await source.copy(revision.path);
      if (await _hashFile(revision) != hash) {
        await revision.delete();
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.localDataCorrupt,
          'The local book changed while creating its revision. Retry sync.',
        );
      }
    } else if (await _hashFile(revision) != hash) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.localDataCorrupt,
        'A local revision snapshot is damaged.',
      );
    }
    final snapshot = _Snapshot(revision, hash, await revision.length());
    final after = await source.stat();
    if (after.size != stat.size ||
        after.modified != stat.modified ||
        after.changed != stat.changed) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The local file changed while taking a snapshot. Retry sync.',
      );
    }
    _localObservations[bookUid] = _LocalObservation(
      source.path,
      after,
      snapshot,
      _now(),
    );
    return snapshot;
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
    if (binding.localHash != null && originalHash != binding.localHash) {
      await incoming.delete();
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The local book changed during download. Retry to compare both revisions.',
      );
    }
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
      'remote_version': remote.revisionId,
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
          SyncObjectVersion(remote.revisionId),
          SyncObjectVersion(remote.revisionId),
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
  ) async {
    final currentFile = File(binding.localPath);
    String? localHash;
    if (await currentFile.exists()) {
      final stat = await currentFile.stat();
      final observation = _localObservations[binding.bookUid];
      localHash =
          observation != null && observation.matches(currentFile, stat, _now())
          ? observation.snapshot.hash
          : await _hashFile(currentFile);
    }
    await db.transaction((txn) async {
      await _markSyncedInTransaction(
        txn,
        binding,
        hash,
        currentVersion,
        headVersion,
        size,
        sourceStateHash,
        observedLocalHash: localHash,
      );
    });
  }

  Future<void> _markSyncedInTransaction(
    DatabaseExecutor db,
    _Binding binding,
    String hash,
    SyncObjectVersion currentVersion,
    SyncObjectVersion? headVersion,
    int size,
    String? sourceStateHash, {
    String? observedLocalHash,
  }) async {
    final latest = await db.query(
      'book_content_bindings',
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    final row = latest.single;
    final recordedHash = row['local_hash'] as String?;
    final effectiveHash =
        recordedHash != binding.localHash && recordedHash != hash
        ? recordedHash
        : observedLocalHash ?? hash;
    final changedDuringUpload = effectiveHash != hash;
    // The existing local column stores the verified revision commit identity.
    if (headVersion == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The book has no verified revision commit.',
      );
    }
    await db.update(
      'book_content_bindings',
      {
        'status': changedDuringUpload
            ? BookContentSyncStatus.pending.name
            : BookContentSyncStatus.synced.name,
        'local_hash': effectiveHash,
        'base_hash': hash,
        'failure_count': 0,
        'retry_after': null,
        'remote_version': currentVersion.value,
        'head_version': headVersion.value,
        'current_path': BookRevisionRepository.revisionPath(
          binding.bookUid,
          currentVersion.value,
        ).value,
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
    if (!changedDuringUpload) {
      await db.delete(
        'book_content_jobs',
        where: 'book_uid = ?',
        whereArgs: [binding.bookUid],
      );
    }
    final existingFiles = await db.query(
      'sync_book_files',
      where: 'book_uid = ?',
      whereArgs: [binding.bookUid],
    );
    final existingFile = existingFiles.isEmpty
        ? <String, Object?>{}
        : existingFiles.single;
    await db.insert('sync_book_files', {
      for (final entry in existingFile.entries)
        if (entry.key.startsWith('cover_')) entry.key: entry.value,
      'book_uid': binding.bookUid,
      'local_book_id': binding.localBookId,
      'blob_sha256': hash,
      'file_name': binding.originalFileName,
      'file_size': size,
      'remote_path': BookRevisionRepository.revisionPath(
        binding.bookUid,
        currentVersion.value,
      ).value,
      'sync_enabled': binding.enabled ? 1 : 0,
      'updated_at': _utcNow(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

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
          'failure_count': 0,
          'retry_after': null,
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
      'failure_count': 'INTEGER NOT NULL DEFAULT 0',
      'retry_after': 'TEXT',
    });
    await _ensureColumns(db, 'book_content_conflicts', const {
      'remote_tips_json': 'TEXT',
    });
    await _ensureColumns(db, 'book_content_jobs', const {
      'source_state_hash': 'TEXT',
    });
    await _ensureColumns(db, 'book_content_apply_journal', const {
      'source_path': 'TEXT',
      'source_backup_path': 'TEXT',
      'source_existed': 'INTEGER NOT NULL DEFAULT 0',
    });
    final obsolete = await db.query(
      'book_content_bindings',
      where: "current_path NOT LIKE '%/revisions/%'",
    );
    for (final row in obsolete) {
      final uid = row['book_uid'] as String;
      final folder = BookRevisionRepository.folder(uid);
      await db.update(
        'book_content_bindings',
        {
          'folder_name': folder,
          'current_path': 'books/$folder/revisions/unpublished.json',
          'space_key': '',
          'base_hash': null,
          'remote_version': null,
          'head_version': null,
          'base_source_state_hash': null,
          'pending_remote_path': null,
          'pending_remote_version': null,
          'pending_head_version': null,
          'status': row['enabled'] == 0 ? 'paused' : 'pending',
        },
        where: 'book_uid = ?',
        whereArgs: [uid],
      );
      await db.delete(
        'sync_book_files',
        where: 'book_uid = ?',
        whereArgs: [uid],
      );
    }
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

  String _safeSegment(String value) {
    final safe = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (safe.isEmpty) return 'book';
    return safe.substring(0, min(80, safe.length));
  }

  String _utcNow() => _now().toUtc().toIso8601String();
  String _nonce() =>
      '${_now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  String _safeError(Object error) => switch (error) {
    SyncStorageException() => error.message,
    WebDavSyncFailure() => error.message,
    _ => 'Book synchronization failed (${error.runtimeType}).',
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

class _LocalObservation {
  const _LocalObservation(this.path, this.stat, this.snapshot, this.verifiedAt);
  final String path;
  final FileStat stat;
  final _Snapshot snapshot;
  final DateTime verifiedAt;
  bool matches(File file, FileStat current, DateTime now) =>
      file.path == path &&
      current.size == stat.size &&
      current.modified == stat.modified &&
      current.changed == stat.changed &&
      now.difference(verifiedAt).abs() < const Duration(minutes: 15);
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
    required this.revisionId,
    required this.sourceStateHash,
    required this.sourceStateJson,
    required this.sourceAssets,
  });
  final _Snapshot snapshot;
  final String revisionId;
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
