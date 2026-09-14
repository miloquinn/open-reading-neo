import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/book_revision_repository.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/storage/immutable_object_store.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';
import 'package:xxread/services/sync/storage/webdav_sync_storage.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/sync_space.dart';
import 'package:xxread/services/sync/webdav_client.dart';

import 'support/local_webdav_server.dart';

void main() {
  late LocalWebDavServer dav;
  late Directory local;
  late WebDavClient client;
  late WebDavSyncStorage storage;
  setUp(() async {
    dav = await LocalWebDavServer.start();
    local = await Directory.systemTemp.createTemp('dav-client-');
    client = WebDavClient.standard(
      StoredSyncCredentials(
        WebDavSyncConfiguration(
          serverUrl: dav.url,
          username: 'reader',
          rootPath: '中文 space',
          allowInsecurePrivateHttp: true,
        ),
        'private-password',
      ),
    );
    storage = WebDavSyncStorage(client);
  });
  tearDown(() async {
    await dav.close();
    await local.delete(recursive: true);
  });

  test(
    'connection and two-device revision transfer work without ETags or conditional writes',
    () async {
      expect((await client.testConnection()).success, isTrue);
      await SyncSpace.ensure(storage);
      final first = BookRevisionRepository(
        ImmutableObjectStore(storage, Directory('${local.path}/first')),
      );
      final file = File('${local.path}/book.txt');
      await file.writeAsString('中文正文\n可增量同步');
      final revision = await first.publish(
        bookUid: 'book',
        file: file,
        hash: await ImmutableObjectStore.hashFile(file),
        format: 'txt',
        fileName: 'book.txt',
        parents: [],
        metadata: {},
      );
      final second = BookRevisionRepository(
        ImmutableObjectStore(storage, Directory('${local.path}/second')),
      );
      final tips = await second.tips('book');
      expect(tips.single.id, revision.id);
      final restored = File('${local.path}/restored.txt');
      await second.materialize(tips.single, restored);
      expect(await restored.readAsBytes(), await file.readAsBytes());
      expect(dav.requests.any((r) => r.contains('.capabilities')), isFalse);
      expect(
        jsonEncode(client.recentRequests),
        isNot(contains('private-password')),
      );
      expect(jsonEncode(client.recentRequests), isNot(contains('中文')));
    },
  );

  test(
    'HEAD and OPTIONS restrictions do not disable immutable synchronization',
    () async {
      dav.rejectHead = true;
      dav.rejectOptions = true;
      expect((await client.testConnection()).success, isTrue);
      final store = ImmutableObjectStore(
        storage,
        Directory('${local.path}/cache'),
      );
      const text = 'content';
      final hash = ImmutableObjectStore.hashBytes(utf8.encode(text));
      final remote = SyncPath('objects/$hash.json');
      await store.putText(remote, text);
      expect(await store.readText(remote, hash), text);
      expect(
        dav.requests.any((r) => r.startsWith('PROPFIND') && r.contains(hash)),
        isTrue,
      );
    },
  );

  test(
    'retry repairs a partial object at its exact immutable address',
    () async {
      final store = ImmutableObjectStore(
        storage,
        Directory('${local.path}/cache'),
      );
      const text = 'complete data';
      final hash = ImmutableObjectStore.hashBytes(utf8.encode(text));
      final remote = SyncPath('objects/$hash.json');
      await storage.create(
        remote,
        Stream.value(utf8.encode('partial')),
        length: 7,
        contentType: 'application/json',
      );
      await store.putText(remote, text);
      final other = ImmutableObjectStore(
        storage,
        Directory('${local.path}/other'),
      );
      expect(await other.readText(remote, hash), text);
    },
  );

  test('older cloud space is rejected without modifying its files', () async {
    const old = '{"protocol":"open-reading-sync","schema_version":1}';
    await storage.create(
      SyncPath('format.json'),
      Stream.value(utf8.encode(old)),
      length: utf8.encode(old).length,
      contentType: 'application/json',
    );
    await expectLater(
      SyncSpace.ensure(storage),
      throwsA(isA<SyncStorageException>()),
    );
    expect((await storage.readText(SyncPath('format.json'))).text, old);
  });

  test(
    'directory discovery requests collection types from strict DAV servers',
    () async {
      await storage.create(
        SyncPath('changes/device/entry.json'),
        Stream.value(utf8.encode('{}')),
        length: 2,
        contentType: 'application/json',
      );
      final listing = await storage.list(SyncPath('changes'));
      expect(listing.prefixes.map((p) => p.value), ['changes/device']);
      expect(listing.objects, isEmpty);
    },
  );

  test(
    'malformed directory responses fail instead of reporting an empty cloud',
    () async {
      dav.malformedListing = true;
      await expectLater(
        storage.list(SyncPath('changes')),
        throwsA(isA<SyncStorageException>()),
      );
    },
  );
}
