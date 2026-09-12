import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/book.dart';
import '../books/book_storage_codec.dart';
import '../library/library_event_bus_service.dart';
import '../reader/replace_rule_service.dart';
import '../books/txt_content_change_bus.dart';
import '../core/database_service.dart';

import 'adapters/metadata_sync_adapters.dart';
import 'automatic_sync_scheduler.dart';
import 'book_sync_identity.dart';
import 'book_content_sync_service.dart';
import 'reading_progress_sync_service.dart';
import 'secure_sync_config.dart';
import 'sync_change_store.dart';
import 'sync_dataset_catalog.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'book_file_sync_service.dart';
import 'webdav_client.dart';
import 'storage/sync_storage.dart';
import 'storage/webdav_sync_storage.dart';

class WebDavSyncController extends ChangeNotifier {
  WebDavSyncController({
    SecureSyncConfigStore? configStore,
    SyncChangeStore? changeStore,
    SyncEngine? engine,
    WebDavClientFactory? clientFactory,
    BookFileSyncService? bookFileService,
    BookContentSyncService? contentSyncService,
    this.localBooksLoader,
    this._replaceRuleService,
  }) : _configStore = configStore ?? SecureSyncConfigStore(),
       _changeStore = changeStore ?? SyncChangeStore(),
       _clientFactory = clientFactory ?? WebDavClient.standard {
    _engine = engine;
    _contentSync =
        contentSyncService ??
        BookContentSyncService(storageProvider: _storageProvider);
    _bookFileService =
        bookFileService ??
        BookFileSyncService(
          storageProvider: _storageProvider,
          contentSyncService: _contentSync,
        );
    _scheduler = AutomaticSyncScheduler(
      run: _runAutomaticCycle,
      enabled: () => isConfigured && autoSync && !_disposed,
    );
  }

  final SecureSyncConfigStore _configStore;
  final SyncChangeStore _changeStore;
  final WebDavClientFactory _clientFactory;
  final ReplaceRuleService? _replaceRuleService;
  final Future<List<Book>> Function()? localBooksLoader;
  SyncEngine? _engine;
  late final BookFileSyncService _bookFileService;
  Future<WebDavSyncRunResult>? _running;
  WebDavSyncConfiguration? _configuration;
  WebDavSyncScope _scope = const WebDavSyncScope();
  WebDavSyncStatus _status = WebDavSyncStatus.unconfigured;
  WebDavSyncPhase _phase = WebDavSyncPhase.none;
  WebDavSyncPhase _lastFailedPhase = WebDavSyncPhase.none;
  DateTime? _lastSuccessfulSync;
  int _pendingChanges = 0;
  WebDavSyncFailure? _metadataFailure;
  WebDavSyncFailure? _fileFailure;
  WebDavSyncFailure? _backgroundUploadFailure;
  WebDavSyncFailure? _visibleFailure;
  WebDavSyncRunResult? _lastResult;
  List<RemoteBookDescriptor> _remoteBooks = const [];
  WebDavNewBookUploadPolicy _newBookUploadPolicy =
      WebDavNewBookUploadPolicy.askEveryTime;
  final List<Book> _backgroundUploadQueue = <Book>[];
  final Set<String> _backgroundUploadTitles = <String>{};
  bool _backgroundUploadRunning = false;
  late final BookContentSyncService _contentSync;
  StreamSubscription<ReadingProgressSyncEvent>? _progressSubscription;
  StreamSubscription<TxtContentChanged>? _textSubscription;
  Future<void>? _fileRun;
  List<BookContentState> _textStates = const [];
  bool get syncingText => _fileRun != null;
  List<BookContentState> get textStates => List.unmodifiable(_textStates);
  BookContentSyncService get contentSyncService => _contentSync;

  Future<void> refreshTextStates() async {
    _textStates = await _contentSync.listStates();
    _restorePersistedFileFailure();
    _restoreSettledStatus();
    notifyListeners();
  }

  Future<SyncStorage?> _storageProvider() async {
    final credentials = await _configStore.readCredentials();
    return credentials == null
        ? null
        : WebDavSyncStorage(_clientFactory(credentials));
  }

  late final AutomaticSyncScheduler _scheduler;
  bool _disposed = false;
  bool _autoResume = true;
  DateTime? _lastCheckedAt;
  DateTime? _lastProgressSyncAt;
  int _progressGeneration = 0;
  bool _progressPending = false;

  bool get autoResume => _autoResume;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  DateTime? get lastProgressSyncAt => _lastProgressSyncAt;
  bool get progressPending => _progressPending;

  void requestAutomaticSync({bool immediate = false}) =>
      _scheduler.request(immediate: immediate);

  void setForeground(bool foreground) => _scheduler.setForeground(foreground);

  Future<void> checkProgressBeforeOpen() async {
    if (!isConfigured || !autoSync || !scope.progress) return;
    await _syncMetadataNow();
  }

  Future<void> _runAutomaticCycle() async {
    await _syncMetadataNow();
    if (autoSync && scope.bookFiles && _backgroundUploadQueue.isNotEmpty) {
      unawaited(_drainBackgroundBookUploads());
    }
    if (autoSync && scope.bookFiles) {
      unawaited(
        synchronizeTextFiles(automatic: true).catchError((Object error) {
          debugPrint('TXT synchronization will retry: ${error.runtimeType}');
        }),
      );
    }
  }

  Future<void> synchronizeTextFiles({bool automatic = false}) {
    if (!isConfigured || !scope.bookFiles) return Future<void>.value();
    final running = _fileRun;
    if (running != null) return running;
    final future = _runTextFiles(automatic: automatic).whenComplete(() {
      _fileRun = null;
      notifyListeners();
    });
    _fileRun = future;
    notifyListeners();
    return future;
  }

  Future<void> _runTextFiles({required bool automatic}) async {
    final connection = '$serverUrl|$username|$rootPath';
    try {
      final result = await _contentSync.reconcile(
        shouldContinue: () =>
            !_disposed &&
            isConfigured &&
            scope.bookFiles &&
            connection == '$serverUrl|$username|$rootPath' &&
            (!automatic || autoSync),
      );
      _textStates = await _contentSync.listStates();
      final hasFailedState = _textStates.any(
        (state) => state.status == BookContentSyncStatus.failed,
      );
      final hasConflictState = _textStates.any(
        (state) => state.status == BookContentSyncStatus.conflict,
      );
      if (result.failed > 0 || hasFailedState) {
        _setFileFailure(
          WebDavSyncFailure(
            WebDavSyncErrorCode.unknown,
            result.failed == 1
                ? 'One book file could not be synchronized. Check its file sync status for details.'
                : 'Some book files could not be synchronized. Check their file sync status for details.',
          ),
        );
      } else if (result.conflicts > 0 || hasConflictState) {
        _setFileFailure(
          const WebDavSyncFailure(
            WebDavSyncErrorCode.conflict,
            'A book file has conflicting changes that require attention.',
          ),
        );
      } else if (_backgroundUploadFailure != null &&
          _backgroundUploadQueue.isNotEmpty) {
        _setFileFailure(_backgroundUploadFailure!);
      } else {
        _clearFileFailure();
      }
      if (result.downloaded > 0) LibraryEventBus().notifyLibraryChanged();
      if (result.uploaded > 0 || result.downloaded > 0) {
        // Publish the file descriptor after its current TXT is committed.
        // This stays on the small metadata lane, independent of file transfer.
        await _syncMetadataNow();
      }
      await _refreshRemoteBooks();
      _restoreSettledStatus();
    } on WebDavSyncFailure catch (error) {
      if (!identical(_metadataFailure, error)) {
        _setFileFailure(error);
      }
      _restoreSettledStatus();
      rethrow;
    } on SyncStorageException catch (error) {
      final failure = _storageFailure(error);
      _setFileFailure(failure);
      _restoreSettledStatus();
      throw failure;
    } catch (error, stackTrace) {
      debugPrint('WebDAV book-file sync failed: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      const failure = WebDavSyncFailure(
        WebDavSyncErrorCode.unknown,
        'Book-file sync could not be completed.',
      );
      _setFileFailure(failure);
      _restoreSettledStatus();
      throw failure;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _onTextChanged(TxtContentChanged event) async {
    if (event.origin == TxtContentChangeOrigin.remoteApply || !isConfigured) {
      return;
    }
    try {
      final uid = await stableBookUid(event.book);
      final bindings = await _contentSync.listStates();
      if (!bindings.any((state) => state.bookUid == uid)) return;
      await _contentSync.enqueueLocalUpdate(event.book, bookUid: uid);
      _textStates = await _contentSync.listStates();
      notifyListeners();
      requestAutomaticSync();
    } catch (error) {
      // The editor has committed the original file. Reconciliation detects its
      // hash after restart even if queuing this notification fails.
      debugPrint('TXT update will be reconciled: ${error.runtimeType}');
    }
  }

  bool get isConfigured => _configuration != null;
  WebDavSyncStatus get status => _status;
  WebDavSyncPhase get phase => _phase;
  WebDavSyncPhase get lastFailedPhase => _lastFailedPhase;
  DateTime? get lastSuccessfulSync => _lastSuccessfulSync;
  int get pendingChanges => _pendingChanges;
  WebDavSyncFailure? get lastFailure => _visibleFailure;
  bool get lastFailureIsFile =>
      _fileFailure != null && identical(_visibleFailure, _fileFailure);
  WebDavSyncErrorCode? get lastError => lastFailure?.code;
  String? get lastErrorMessage => lastFailure?.message;
  bool get autoSync => _configuration?.autoSync ?? false;
  WebDavSyncScope get scope => _scope;
  String? get serverUrl => _configuration?.serverUrl;
  String? get username => _configuration?.username;
  String? get rootPath => _configuration?.rootPath;
  WebDavSyncRunResult? get lastResult => _lastResult;
  List<RemoteBookDescriptor> get remoteBooks => _remoteBooks;
  WebDavNewBookUploadPolicy get newBookUploadPolicy => _newBookUploadPolicy;
  SyncFileCapabilities get fileCapabilities => const SyncFileCapabilities();

  /// Queues automatic uploads without making the caller wait for network I/O.
  /// Queue identity uses the local book, never its title: unrelated books can
  /// legitimately share a name. The file service resolves the stable identity.
  int enqueueNewBookUploads(Iterable<Book> books) {
    if (!isConfigured || !scope.bookFiles || !autoSync) return 0;
    var queued = 0;
    for (final book in books) {
      if (book.isOnline || book.filePath.isEmpty) continue;
      final identity = '${book.id ?? book.filePath}';
      if (!_backgroundUploadTitles.add(identity)) {
        continue;
      }
      _backgroundUploadQueue.add(book);
      queued++;
    }
    if (queued > 0) unawaited(_drainBackgroundBookUploads());
    return queued;
  }

  Future<void> initialize() async {
    // Finishing an interrupted local file swap does not require credentials
    // or permission to make a network request.
    await _contentSync.recoverLocalState();
    _configuration = await _configStore.readConfiguration();
    _scope = SyncDatasetCatalog.normalizeScope(await _configStore.readScope());
    _newBookUploadPolicy = await _configStore.readNewBookUploadPolicy();
    _autoResume = await _configStore.readAutoResume();
    _pendingChanges = await _enabledPendingCount();
    final lastSuccess = await _changeStore.getState('last_successful_sync');
    _lastSuccessfulSync = lastSuccess == null
        ? null
        : DateTime.tryParse(lastSuccess)?.toLocal();
    _status = isConfigured
        ? WebDavSyncStatus.idle
        : WebDavSyncStatus.unconfigured;
    await _discoverUnuploadedBooks();
    await _refreshRemoteBooks();
    _progressSubscription ??= ReadingProgressSyncService.instance.events.listen(
      (event) {
        _progressGeneration++;
        _progressPending = true;
        notifyListeners();
        requestAutomaticSync(
          immediate: event.kind == ReadingProgressSyncEventKind.readerClosed,
        );
      },
    );
    _textSubscription ??= TxtContentChangeBus.instance.stream.listen(
      (event) => unawaited(_onTextChanged(event)),
    );
    _textStates = await _contentSync.listStates();
    _restorePersistedFileFailure();
    _restoreSettledStatus(successStatus: WebDavSyncStatus.idle);
    _scheduler.start();
    notifyListeners();
  }

  Future<ConnectionTestResult> testConnection(
    WebDavSyncConfigDraft draft,
  ) async {
    _status = WebDavSyncStatus.testing;
    _phase = WebDavSyncPhase.connecting;
    _clearMetadataFailure();
    notifyListeners();
    try {
      final password = await _resolvePassword(draft.password);
      final configuration = draft.withoutPassword(
        autoSync: _configuration?.autoSync ?? true,
      );
      validateWebDavConfiguration(configuration, password: password);
      final result = await _clientFactory(
        StoredSyncCredentials(configuration, password),
      ).testConnection();
      if (!result.success) {
        _setMetadataFailure(
          result.failure ??
              WebDavSyncFailure(
                result.errorCode ?? WebDavSyncErrorCode.unknown,
                result.message ?? 'The WebDAV connection test failed.',
              ),
        );
      }
      _restoreSettledStatus(successStatus: WebDavSyncStatus.idle);
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      return result;
    } on WebDavSyncFailure catch (error) {
      _setMetadataFailure(error);
      _restoreSettledStatus(successStatus: WebDavSyncStatus.idle);
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      return ConnectionTestResult(
        success: false,
        errorCode: error.code,
        message: error.message,
        failure: error,
      );
    }
  }

  Future<void> configure(WebDavSyncConfigDraft draft) async {
    _ensureConnectionIdle();
    _scheduler.cancelPending();
    final password = await _resolvePassword(draft.password);
    final configuration = draft.withoutPassword(
      autoSync: _configuration?.autoSync ?? true,
    );
    final old = _configuration;
    if (old == null ||
        old.serverUrl != configuration.serverUrl ||
        old.rootPath != configuration.rootPath ||
        old.username != configuration.username) {
      await _changeStore.resetRemoteMirrorForNewSpace();
      _remoteBooks = const [];
      _lastResult = null;
      _lastSuccessfulSync = null;
      _lastProgressSyncAt = null;
      _lastCheckedAt = null;
      _backgroundUploadQueue.clear();
      _backgroundUploadTitles.clear();
    }
    await _configStore.save(configuration, password);
    _configuration = configuration;
    if (old == null) {
      // Read after saving credentials so an already persisted scope (including
      // explicit false values) wins over the complete first-connection default.
      _scope = await _configStore.readScope();
      await _configStore.saveScope(_scope);
    }
    _newBookUploadPolicy = await _configStore.readNewBookUploadPolicy();
    _status = WebDavSyncStatus.idle;
    _clearFailures();
    await _discoverUnuploadedBooks();
    notifyListeners();
    requestAutomaticSync(immediate: true);
  }

  Future<WebDavSyncRunResult> syncNow() {
    return _syncMetadataNow().then((result) async {
      if (scope.bookFiles) await synchronizeTextFiles();
      return result;
    });
  }

  Future<WebDavSyncRunResult> _syncMetadataNow() {
    final running = _running;
    if (running != null) return running;
    final future = _runSync();
    _running = future;
    future.then<void>((_) => _running = null, onError: (_) => _running = null);
    return future;
  }

  Future<WebDavSyncRunResult> _runSync() async {
    final progressGeneration = _progressGeneration;
    final syncProgress = scope.progress;
    if (!isConfigured) {
      const failure = WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Configure WebDAV before starting sync.',
      );
      _setMetadataFailure(failure);
      notifyListeners();
      throw failure;
    }
    _status = WebDavSyncStatus.syncing;
    _phase = WebDavSyncPhase.connecting;
    _clearMetadataFailure();
    notifyListeners();
    try {
      final engine =
          _engine ??
          SyncEngine(
            storage:
                await _storageProvider() ??
                (throw const WebDavSyncFailure(
                  WebDavSyncErrorCode.authentication,
                  'WebDAV credentials are unavailable.',
                )),
            scope: _scope,
            changeStore: _changeStore,
            adapters: MetadataSyncAdapters(
              store: _changeStore,
              replaceRuleService: _replaceRuleService,
            ),
          );
      final result = await engine.run(
        onPhase: (phase) {
          _phase = phase;
          notifyListeners();
        },
      );
      _lastResult = result;
      _lastCheckedAt = result.completedAt;
      if (syncProgress) {
        _lastProgressSyncAt = result.completedAt;
        if (progressGeneration == _progressGeneration) _progressPending = false;
      }
      _lastFailedPhase = WebDavSyncPhase.none;
      _lastSuccessfulSync = result.completedAt;
      await _changeStore.setState(
        'last_successful_sync',
        result.completedAt.toUtc().toIso8601String(),
      );
      _pendingChanges = await _enabledPendingCount();
      await _refreshRemoteBooks();
      if (result.downloaded > 0) {
        LibraryEventBus().notifyLibraryChanged();
      }
      _restoreSettledStatus(successStatus: WebDavSyncStatus.success);
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      return result;
    } on WebDavSyncFailure catch (error) {
      _lastFailedPhase = _phase;
      debugPrint(
        'WebDAV sync failed at ${_phase.name}: ${error.code.name}'
        '${error.statusCode == null ? '' : ' (HTTP ${error.statusCode})'}',
      );
      _setMetadataFailure(error);
      _pendingChanges = await _enabledPendingCount();
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      rethrow;
    } on SyncStorageException catch (error) {
      final failure = _storageFailure(error);
      _lastFailedPhase = _phase;
      _setMetadataFailure(failure);
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      throw failure;
    } catch (error, stackTrace) {
      _lastFailedPhase = _phase;
      debugPrint('WebDAV sync failed at ${_phase.name}: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      const failure = WebDavSyncFailure(
        WebDavSyncErrorCode.unknown,
        'Metadata sync could not be completed.',
      );
      _setMetadataFailure(failure);
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      throw failure;
    }
  }

  Future<void> setAutoSync(bool enabled) async {
    final current = _configuration;
    if (current == null) return;
    final credentials = await _configStore.readCredentials();
    if (credentials == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.secureStorage,
        'The secure WebDAV password is unavailable.',
      );
    }
    final updated = current.copyWith(autoSync: enabled);
    await _configStore.save(updated, credentials.password);
    _configuration = updated;
    if (enabled) {
      await _discoverUnuploadedBooks();
      _scheduler.request(immediate: true);
    } else {
      _scheduler.cancelPending();
    }
    notifyListeners();
  }

  Future<void> setAutoResume(bool enabled) async {
    await _configStore.saveAutoResume(enabled);
    _autoResume = enabled;
    notifyListeners();
  }

  Future<void> setScope(WebDavSyncScope scope) async {
    final filesWereEnabled = _scope.bookFiles;
    final normalized = SyncDatasetCatalog.normalizeScope(scope);
    await _configStore.saveScope(normalized);
    _scope = normalized;
    if (!normalized.bookFiles) {
      _clearFileFailure();
      _restoreSettledStatus();
    }
    _pendingChanges = await _enabledPendingCount();
    if (normalized.bookFiles && !filesWereEnabled) {
      await _discoverUnuploadedBooks();
    }
    notifyListeners();
  }

  Future<int> _enabledPendingCount() => _changeStore.pendingCount(
    datasets: SyncDatasetCatalog.enabledRemoteNames(_scope),
  );

  Future<void> setNewBookUploadPolicy(WebDavNewBookUploadPolicy policy) async {
    await _configStore.saveNewBookUploadPolicy(policy);
    _newBookUploadPolicy = policy;
    notifyListeners();
  }

  Future<void> clearConfiguration() async {
    _ensureConnectionIdle();
    _scheduler.cancelPending();
    await _configStore.clear();
    _configuration = null;
    _autoResume = true;
    _lastResult = null;
    _lastCheckedAt = null;
    _lastProgressSyncAt = null;
    _lastSuccessfulSync = null;
    _textStates = const [];
    _remoteBooks = const [];
    _backgroundUploadQueue.clear();
    _backgroundUploadTitles.clear();
    _scope = const WebDavSyncScope();
    _status = WebDavSyncStatus.unconfigured;
    _phase = WebDavSyncPhase.none;
    _lastFailedPhase = WebDavSyncPhase.none;
    _newBookUploadPolicy = WebDavNewBookUploadPolicy.askEveryTime;
    _clearFailures();
    notifyListeners();
    await _changeStore.resetRemoteMirrorForNewSpace();
  }

  void _ensureConnectionIdle() {
    if (_running != null || _fileRun != null || _backgroundUploadRunning) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'Wait for the active transfer before changing the storage connection.',
      );
    }
  }

  Future<void> refreshRemoteBooks() async {
    await _refreshRemoteBooks();
    notifyListeners();
  }

  Future<RemoteBookDescriptor> uploadBookFile(
    Book book, {
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    if (!_scope.bookFiles) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Enable book-file uploads before selecting a book to upload.',
      );
    }
    try {
      final descriptor = await _bookFileService.upload(
        book,
        onProgress: onProgress,
      );
      if (!_backgroundUploadRunning) await syncNow();
      return descriptor;
    } on SyncStorageException catch (error) {
      throw _storageFailure(error);
    }
  }

  Future<void> _discoverUnuploadedBooks() async {
    if (!isConfigured || !autoSync || !scope.bookFiles) return;
    final connection = '$serverUrl|$username|$rootPath';
    try {
      final books = await (localBooksLoader?.call() ?? _loadLocalBooks());
      final states = await _contentSync.listStates();
      if (_disposed || connection != '$serverUrl|$username|$rootPath') return;
      enqueueNewBookUploads(
        books.where(
          (book) => !states.any(
            (state) =>
                !state.enabled &&
                ((book.id != null && state.localBookId == book.id) ||
                    state.localPath == book.filePath),
          ),
        ),
      );
    } catch (error) {
      // Discovery is a restart/first-connect safety net; metadata sync remains
      // independent if the local library is temporarily unavailable.
      debugPrint('WebDAV book discovery will retry: ${error.runtimeType}');
    }
  }

  Future<List<Book>> _loadLocalBooks() async {
    final db = await DatabaseService().database;
    // sync_book_files predates per-space ownership. Always inspect the books
    // table for the current connection; an old binding must not hide a local
    // file from a newly selected WebDAV space.
    final rows = await db.rawQuery('''
      SELECT b.* FROM books b
      WHERE COALESCE(b.storage_type, 'local') != 'online'
        AND COALESCE(b.filePath, '') != ''
        AND NOT EXISTS (
          SELECT 1 FROM sync_book_files f
          WHERE f.local_book_id = b.id AND f.sync_enabled = 0
        )
    ''');
    final books = <Book>[];
    for (final row in rows) {
      try {
        books.add(await bookFromStorageMap(row));
      } catch (_) {
        // A malformed library row must not block discovery of other books.
      }
    }
    return books;
  }

  Future<Book> downloadBookFile(
    RemoteBookDescriptor descriptor, {
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    try {
      final book = await _bookFileService.download(
        descriptor,
        onProgress: onProgress,
      );
      await refreshRemoteBooks();
      return book;
    } on SyncStorageException catch (error) {
      throw _storageFailure(error);
    }
  }

  Future<String> _resolvePassword(String draftPassword) async {
    if (draftPassword.isNotEmpty) return draftPassword;
    final stored = await _configStore.readCredentials();
    if (stored != null && stored.password.isNotEmpty) return stored.password;
    throw const WebDavSyncFailure(
      WebDavSyncErrorCode.authentication,
      'Enter the WebDAV app password.',
    );
  }

  Future<void> _refreshRemoteBooks() async {
    final records = await _changeStore.recordsForDataset('books');
    _remoteBooks = records
        .where((record) => !record.deleted && record.payload != null)
        .map((record) {
          final payload = record.payload!;
          return RemoteBookDescriptor(
            bookUid: record.entityKey,
            title: payload['title'] as String? ?? '',
            author: payload['author'] as String? ?? '',
            format: payload['format'] as String? ?? '',
            fileAvailable: payload['file_available'] as bool? ?? false,
            sizeBytes: (payload['file_size'] as num?)?.toInt(),
            blobSha256: payload['blob_sha256'] as String?,
            remotePath: payload['remote_path'] as String?,
            fileName: payload['file_name'] as String?,
            sourceId: payload['source_id'] as String?,
            sourceBookId: payload['source_book_id'] as String?,
            coverAvailable: payload['cover_available'] as bool? ?? false,
            coverSizeBytes: (payload['cover_file_size'] as num?)?.toInt(),
            coverBlobSha256: payload['cover_blob_sha256'] as String?,
            coverRemotePath: payload['cover_remote_path'] as String?,
            coverFileName: payload['cover_file_name'] as String?,
          );
        })
        .toList(growable: false);
  }

  Future<void> _drainBackgroundBookUploads() async {
    if (_backgroundUploadRunning) return;
    _backgroundUploadRunning = true;
    try {
      // Give every book already in this batch one attempt. Failed books move
      // to the back for a later automatic cycle instead of blocking the rest
      // of the library or spinning forever in this cycle.
      var attemptsRemaining = _backgroundUploadQueue.length;
      while (_backgroundUploadQueue.isNotEmpty && attemptsRemaining > 0) {
        if (!isConfigured || !autoSync || !scope.bookFiles) break;
        final book = _backgroundUploadQueue.removeAt(0);
        attemptsRemaining--;
        if (_textStates.any(
          (state) =>
              !state.enabled &&
              ((book.id != null && state.localBookId == book.id) ||
                  state.localPath == book.filePath),
        )) {
          _backgroundUploadTitles.remove('${book.id ?? book.filePath}');
          continue;
        }
        try {
          await uploadBookFile(book);
        } catch (error, stackTrace) {
          _backgroundUploadQueue.add(book);
          final failure = error is WebDavSyncFailure
              ? error
              : WebDavSyncFailure(
                  WebDavSyncErrorCode.unknown,
                  'The book file "${book.title}" could not be uploaded and will be retried.',
                );
          _backgroundUploadFailure = failure;
          _setFileFailure(failure);
          _restoreSettledStatus();
          notifyListeners();
          debugPrint('Background WebDAV book upload failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }
      if (_backgroundUploadQueue.isEmpty) {
        if (identical(_fileFailure, _backgroundUploadFailure)) {
          _clearFileFailure();
        }
        _backgroundUploadFailure = null;
        _restoreSettledStatus();
        notifyListeners();
      }
    } finally {
      _backgroundUploadRunning = false;
    }
  }

  void _setMetadataFailure(WebDavSyncFailure failure) {
    _metadataFailure = failure;
    _visibleFailure = failure;
    _status = WebDavSyncStatus.failed;
  }

  void _clearMetadataFailure() {
    final failure = _metadataFailure;
    _metadataFailure = null;
    if (identical(_visibleFailure, failure)) _visibleFailure = _fileFailure;
  }

  void _setFileFailure(WebDavSyncFailure failure) {
    _fileFailure = failure;
    _visibleFailure = failure;
  }

  void _clearFileFailure() {
    final failure = _fileFailure;
    _fileFailure = null;
    if (identical(_visibleFailure, failure)) _visibleFailure = _metadataFailure;
  }

  void _clearFailures() {
    _backgroundUploadFailure = null;
    _metadataFailure = null;
    _fileFailure = null;
    _backgroundUploadFailure = null;
    _visibleFailure = null;
  }

  void _restorePersistedFileFailure() {
    if (!scope.bookFiles || _fileFailure != null) return;
    final failed = _textStates.where(
      (state) => state.status == BookContentSyncStatus.failed,
    );
    if (failed.isNotEmpty) {
      final detail = failed.first.error?.trim();
      _setFileFailure(
        WebDavSyncFailure(
          WebDavSyncErrorCode.unknown,
          detail == null || detail.isEmpty
              ? 'A book file could not be synchronized.'
              : detail,
        ),
      );
      return;
    }
    if (_textStates.any(
      (state) => state.status == BookContentSyncStatus.conflict,
    )) {
      _setFileFailure(
        const WebDavSyncFailure(
          WebDavSyncErrorCode.conflict,
          'A book file has conflicting changes that require attention.',
        ),
      );
    }
  }

  void _restoreSettledStatus({WebDavSyncStatus? successStatus}) {
    if (!isConfigured) {
      _status = WebDavSyncStatus.unconfigured;
    } else if (_running != null && successStatus == null) {
      _status = WebDavSyncStatus.syncing;
    } else if (_metadataFailure != null) {
      _status = WebDavSyncStatus.failed;
    } else if (_fileFailure != null) {
      _status = WebDavSyncStatus.partialFailure;
    } else if (successStatus != null) {
      _status = successStatus;
    } else if (_lastResult != null) {
      _status = WebDavSyncStatus.success;
    } else {
      _status = WebDavSyncStatus.idle;
    }
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scheduler.dispose();
    unawaited(_progressSubscription?.cancel());
    unawaited(_textSubscription?.cancel());
    super.dispose();
  }
}

WebDavSyncFailure _storageFailure(SyncStorageException error) {
  if (error.cause case final WebDavSyncFailure failure) return failure;
  final code = switch (error.code) {
    SyncStorageErrorCode.authentication => WebDavSyncErrorCode.authentication,
    SyncStorageErrorCode.permissionDenied =>
      WebDavSyncErrorCode.permissionDenied,
    SyncStorageErrorCode.notFound => WebDavSyncErrorCode.notFound,
    SyncStorageErrorCode.versionConflict => WebDavSyncErrorCode.conflict,
    SyncStorageErrorCode.rateLimited => WebDavSyncErrorCode.rateLimited,
    SyncStorageErrorCode.storageFull => WebDavSyncErrorCode.storageFull,
    SyncStorageErrorCode.timeout => WebDavSyncErrorCode.timeout,
    SyncStorageErrorCode.network => WebDavSyncErrorCode.network,
    SyncStorageErrorCode.tls => WebDavSyncErrorCode.tls,
    SyncStorageErrorCode.unsupported => WebDavSyncErrorCode.serverIncompatible,
    SyncStorageErrorCode.invalidData => WebDavSyncErrorCode.corruptRemoteData,
    SyncStorageErrorCode.serverError => WebDavSyncErrorCode.serverError,
  };
  return WebDavSyncFailure(code, error.message);
}
