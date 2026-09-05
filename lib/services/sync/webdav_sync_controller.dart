import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/book.dart';
import '../library/library_event_bus_service.dart';
import '../reader/replace_rule_service.dart';
import '../books/txt_content_change_bus.dart';

import 'adapters/metadata_sync_adapters.dart';
import 'automatic_sync_scheduler.dart';
import 'book_sync_identity.dart';
import 'mutable_txt_sync_service.dart';
import 'reading_progress_sync_service.dart';
import 'secure_sync_config.dart';
import 'sync_change_store.dart';
import 'sync_dataset_catalog.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'webdav_book_file_service.dart';
import 'webdav_client.dart';

class WebDavSyncController extends ChangeNotifier {
  WebDavSyncController({
    SecureSyncConfigStore? configStore,
    SyncChangeStore? changeStore,
    SyncEngine? engine,
    WebDavClientFactory? clientFactory,
    WebDavBookFileService? bookFileService,
    MutableTxtSyncService? mutableTxtService,
    this._replaceRuleService,
  }) : _configStore = configStore ?? SecureSyncConfigStore(),
       _changeStore = changeStore ?? SyncChangeStore(),
       _clientFactory = clientFactory ?? WebDavClient.standard {
    _engine = engine;
    _mutableTxt =
        mutableTxtService ??
        MutableTxtSyncService(
          configStore: _configStore,
          clientFactory: _clientFactory,
        );
    _bookFileService =
        bookFileService ??
        WebDavBookFileService(
          configStore: _configStore,
          clientFactory: _clientFactory,
          mutableTxtSyncService: _mutableTxt,
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
  SyncEngine? _engine;
  late final WebDavBookFileService _bookFileService;
  Future<WebDavSyncRunResult>? _running;
  WebDavSyncConfiguration? _configuration;
  WebDavSyncScope _scope = const WebDavSyncScope();
  WebDavSyncStatus _status = WebDavSyncStatus.unconfigured;
  WebDavSyncPhase _phase = WebDavSyncPhase.none;
  WebDavSyncPhase _lastFailedPhase = WebDavSyncPhase.none;
  DateTime? _lastSuccessfulSync;
  int _pendingChanges = 0;
  WebDavSyncErrorCode? _lastError;
  String? _lastErrorMessage;
  WebDavSyncRunResult? _lastResult;
  List<RemoteBookDescriptor> _remoteBooks = const [];
  WebDavNewBookUploadPolicy _newBookUploadPolicy =
      WebDavNewBookUploadPolicy.askEveryTime;
  final List<Book> _backgroundUploadQueue = <Book>[];
  final Set<String> _backgroundUploadTitles = <String>{};
  bool _backgroundUploadRunning = false;
  late final MutableTxtSyncService _mutableTxt;
  StreamSubscription<ReadingProgressSyncEvent>? _progressSubscription;
  StreamSubscription<TxtContentChanged>? _textSubscription;
  Future<void>? _fileRun;
  List<MutableTxtBookState> _textStates = const [];
  bool get syncingText => _fileRun != null;
  List<MutableTxtBookState> get textStates => List.unmodifiable(_textStates);
  MutableTxtSyncService get mutableTxtService => _mutableTxt;

  Future<void> refreshTextStates() async {
    _textStates = await _mutableTxt.listStates();
    notifyListeners();
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
    return _fileRun ??= _runTextFiles(automatic: automatic).whenComplete(() {
      _fileRun = null;
      notifyListeners();
    });
  }

  Future<void> _runTextFiles({required bool automatic}) async {
    notifyListeners();
    final connection = '$serverUrl|$username|$rootPath';
    try {
      // Follow a storage upgrade on the file lane. Waiting for another file
      // operation must never delay the independent reading-progress lane.
      final boundUids = (await _mutableTxt.listStates())
          .map((state) => state.bookUid)
          .toSet();
      for (final remote in _remoteBooks.toList(growable: false)) {
        final remotePath = remote.remotePath;
        final hash = remote.blobSha256;
        final size = remote.sizeBytes;
        if (!boundUids.contains(remote.bookUid) ||
            remote.format.toLowerCase() != 'txt' ||
            remotePath == null ||
            !remotePath.startsWith('v3:') ||
            hash == null ||
            size == null) {
          continue;
        }
        await _mutableTxt.followRemoteStorage(
          bookUid: remote.bookUid,
          remotePath: remotePath,
          contentHash: hash,
          fileSize: size,
        );
      }
      final result = await _mutableTxt.reconcile(
        shouldContinue: () =>
            !_disposed &&
            isConfigured &&
            scope.bookFiles &&
            connection == '$serverUrl|$username|$rootPath' &&
            (!automatic || autoSync),
      );
      _textStates = await _mutableTxt.listStates();
      if (result.failed > 0 ||
          result.conflicts > 0 ||
          _textStates.any(
            (s) =>
                s.status == MutableTxtSyncStatus.failed ||
                s.status == MutableTxtSyncStatus.conflict,
          )) {
        _status = WebDavSyncStatus.partialFailure;
      }
      if (result.downloaded > 0) LibraryEventBus().notifyLibraryChanged();
      if (result.uploaded > 0 || result.downloaded > 0) {
        // Publish the file descriptor after its current TXT is committed.
        // This stays on the small metadata lane, independent of file transfer.
        await _syncMetadataNow();
      }
      await _refreshRemoteBooks();
    } catch (_) {
      _status = WebDavSyncStatus.partialFailure;
      rethrow;
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
      final bindings = await _mutableTxt.listStates();
      if (!bindings.any((state) => state.bookUid == uid)) return;
      await _mutableTxt.enqueueLocalUpdate(event.book, bookUid: uid);
      _textStates = await _mutableTxt.listStates();
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
  WebDavSyncErrorCode? get lastError => _lastError;
  String? get lastErrorMessage => _lastErrorMessage;
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
    await _mutableTxt.recoverLocalState();
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
    _textStates = await _mutableTxt.listStates();
    _scheduler.start();
    notifyListeners();
  }

  Future<ConnectionTestResult> testConnection(
    WebDavSyncConfigDraft draft,
  ) async {
    _status = WebDavSyncStatus.testing;
    _phase = WebDavSyncPhase.connecting;
    _clearError();
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
        _lastError = result.errorCode;
        _lastErrorMessage = result.message;
      }
      _status = isConfigured
          ? WebDavSyncStatus.idle
          : WebDavSyncStatus.unconfigured;
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      return result;
    } on WebDavSyncFailure catch (error) {
      _setFailure(error);
      _status = isConfigured
          ? WebDavSyncStatus.idle
          : WebDavSyncStatus.unconfigured;
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      return ConnectionTestResult(
        success: false,
        errorCode: error.code,
        message: error.message,
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
    if (_configuration == null) {
      _scope = await _configStore.readScope();
      await _configStore.saveScope(_scope);
    }
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
    _status = WebDavSyncStatus.idle;
    _clearError();
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
      _setFailure(failure);
      notifyListeners();
      throw failure;
    }
    _status = WebDavSyncStatus.syncing;
    _phase = WebDavSyncPhase.connecting;
    _clearError();
    notifyListeners();
    try {
      final engine = _engine ??= SyncEngine(
        configStore: _configStore,
        changeStore: _changeStore,
        adapters: MetadataSyncAdapters(
          store: _changeStore,
          replaceRuleService: _replaceRuleService,
        ),
        clientFactory: _clientFactory,
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
      _status =
          scope.bookFiles &&
              _textStates.any(
                (state) =>
                    state.status == MutableTxtSyncStatus.failed ||
                    state.status == MutableTxtSyncStatus.conflict,
              )
          ? WebDavSyncStatus.partialFailure
          : WebDavSyncStatus.success;
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      return result;
    } on WebDavSyncFailure catch (error) {
      _lastFailedPhase = _phase;
      debugPrint(
        'WebDAV sync failed at ${_phase.name}: ${error.code.name}'
        '${error.statusCode == null ? '' : ' (HTTP ${error.statusCode})'}',
      );
      _setFailure(error);
      _pendingChanges = await _enabledPendingCount();
      _phase = WebDavSyncPhase.none;
      notifyListeners();
      rethrow;
    } catch (error, stackTrace) {
      _lastFailedPhase = _phase;
      debugPrint('WebDAV sync failed at ${_phase.name}: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      const failure = WebDavSyncFailure(
        WebDavSyncErrorCode.unknown,
        'Metadata sync could not be completed.',
      );
      _setFailure(failure);
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
    final normalized = SyncDatasetCatalog.normalizeScope(scope);
    await _configStore.saveScope(normalized);
    _scope = normalized;
    _pendingChanges = await _enabledPendingCount();
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
    _clearError();
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
    bool incrementalTxt = false,
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    if (!_scope.bookFiles) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Enable book-file uploads before selecting a book to upload.',
      );
    }
    final descriptor = await _bookFileService.upload(
      book,
      incrementalTxt: incrementalTxt,
      onProgress: onProgress,
    );
    await syncNow();
    return descriptor;
  }

  Future<Book> downloadBookFile(
    RemoteBookDescriptor descriptor, {
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    final book = await _bookFileService.download(
      descriptor,
      onProgress: onProgress,
    );
    await refreshRemoteBooks();
    return book;
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
      while (_backgroundUploadQueue.isNotEmpty) {
        if (!isConfigured || !autoSync || !scope.bookFiles) break;
        final book = _backgroundUploadQueue.removeAt(0);
        try {
          await uploadBookFile(book);
        } catch (error, stackTrace) {
          _backgroundUploadQueue.insert(0, book);
          debugPrint('Background WebDAV book upload failed: $error');
          debugPrintStack(stackTrace: stackTrace);
          break;
        }
      }
    } finally {
      _backgroundUploadRunning = false;
    }
  }

  void _setFailure(WebDavSyncFailure failure) {
    _status = WebDavSyncStatus.failed;
    _lastError = failure.code;
    _lastErrorMessage = failure.message;
  }

  void _clearError() {
    _lastError = null;
    _lastErrorMessage = null;
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
