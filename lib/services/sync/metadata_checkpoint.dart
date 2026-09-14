import 'dart:convert';

import 'storage/immutable_object_store.dart';
import 'storage/sync_storage.dart';
import 'sync_change_store.dart';
import 'sync_protocol.dart';

/// Checkpoints contain this writer's complete published state, including
/// tombstones. They are paged, immutable and published after all their pages.
/// Readers advance the main cursor only after every page has been applied.
class MetadataCheckpoint {
  MetadataCheckpoint(this.objects, this.store, this.namespace);
  final ImmutableObjectStore objects;
  final SyncChangeStore store;
  final String namespace;
  static const interval = 128;

  Future<void> recordPublished(SyncBatch batch) async {
    final viewNamespace = '$namespace:${batch.deviceId}';
    await store.rememberPublished(viewNamespace, batch);
    if (batch.sequence != 1 && batch.sequence % interval != 0) return;
    final pages = <String>[];
    var selected = <SyncOperation>[];
    Future<void> flush() async {
      if (selected.isEmpty) return;
      final page = SyncBatch.create(
        deviceId: batch.deviceId,
        sequence: batch.sequence,
        createdHlc: batch.createdHlc,
        operations: selected,
      );
      final text = page.encode();
      final hash = ImmutableObjectStore.hashBytes(utf8.encode(text));
      await objects.putText(
        SyncPath('checkpoints/${batch.deviceId}/pages/$hash.json'),
        text,
      );
      pages.add(hash);
      selected = [];
    }

    await for (final operation in store.publishedOperations(viewNamespace)) {
      try {
        SyncBatch.create(
          deviceId: batch.deviceId,
          sequence: batch.sequence,
          createdHlc: batch.createdHlc,
          operations: [...selected, operation],
        );
      } on ArgumentError {
        await flush();
      }
      selected.add(operation);
    }
    await flush();
    final text = jsonEncode({
      'schema_version': 2,
      'device_id': batch.deviceId,
      'sequence': batch.sequence,
      'pages': pages,
    });
    final hash = ImmutableObjectStore.hashBytes(utf8.encode(text));
    await objects.putText(
      SyncPath(
        'checkpoints/${batch.deviceId}/${batch.sequence.toString().padLeft(12, '0')}-$hash.json',
      ),
      text,
    );
  }

  /// Reclaims only this writer's generated logs, behind the older of two
  /// verified checkpoints. A delayed reader can restart from a retained
  /// checkpoint; no book content, export or legacy namespace is deleted.
  Future<void> compact(String deviceId) async {
    final listing = await objects.storage.list(
      SyncPath('checkpoints/$deviceId'),
    );
    final indexes =
        listing.objects
            .where(
              (o) =>
                  RegExp(r'/\d{12}-[a-f0-9]{64}\.json$').hasMatch(o.path.value),
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    if (indexes.length < 2) return;
    final retainedPages = <String>{};
    final retiredPages = <String>{};
    for (var i = 0; i < indexes.length; i++) {
      final name = indexes[i].path.value.split('/').last;
      final data =
          jsonDecode(
                await objects.readText(indexes[i].path, name.substring(13, 77)),
              )
              as Map;
      final pages = (data['pages'] as List).cast<String>();
      (i < 2 ? retainedPages : retiredPages).addAll(pages);
      // Ensure both recovery points still have all their remote pages before
      // removing anything; a local cache alone cannot establish that fact.
      if (i < 2) {
        for (final hash in pages) {
          final remote = SyncPath('checkpoints/$deviceId/pages/$hash.json');
          final text = (await objects.storage.readText(remote)).text;
          if (ImmutableObjectStore.hashBytes(utf8.encode(text)) != hash) {
            throw const SyncStorageException(
              SyncStorageErrorCode.invalidData,
              'Checkpoint maintenance stopped because a recovery page is damaged.',
            );
          }
        }
      }
    }
    final boundary = int.parse(
      indexes[1].path.value.split('/').last.substring(0, 12),
    );
    final logs = await objects.storage.list(SyncPath('changes/$deviceId'));
    for (final log in logs.objects) {
      final match = RegExp(
        r'^(\d{12})-[a-f0-9]{64}\.json$',
      ).firstMatch(log.path.value.split('/').last);
      if (match != null && int.parse(match[1]!) <= boundary) {
        await objects.storage.delete(log.path, expectedVersion: log.version);
      }
    }
    for (final index in indexes.skip(2)) {
      await objects.storage.delete(index.path, expectedVersion: index.version);
    }
    for (final hash in retiredPages.difference(retainedPages)) {
      final remote = SyncPath('checkpoints/$deviceId/pages/$hash.json');
      final info = await objects.storage.stat(remote);
      if (info != null) {
        await objects.storage.delete(remote, expectedVersion: info.version);
      }
    }
  }

  Future<int> restore(
    String deviceId,
    int cursor,
    Future<void> Function(SyncBatch batch, String snapshotNamespace) apply,
  ) async {
    SyncListing listing;
    try {
      listing = await objects.storage.list(SyncPath('checkpoints/$deviceId'));
    } on SyncStorageException catch (error) {
      if (error.code != SyncStorageErrorCode.notFound) rethrow;
      return cursor;
    }
    final candidates =
        listing.objects
            .where(
              (o) =>
                  RegExp(r'/\d{12}-[a-f0-9]{64}\.json$').hasMatch(o.path.value),
            )
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    if (candidates.isEmpty) return cursor;
    final candidate = candidates.first;
    final name = candidate.path.value.split('/').last;
    final sequence = int.parse(name.substring(0, 12));
    if (sequence <= cursor) return cursor;
    final hash = name.substring(13, 77);
    final data =
        (jsonDecode(await objects.readText(candidate.path, hash)) as Map)
            .cast<String, dynamic>();
    if (data['schema_version'] != 2 ||
        data['device_id'] != deviceId ||
        data['sequence'] != sequence ||
        data['pages'] is! List ||
        (data['pages'] as List).isEmpty) {
      throw const SyncStorageException(
        SyncStorageErrorCode.invalidData,
        'Invalid metadata checkpoint.',
      );
    }
    // Validate and load all page envelopes before touching the main cursor.
    final pages = <SyncBatch>[];
    for (final page in (data['pages'] as List).cast<String>()) {
      final batch = SyncBatch.decode(
        await objects.readText(
          SyncPath('checkpoints/$deviceId/pages/$page.json'),
          page,
        ),
      );
      if (batch.deviceId != deviceId || batch.sequence != sequence) {
        throw const SyncStorageException(
          SyncStorageErrorCode.invalidData,
          'Invalid checkpoint page identity.',
        );
      }
      pages.add(batch);
    }
    for (final page in pages) {
      await apply(page, '$namespace:checkpoint:$hash');
    }
    await store.advanceCursor(deviceId, sequence, namespace: namespace);
    return sequence;
  }
}
