import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/sync/storage/memory_sync_storage.dart';
import 'package:xxread/services/sync/storage/sync_storage.dart';

void main() {
  test('paths accept plain relative keys and reject traversal or URLs', () {
    expect(
      SyncPath('sync/metadata/head.json').value,
      'sync/metadata/head.json',
    );
    for (final invalid in ['', '/absolute', 'a//b', 'a/../b', 'https://x/y']) {
      expect(() => SyncPath(invalid), throwsArgumentError);
    }
  });

  test(
    'memory storage enforces create-only, CAS, and conditional reads',
    () async {
      final storage = MemorySyncStorage();
      final path = SyncPath('books/书/current.txt');
      final first = utf8.encode('第一版');
      final created = await storage.create(
        path,
        Stream.value(first),
        length: first.length,
        contentType: 'text/plain; charset=utf-8',
      );

      await expectLater(
        storage.create(
          path,
          Stream.value(first),
          length: first.length,
          contentType: 'text/plain; charset=utf-8',
        ),
        throwsA(_storageError(SyncStorageErrorCode.versionConflict)),
      );

      final second = utf8.encode('第二版');
      final replaced = await storage.compareAndSwap(
        path,
        Stream.value(second),
        length: second.length,
        contentType: 'text/plain; charset=utf-8',
        expectedVersion: created.info.version,
      );
      expect((await storage.readText(path)).text, '第二版');
      await expectLater(
        storage.readText(path, expectedVersion: created.info.version),
        throwsA(_storageError(SyncStorageErrorCode.versionConflict)),
      );
      expect(
        (await storage.readText(
          path,
          expectedVersion: replaced.info.version,
        )).info.version,
        replaced.info.version,
      );
    },
  );

  test('download returns the version bound to the streamed bytes', () async {
    final storage = MemorySyncStorage();
    final path = SyncPath('books/a/current.epub');
    final bytes = List<int>.generate(2048, (index) => index % 251);
    final created = await storage.create(
      path,
      Stream<List<int>>.fromIterable([
        bytes.sublist(0, 1024),
        bytes.sublist(1024),
      ]),
      length: bytes.length,
      contentType: 'application/epub+zip',
    );
    final directory = await Directory.systemTemp.createTemp('sync-store-');
    final file = File('${directory.path}/download.epub');
    final sink = file.openWrite();
    try {
      final result = await storage.download(
        path,
        sink,
        expectedVersion: created.info.version,
      );
      await sink.close();
      expect(await file.readAsBytes(), bytes);
      expect(result.info.version, created.info.version);
      expect(result.info.length, bytes.length);
    } finally {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test('list separates immediate objects from common prefixes', () async {
    final storage = MemorySyncStorage();
    for (final value in const [
      'sync/metadata/devices/a/head.json',
      'sync/metadata/devices/a/changes/000000000001.json',
      'books/a/current.txt',
    ]) {
      await storage.create(
        SyncPath(value),
        Stream.value(const [1]),
        length: 1,
        contentType: 'application/octet-stream',
      );
    }
    final devices = await storage.list(SyncPath('sync/metadata/devices'));
    expect(devices.prefixes.map((path) => path.value), [
      'sync/metadata/devices/a',
    ]);
    expect(
      (await storage.list(
        SyncPath('sync/metadata/devices/a'),
      )).objects.map((object) => object.path.value),
      ['sync/metadata/devices/a/head.json'],
    );
  });
}

Matcher _storageError(SyncStorageErrorCode code) =>
    isA<SyncStorageException>().having((error) => error.code, 'code', code);
