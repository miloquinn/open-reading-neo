import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'adapters/metadata_sync_adapters.dart';
import 'storage/sync_storage.dart';
import 'sync_change_store.dart';
import 'sync_clock.dart';
import 'sync_dataset_catalog.dart';
import 'sync_models.dart';
import 'sync_protocol.dart';

class SyncEngine {
  SyncEngine({
    required this.storage,
    required this.scope,
    required SyncChangeStore changeStore,
    MetadataSyncAdapters? adapters,
  }) : _changeStore = changeStore,
       _adapters = adapters ?? MetadataSyncAdapters(store: changeStore);

  static final SyncPath _formatPath = SyncPath('format.json');
  static final SyncPath _devicesPath = SyncPath('sync/metadata/devices');

  final SyncStorage storage;
  final WebDavSyncScope scope;
  final SyncChangeStore _changeStore;
  final MetadataSyncAdapters _adapters;
  String _namespace = '';

  String _stateKey(String name) => 'metadata:$_namespace:$name';

  Future<WebDavSyncRunResult> run({
    void Function(WebDavSyncPhase phase)? onPhase,
  }) async {
    if (!storage.capabilities.strongVersions) {
      throw const SyncStorageException(
        SyncStorageErrorCode.unsupported,
        'This storage provider cannot safely perform bidirectional sync.',
      );
    }
    onPhase?.call(WebDavSyncPhase.connecting);
    final spaceId = await _ensureSpace();
    _namespace = sha256
        .convert(utf8.encode('${storage.spaceKey}\u0000$spaceId'))
        .toString();
    await _prepareSpaceState();
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
      if (parts.length == 4 &&
          parts[0] == 'sync' &&
          parts[1] == 'metadata' &&
          parts[2] == 'devices' &&
          parts[3] != deviceId) {
        remoteDeviceIds.add(parts[3]);
      }
    }
    for (final remoteDeviceId in remoteDeviceIds) {
      final headRead = await _readOptional(_headPath(remoteDeviceId));
      if (headRead == null) continue;
      late final RemoteDeviceHead head;
      try {
        head = RemoteDeviceHead.decode(headRead.text);
      } catch (_) {
        throw const SyncStorageException(
          SyncStorageErrorCode.invalidData,
          'A remote device head is invalid.',
        );
      }
      if (head.deviceId != remoteDeviceId) {
        throw const SyncStorageException(
          SyncStorageErrorCode.invalidData,
          'A remote device head does not match its directory.',
        );
      }
      var cursor = await _changeStore.cursorFor(
        remoteDeviceId,
        namespace: _namespace,
      );
      while (cursor < head.latestSequence) {
        final sequence = cursor + 1;
        final batchRead = await storage.readText(
          _batchPath(remoteDeviceId, sequence),
        );
        late final SyncBatch batch;
        try {
          batch = SyncBatch.decode(batchRead.text);
        } catch (_) {
          throw const SyncStorageException(
            SyncStorageErrorCode.invalidData,
            'A remote metadata batch is missing or invalid.',
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

  Future<void> _prepareSpaceState() async {
    final active = await _changeStore.getState('active_metadata_space');
    if (active == _namespace) return;
    await _changeStore.resetRemoteMirrorForNewSpace();
    await _changeStore.setState('active_metadata_space', _namespace);
  }

  Future<String> _ensureSpace() async {
    final existing = await _readOptional(_formatPath);
    if (existing != null) {
      return _validateSpace(existing.text);
    }
    final content = jsonEncode({
      'protocol': 'open-reading-sync',
      'schema_version': 1,
      'space_id': const Uuid().v4(),
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'metadata_encoding': 'json',
      'content_encryption': 'none',
    });
    try {
      await _createText(_formatPath, content);
      return _validateSpace(content);
    } on SyncStorageException catch (error) {
      if (error.code != SyncStorageErrorCode.versionConflict) rethrow;
      return _validateSpace((await storage.readText(_formatPath)).text);
    }
  }

  String _validateSpace(String existing) {
    try {
      final json = (jsonDecode(existing) as Map).cast<String, dynamic>();
      if (json['protocol'] != 'open-reading-sync' ||
          json['schema_version'] != 1 ||
          json['metadata_encoding'] != 'json' ||
          json['content_encryption'] != 'none') {
        throw const FormatException();
      }
      final spaceId = json['space_id'];
      if (spaceId is! String || spaceId.isEmpty) throw const FormatException();
      return spaceId;
    } catch (_) {
      throw const SyncStorageException(
        SyncStorageErrorCode.unsupported,
        'This folder contains an unsupported Open Reading sync space.',
      );
    }
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
        final uploaded = await _readOptional(
          _batchPath(deviceId, batch.sequence),
        );
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

    await _createImmutableText(
      _batchPath(deviceId, batch.sequence),
      batch.encode(),
    );
    final head = RemoteDeviceHead(
      deviceId: deviceId,
      latestSequence: batch.sequence,
      latestHlc: batch.createdHlc,
      updatedAt: DateTime.now().toUtc(),
    ).encode();
    await _writeMutableText(_headPath(deviceId), head);
    await _changeStore.markUploaded(records);
    await _changeStore.setState(sequenceKey, '${batch.sequence}');
    await _changeStore.setState(pendingKey, '');
    return records.length;
  }

  Future<void> _createImmutableText(SyncPath path, String content) async {
    try {
      await _createText(path, content);
    } on SyncStorageException catch (error) {
      if (error.code != SyncStorageErrorCode.versionConflict) rethrow;
      if ((await storage.readText(path)).text != content) {
        throw const SyncStorageException(
          SyncStorageErrorCode.versionConflict,
          'An immutable metadata object contains different data.',
        );
      }
    }
  }

  Future<void> _writeMutableText(SyncPath path, String content) async {
    final bytes = utf8.encode(content);
    final current = await storage.stat(path);
    try {
      if (current == null) {
        await storage.create(
          path,
          Stream.value(bytes),
          length: bytes.length,
          contentType: 'application/json; charset=utf-8',
        );
      } else {
        await storage.compareAndSwap(
          path,
          Stream.value(bytes),
          length: bytes.length,
          contentType: 'application/json; charset=utf-8',
          expectedVersion: current.version,
        );
      }
    } on SyncStorageException catch (error) {
      if (error.code != SyncStorageErrorCode.versionConflict) rethrow;
      if ((await storage.readText(path)).text != content) rethrow;
    }
  }

  Future<void> _createText(SyncPath path, String content) async {
    final bytes = utf8.encode(content);
    await storage.create(
      path,
      Stream.value(bytes),
      length: bytes.length,
      contentType: 'application/json; charset=utf-8',
    );
  }

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

  SyncPath _headPath(String deviceId) =>
      _devicesPath.child(deviceId).child('head.json');

  SyncPath _batchPath(String deviceId, int sequence) => _devicesPath
      .child(deviceId)
      .child('changes')
      .child('${sequence.toString().padLeft(12, '0')}.json');

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
