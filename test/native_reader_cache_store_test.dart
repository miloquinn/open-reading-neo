import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/books/native_reader_cache_store.dart';

void main() {
  late Directory directory;
  late NativeReaderCacheStore cache;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'native-cache-lifecycle-',
    );
    cache = NativeReaderCacheStore(maxDiskBytes: 10);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'clear releases memory but keeps active resources until final owner leaves',
    () async {
      final active = Directory('${directory.path}/epub/book');
      await active.create(recursive: true);
      final chapter = File('${active.path}/chapter.json');
      await chapter.writeAsString('chapter');
      final unused = File('${directory.path}/old.json');
      await unused.writeAsString('old');
      final reader = Object();
      final reopen = Object();
      cache.retain(reader, active.path);
      cache.retain(reopen, active.path);
      var cleared = 0;
      cache.registerMemoryClearer(() {
        cleared++;
        cache.release(reopen);
      });

      final before = cache.generation;
      await cache.clearDirectory(directory);
      expect(cache.generation, greaterThan(before));
      expect(cleared, 1);
      expect(await unused.exists(), isFalse);
      expect(await chapter.exists(), isTrue);
      await cache.release(reader);
      expect(await chapter.exists(), isFalse);
    },
  );

  test(
    'quota evicts an entire TXT index/data pair and protects active book',
    () async {
      final index = File('${directory.path}/old.json.index');
      final data = File('${directory.path}/old.json.data');
      final active = File('${directory.path}/active.json');
      await index.writeAsString('12345');
      await data.writeAsString('67890');
      await active.writeAsString('active');
      final old = DateTime.now().subtract(const Duration(days: 1));
      await index.setLastModified(old);
      await data.setLastModified(old);
      final owner = Object();
      cache.retain(owner, active.path);
      await cache.maintain(directory, force: true);
      expect(await index.exists(), isFalse);
      expect(await data.exists(), isFalse);
      expect(await active.exists(), isTrue);
      await cache.release(owner);
    },
  );

  test('clearing a retained TXT pair defers both files', () async {
    final index = File('${directory.path}/book.json.index');
    final data = File('${directory.path}/book.json.data');
    await index.writeAsString('index');
    await data.writeAsString('data');
    final owner = Object();
    cache.retain(owner, '${directory.path}/book.json');
    await cache.clearDirectory(directory);
    expect(await index.exists(), isTrue);
    expect(await data.exists(), isTrue);
    await cache.release(owner);
    expect(await index.exists(), isFalse);
    expect(await data.exists(), isFalse);
  });

  test(
    'clear tracks outputs not yet created and waits for in-flight writer',
    () async {
      final resource = '${directory.path}/late.json';
      final reader = Object();
      final writer = Object();
      cache.retain(reader, resource);
      await cache.acquire(writer, resource);
      await cache.clearDirectory(directory);
      await cache.release(reader);
      final data = File('$resource.data');
      await data.parent.create(recursive: true);
      await data.writeAsString('late write');
      expect(await data.exists(), isTrue);
      await cache.release(writer);
      expect(await data.exists(), isFalse);
    },
  );

  test(
    'EPUB quota removes a whole book instead of individual resources',
    () async {
      final root = Directory('${directory.path}/old-book');
      await Directory('${root.path}/images').create(recursive: true);
      await File('${root.path}/index.json').writeAsString('123456');
      await File('${root.path}/images/cover.png').writeAsString('789012');
      await cache.maintain(directory, force: true);
      expect(await root.exists(), isFalse);
    },
  );

  test(
    'closing a reader enforces quota after an in-flight operation finishes',
    () async {
      final book = Directory('${directory.path}/book');
      await book.create();
      final file = File('${book.path}/chapter.json');
      await file.writeAsString('larger than the ten byte quota');
      final reader = Object();
      final operation = Object();
      cache.retain(reader, book.path);
      cache.retain(operation, book.path);
      await cache.maintain(directory, force: true);
      expect(await file.exists(), isTrue);
      await cache.release(reader, enforceBudget: true);
      expect(await file.exists(), isTrue);
      await cache.release(operation);
      expect(await file.exists(), isFalse);
    },
  );
}
