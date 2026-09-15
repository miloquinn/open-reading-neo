import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/book_revision_repository.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/storage/immutable_object_store.dart';
import 'package:xxread/services/sync/storage/webdav_sync_storage.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_client.dart';

import 'support/local_webdav_server.dart';

void main() {
  const mib = int.fromEnvironment('SYNC_BENCHMARK_MIB', defaultValue: 8);
  test(
    'streaming $mib MiB TXT prefix edit uploads one whole file over real HTTP',
    () async {
      final dav = await LocalWebDavServer.start();
      final local = await Directory.systemTemp.createTemp('sync-benchmark-');
      try {
        final storage = WebDavSyncStorage(
          WebDavClient.standard(
            StoredSyncCredentials(
              WebDavSyncConfiguration(
                serverUrl: dav.url,
                username: 'fixture',
                allowInsecurePrivateHttp: true,
              ),
              'fixture',
            ),
          ),
        );
        final objects = ImmutableObjectStore(
          storage,
          Directory('${local.path}/writer'),
        );
        final repository = BookRevisionRepository(objects);
        final file = File('${local.path}/book.txt');
        final sink = file.openWrite();
        final random = Random(814);
        try {
          for (var i = 0; i < mib * 16; i++) {
            final buffer = Uint8List(65536);
            for (var j = 0; j < buffer.length; j++) {
              buffer[j] = 32 + random.nextInt(95);
            }
            sink.add(buffer);
            await sink.flush();
          }
        } finally {
          await sink.close();
        }
        final watch = Stopwatch()..start();
        final first = await repository.publish(
          bookUid: 'benchmark',
          file: file,
          hash: await ImmutableObjectStore.hashFile(file),
          format: 'txt',
          fileName: 'book.txt',
          parents: [],
          metadata: {},
        );
        final initialUpload = dav.uploaded;
        final initialDownload = dav.downloaded;
        final initialMs = watch.elapsedMilliseconds;
        final edited = File('${local.path}/edited.txt');
        final output = edited.openWrite();
        try {
          output.add([65, 66, 67, 68, 69, 70, 71]);
          await output.addStream(file.openRead());
        } finally {
          await output.close();
        }
        watch.reset();
        final second = await repository.publish(
          bookUid: 'benchmark',
          file: edited,
          hash: await ImmutableObjectStore.hashFile(edited),
          format: 'txt',
          fileName: 'book.txt',
          parents: [first.id],
          metadata: {},
        );
        final changedUpload = dav.uploaded - initialUpload;
        final changedDownload = dav.downloaded - initialDownload;
        final changedMs = watch.elapsedMilliseconds;
        expect(initialUpload, greaterThanOrEqualTo(mib * 1024 * 1024));
        final editedSize = await edited.length();
        expect(second.chunks, hasLength(1));
        expect(changedUpload, inInclusiveRange(editedSize, editedSize + 4096));
        expect(changedDownload, changedUpload);
        final reader = BookRevisionRepository(
          ImmutableObjectStore(storage, Directory('${local.path}/reader')),
        );
        final restored = File('${local.path}/restored.txt');
        await reader.materialize(
          await reader.read('benchmark', second.id),
          restored,
        );
        expect(
          await ImmutableObjectStore.hashFile(restored),
          await ImmutableObjectStore.hashFile(edited),
        );
        // These are HTTP body bytes counted by the server, including manifests
        // and upload verification, rather than logical book sizes.
        // ignore: avoid_print
        print(
          'BENCHMARK mib=$mib initial_upload=$initialUpload initial_download=$initialDownload '
          'changed_upload=$changedUpload changed_download=$changedDownload '
          'initial_ms=$initialMs changed_ms=$changedMs blocks=${second.chunks.length}',
        );
      } finally {
        await dav.close();
        await local.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
