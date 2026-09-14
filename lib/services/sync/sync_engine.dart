import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'adapters/metadata_sync_adapters.dart';
import 'storage/sync_storage.dart';
import 'storage/immutable_object_store.dart';
import 'sync_change_store.dart';
import 'sync_clock.dart';
import 'sync_dataset_catalog.dart';
import 'sync_models.dart';
import 'sync_protocol.dart';
import 'metadata_checkpoint.dart';
import 'sync_space.dart';

class SyncEngine {
  SyncEngine({
    required this.storage,
    required this.scope,
    required SyncChangeStore changeStore,
    MetadataSyncAdapters? adapters,
    this.installationId,
  }) : _changeStore = changeStore,
       _adapters = adapters ?? MetadataSyncAdapters(store: changeStore);

  static final SyncPath _devicesPath = SyncPath('changes');

  final String? installationId;
  final SyncStorage storage;
  final WebDavSyncScope scope;
  final SyncChangeStore _changeStore;
  final MetadataSyncAdapters _adapters;
  String _namespace = '';
  late ImmutableObjectStore _objects;

  String _stateKey(String name) => 'metadata:$_namespace:$name';

  Future<WebDavSyncRunResult> run({
    void Function(WebDavSyncPhase phase)? onPhase,
  }) async {
    onPhase?.call(WebDavSyncPhase.connecting);
    final spaceId = await SyncSpace.ensure(storage);
    _namespace = sha256
        .convert(
          utf8.encode(
            '${storage.spaceKey}\u0000$spaceId\u0000${installationId ?? 'local'}',
          ),
        )
        .toString();
    await _prepareSpaceState('${storage.spaceKey}\u0000$spaceId');
    // Cache only immutable bytes, isolated by both account and space identity.
    _objects = ImmutableObjectStore(
      storage,
      Directory(
        '${Directory.systemTemp.path}/open-reading-sync-cache/$_namespace',
      ),
    );

    _checkClockSkew(storage.serverDate);

    final deviceId = await _deviceId();
    final clock = HybridLogicalClock(deviceId: deviceId);
    final latestLocalTimestamp = await _changeStore.latestTimestamp();
    if (latestLocalTimestamp != null) clock.observe(latestLocalTimestamp);

    onPhase?.call(WebDavSyncPhase.scanningLocal);
    await _adapters.scan(scope, clock);
    onPhase?.call(WebDavSyncPhase.readingRemote);
    var downloaded = 0;
    var conflicts = 0;
    final remoteDeviceIds = <String>{};
    for (final prefix in (await _listOrEmpty(_devicesPath)).prefixes) {
      final parts = prefix.value.split('/');
      if (parts.length == 2 && parts[0] == 'changes' && parts[1] != deviceId) {
        remoteDeviceIds.add(parts[1]);
      }
    }
    for (final remoteDeviceId in remoteDeviceIds) {
      final listing = await _listOrEmpty(_devicesPath.child(remoteDeviceId));
      var cursor = await _changeStore.cursorFor(
        remoteDeviceId,
        namespace: _namespace,
      );
      cursor = await MetadataCheckpoint(_objects, _changeStore, _namespace)
          .restore(remoteDeviceId, cursor, (batch, checkpointNamespace) async {
            for (final operation in batch.operations) {
              clock.observe(HybridLogicalTimestamp.parse(operation.hlc));
            }
            downloaded += await _changeStore.applyRemoteBatch(
              batch,
              cursorNamespace: checkpointNamespace,
              validateWinner: _adapters.validate,
              normalizeWinner: _adapters.normalizeRemoteWinner,
              cleanupWinnerAliases: _adapters.cleanupRemoteWinnerAliases,
              applyWinner: (txn, operation) =>
                  _adapters.apply(txn, operation, scope: scope),
            );
          });
      final batches = <int, SyncPath>{};
      for (final object in listing.objects) {
        final name = object.path.value.split('/').last;
        final match = RegExp(
          r'^(\d{12})-([a-f0-9]{64})\.json$',
        ).firstMatch(name);
        if (match == null) continue;
        final sequence = int.parse(match[1]!);
        if (batches.containsKey(sequence)) {
          throw const SyncStorageException(
            SyncStorageErrorCode.versionConflict,
            'A cloned device published two versions of the same metadata sequence.',
          );
        }
        batches[sequence] = object.path;
      }
      final sequences =
          batches.keys.where((sequence) => sequence > cursor).toList()..sort();
      for (final sequence in sequences) {
        if (sequence != cursor + 1) {
          throw const SyncStorageException(
            SyncStorageErrorCode.notFound,
            'A metadata batch is not visible yet. Sync will retry without skipping it.',
          );
        }
        final remotePath = batches[sequence]!;
        final hash = remotePath.value.split('/').last.substring(13, 77);
        late final SyncBatch batch;
        try {
          batch = SyncBatch.decode(await _objects.readText(remotePath, hash));
        } on FormatException {
          throw const SyncStorageException(
            SyncStorageErrorCode.invalidData,
            'A remote metadata batch is invalid.',
          );
        }
        if (batch.deviceId != remoteDeviceId || batch.sequence != sequence) {
          throw const SyncStorageException(
            SyncStorageErrorCode.invalidData,
            'A remote metadata batch has an invalid identity.',
          );
        }
        for (final operation in batch.operations) {
          clock.observe(HybridLogicalTimestamp.parse(operation.hlc));
        }
        onPhase?.call(WebDavSyncPhase.applyingRemote);
        final applied = await _changeStore.applyRemoteBatch(
          batch,
          cursorNamespace: _namespace,
          validateWinner: _adapters.validate,
          normalizeWinner: _adapters.normalizeRemoteWinner,
          cleanupWinnerAliases: _adapters.cleanupRemoteWinnerAliases,
          applyWinner: (txn, operation) =>
              _adapters.apply(txn, operation, scope: scope),
        );
        downloaded += applied;
        conflicts += batch.operations.length - applied;
        cursor = sequence;
      }
    }

    onPhase?.call(WebDavSyncPhase.scanningLocal);
    await _adapters.scan(scope, clock);
    onPhase?.call(WebDavSyncPhase.uploadingLocal);
    var uploaded = 0;
    while (true) {
      final published = await _publish(deviceId, clock);
      if (published == 0) break;
      uploaded += published;
    }
    onPhase?.call(WebDavSyncPhase.finishing);
    return WebDavSyncRunResult(
      uploaded: uploaded,
      downloaded: downloaded,
      skipped: conflicts,
      conflictsResolved: conflicts,
      completedAt: DateTime.now(),
    );
  }

  Future<void> _prepareSpaceState(String contentSpace) async {
    final active = await _changeStore.getState('active_metadata_space');
    if (active == _namespace) return;
    await _changeStore.resetRemoteMirrorForNewSpace(
      preserveFileSpace: contentSpace,
    );
    await _changeStore.setState('active_metadata_space', _namespace);
  }

  Future<int> _publish(String deviceId, HybridLogicalClock clock) async {
    final enabledDatasets = SyncDatasetCatalog.enabledRemoteNames(scope);
    final pendingKey = _stateKey('pending_batch');
    final sequenceKey = _stateKey('local_sequence');
    final pendingRaw = await _changeStore.getState(pendingKey);
    SyncBatch? batch;
    List<SyncRecord> records = const [];
    if (pendingRaw != null && pendingRaw.isNotEmpty) {
      batch = SyncBatch.decode(pendingRaw);
      final unauthorized = batch.operations.any(
        (operation) => !SyncDatasetCatalog.isRecordPublishable(
          dataset: operation.dataset,
          recordId: operation.recordId,
          entityKey: operation.entityKey,
          payload: operation.payload,
          scope: scope,
        ),
      );
      if (unauthorized) {
        final uploaded = await _readOptional(_batchPath(batch));
        if (uploaded == null) {
          await _changeStore.setState(pendingKey, '');
          return _publish(deviceId, clock);
        }
        if (SyncBatch.decode(uploaded.text).sha256 != batch.sha256) {
          throw const SyncStorageException(
            SyncStorageErrorCode.versionConflict,
            'The pending batch conflicts with the remote device log.',
          );
        }
      }
      final dirty = await _changeStore.dirtyRecords();
      final ids = batch.operations
          .map(
            (operation) =>
                '${operation.dataset}\u0000${operation.recordId}\u0000${operation.hlc}',
          )
          .toSet();
      records = dirty
          .where(
            (record) => ids.contains(
              '${record.dataset}\u0000${record.recordId}\u0000${record.hlc}',
            ),
          )
          .toList(growable: false);
    } else {
      final dirty = (await _changeStore.dirtyRecords(datasets: enabledDatasets))
          .where(
            (record) => SyncDatasetCatalog.isRecordPublishable(
              dataset: record.dataset,
              recordId: record.recordId,
              entityKey: record.entityKey,
              payload: record.payload,
              scope: scope,
            ),
          )
          .toList(growable: false);
      if (dirty.isEmpty) return 0;
      final sequence =
          int.tryParse(await _changeStore.getState(sequenceKey) ?? '') ?? 0;
      final selected = <SyncRecord>[];
      for (final record in dirty) {
        try {
          SyncBatch.create(
            deviceId: deviceId,
            sequence: sequence + 1,
            createdHlc: clock.tick().toString(),
            operations: [
              ...selected,
              record,
            ].map((item) => item.toOperation()).toList(),
          );
          selected.add(record);
        } on ArgumentError {
          break;
        }
      }
      if (selected.isEmpty) {
        throw const SyncStorageException(
          SyncStorageErrorCode.invalidData,
          'A metadata record exceeds the 1 MiB batch limit.',
        );
      }
      records = selected;
      batch = SyncBatch.create(
        deviceId: deviceId,
        sequence: sequence + 1,
        createdHlc: clock.tick().toString(),
        operations: selected.map((item) => item.toOperation()).toList(),
      );
      await _changeStore.setState(pendingKey, batch.encode());
    }

    await _createImmutableText(_batchPath(batch), batch.encode());
    await MetadataCheckpoint(
      _objects,
      _changeStore,
      _namespace,
    ).recordPublished(batch);
    await _changeStore.markUploaded(records);
    await _changeStore.setState(sequenceKey, '${batch.sequence}');
    await _changeStore.setState(pendingKey, '');
    if (batch.sequence % MetadataCheckpoint.interval == 0) {
      try {
        await MetadataCheckpoint(
          _objects,
          _changeStore,
          _namespace,
        ).compact(deviceId);
        await _changeStore.deleteState(_stateKey('maintenance_error'));
      } on SyncStorageException catch (error) {
        // Publication is already verified. Cleanup availability must not turn
        // a successful data sync into a failed upload or reset its sequence.
        await _changeStore.setState(
          _stateKey('maintenance_error'),
          error.code.name,
        );
      }
    }
    return records.length;
  }

  Future<void> _createImmutableText(SyncPath path, String content) =>
      _objects.putText(path, content);

  Future<SyncTextRead?> _readOptional(SyncPath path) async {
    try {
      return await storage.readText(path);
    } on SyncStorageException catch (error) {
      if (error.code == SyncStorageErrorCode.notFound) return null;
      rethrow;
    }
  }

  Future<SyncListing> _listOrEmpty(SyncPath path) async {
    try {
      return await storage.list(path);
    } on SyncStorageException catch (error) {
      if (error.code == SyncStorageErrorCode.notFound) {
        return const SyncListing(objects: [], prefixes: []);
      }
      rethrow;
    }
  }

  SyncPath _batchPath(SyncBatch batch) => _devicesPath
      .child(batch.deviceId)
      .child(
        '${batch.sequence.toString().padLeft(12, '0')}-${ImmutableObjectStore.hashBytes(utf8.encode(batch.encode()))}.json',
      );

  Future<String> _deviceId() async {
    final key = _stateKey('device_id');
    final existing = await _changeStore.getState(key);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _changeStore.setState(key, created);
    return created;
  }

  void _checkClockSkew(DateTime? serverDate) {
    if (serverDate == null) return;
    if (DateTime.now().toUtc().difference(serverDate).abs() >
        const Duration(hours: 24)) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'The device clock differs from storage by more than 24 hours.',
      );
    }
  }
}
