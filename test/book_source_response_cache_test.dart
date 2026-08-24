import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/caching/book_source_response_cache.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-response-cache-');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test('deduplicates in-flight loads and serves a fresh memory hit', () async {
    final cache = BookSourceResponseCache(cacheDirectory: directory);
    addTearDown(cache.flushPendingWrites);
    final completer = Completer<Map<String, dynamic>>();
    var loads = 0;

    Future<Map<String, dynamic>> load() {
      loads++;
      return completer.future;
    }

    final first = cache.getOrLoadJson(
      key: 'search:source:q:1',
      ttl: const Duration(minutes: 2),
      loader: load,
    );
    final second = cache.getOrLoadJson(
      key: 'search:source:q:1',
      ttl: const Duration(minutes: 2),
      loader: load,
    );
    completer.complete({'value': 1});

    expect(await first, {'value': 1});
    expect(await second, {'value': 1});
    expect(
      await cache.getOrLoadJson(
        key: 'search:source:q:1',
        ttl: const Duration(minutes: 2),
        loader: load,
      ),
      {'value': 1},
    );
    expect(loads, 1);
  });

  test('expires entries and force refresh bypasses a fresh value', () async {
    var now = DateTime.utc(2026, 8, 3, 10);
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
    );
    addTearDown(cache.flushPendingWrites);
    var loads = 0;

    Future<Map<String, dynamic>> load() async => {'value': ++loads};

    expect(
      await cache.getOrLoadJson(
        key: 'detail:source:book',
        ttl: const Duration(minutes: 10),
        loader: load,
      ),
      {'value': 1},
    );
    expect(
      await cache.getOrLoadJson(
        key: 'detail:source:book',
        ttl: const Duration(minutes: 10),
        loader: load,
        forceRefresh: true,
      ),
      {'value': 2},
    );

    now = now.add(const Duration(minutes: 11));
    expect(
      await cache.getOrLoadJson(
        key: 'detail:source:book',
        ttl: const Duration(minutes: 10),
        loader: load,
      ),
      {'value': 3},
    );
  });

  test('keeps operation, query, and page keys separate', () async {
    final cache = BookSourceResponseCache(cacheDirectory: directory);
    addTearDown(cache.flushPendingWrites);
    var loads = 0;

    Future<Map<String, dynamic>> read(String key) => cache.getOrLoadJson(
      key: key,
      ttl: const Duration(minutes: 5),
      loader: () async => {'value': ++loads},
    );

    expect((await read('search:source:alpha:1'))['value'], 1);
    expect((await read('search:source:alpha:2'))['value'], 2);
    expect((await read('search:source:beta:1'))['value'], 3);
    expect((await read('browse:source:alpha:1'))['value'], 4);
    expect((await read('search:source:alpha:1'))['value'], 1);
  });

  test(
    'reads persistent JSON and ignores a corrupt cache file safely',
    () async {
      final first = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(first.flushPendingWrites);
      var loads = 0;
      expect(
        await first.getOrLoadJson(
          key: 'categories:source',
          ttl: const Duration(hours: 1),
          loader: () async => {'value': ++loads},
        ),
        {'value': 1},
      );
      await first.flushPendingWrites();

      final second = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(second.flushPendingWrites);
      expect(
        await second.getOrLoadJson(
          key: 'categories:source',
          ttl: const Duration(hours: 1),
          loader: () async => {'value': ++loads},
        ),
        {'value': 1},
      );
      expect(loads, 1);

      final files = await directory
          .list()
          .where((entry) => entry is File)
          .toList();
      expect(files, hasLength(1));
      await (files.single as File).writeAsString('{broken');

      final third = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(third.flushPendingWrites);
      expect(
        await third.getOrLoadJson(
          key: 'categories:source',
          ttl: const Duration(hours: 1),
          loader: () async => {'value': ++loads},
        ),
        {'value': 2},
      );
      expect(loads, 2);
    },
  );

  test('does not cache loader failures', () async {
    final cache = BookSourceResponseCache(cacheDirectory: directory);
    addTearDown(cache.flushPendingWrites);
    var loads = 0;

    Future<Map<String, dynamic>> load() async {
      loads++;
      if (loads == 1) throw StateError('network failed');
      return {'value': loads};
    }

    await expectLater(
      cache.getOrLoadJson(
        key: 'discovery:source',
        ttl: const Duration(hours: 1),
        loader: load,
      ),
      throwsStateError,
    );
    expect(
      await cache.getOrLoadJson(
        key: 'discovery:source',
        ttl: const Duration(hours: 1),
        loader: load,
      ),
      {'value': 2},
    );
  });

  test(
    'prefix invalidation prevents an older in-flight result from persisting',
    () async {
      final cache = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(cache.flushPendingWrites);
      final completer = Completer<Map<String, dynamic>>();
      var loads = 0;
      final first = cache.getOrLoadJson(
        key: 'orsp|source|search|alpha',
        ttl: const Duration(minutes: 2),
        loader: () {
          loads++;
          return completer.future;
        },
      );

      await cache.invalidatePrefix('orsp|source|');
      completer.complete({'value': 1});
      expect(await first, {'value': 1});
      expect(
        await cache.getOrLoadJson(
          key: 'orsp|source|search|alpha',
          ttl: const Duration(minutes: 2),
          loader: () async => {'value': ++loads},
        ),
        {'value': 2},
      );
    },
  );

  test(
    'invalidating one key does not discard an unrelated in-flight load',
    () async {
      final cache = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(cache.flushPendingWrites);
      final completer = Completer<Map<String, dynamic>>();
      var loads = 0;
      final first = cache.getOrLoadJson(
        key: 'orsp|source-a|browse',
        ttl: const Duration(minutes: 5),
        persistToDisk: false,
        loader: () {
          loads++;
          return completer.future;
        },
      );

      await cache.invalidate('orsp|source-b|browse');
      completer.complete({'value': 1});
      expect(await first, {'value': 1});
      expect(
        await cache.getOrLoadJson(
          key: 'orsp|source-a|browse',
          ttl: const Duration(minutes: 5),
          persistToDisk: false,
          loader: () async => {'value': ++loads},
        ),
        {'value': 1},
      );
      expect(loads, 1);
    },
  );

  test('disk reads wait for an in-progress invalidation', () async {
    const key = 'orsp|source|categories';
    final seed = BookSourceResponseCache(
      cacheDirectory: directory,
      maxMemoryEntries: 0,
    );
    addTearDown(seed.flushPendingWrites);
    await seed.getOrLoadJson(
      key: key,
      ttl: const Duration(hours: 1),
      loader: () async => {'value': 'stale'},
    );
    await seed.flushPendingWrites();

    final deletionStarted = Completer<void>();
    final releaseDeletion = Completer<void>();
    addTearDown(() {
      if (!releaseDeletion.isCompleted) releaseDeletion.complete();
    });
    var blockDeletion = true;
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      maxMemoryEntries: 0,
      beforeDiskMutation: () async {
        if (!blockDeletion) return;
        blockDeletion = false;
        deletionStarted.complete();
        await releaseDeletion.future;
      },
    );
    addTearDown(cache.flushPendingWrites);

    final invalidation = cache.invalidate(key);
    await deletionStarted.future;
    var loads = 0;
    var completed = false;
    final read = cache
        .getOrLoadJson(
          key: key,
          ttl: const Duration(hours: 1),
          loader: () async => {'value': ++loads},
        )
        .whenComplete(() => completed = true);
    await Future<void>.delayed(Duration.zero);

    expect(completed, isFalse);
    expect(loads, 0);
    releaseDeletion.complete();
    await invalidation;
    expect(await read, {'value': 1});
  });

  test('clear removes both memory and persistent entries', () async {
    final cache = BookSourceResponseCache(cacheDirectory: directory);
    addTearDown(cache.flushPendingWrites);
    await cache.getOrLoadJson(
      key: 'browse:source',
      ttl: const Duration(minutes: 5),
      loader: () async => {'value': 1},
    );
    await cache.flushPendingWrites();
    expect(cache.memoryEntryCount, 1);
    expect(await cache.diskSizeBytes(), greaterThan(0));

    await cache.clear();

    expect(cache.memoryEntryCount, 0);
    expect(await cache.diskSizeBytes(), 0);
  });

  test('clear cannot be undone by an already scheduled disk write', () async {
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      maxDiskBytes: 8 * 1024 * 1024,
    );
    addTearDown(cache.flushPendingWrites);
    await cache.getOrLoadJson(
      key: 'discovery:large',
      ttl: const Duration(hours: 1),
      loader: () async => {'payload': 'x' * (2 * 1024 * 1024)},
    );

    await cache.clear();
    await cache.flushPendingWrites();

    expect(cache.memoryEntryCount, 0);
    expect(await cache.diskSizeBytes(), 0);
  });

  test('invalidation wins over an already scheduled disk write', () async {
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      maxMemoryEntries: 0,
      maxDiskBytes: 8 * 1024 * 1024,
    );
    addTearDown(cache.flushPendingWrites);
    var loads = 0;
    await cache.getOrLoadJson(
      key: 'orsp|source|browse|latest',
      ttl: const Duration(hours: 1),
      loader: () async => {
        'value': ++loads,
        'payload': 'x' * (2 * 1024 * 1024),
      },
    );

    await cache.invalidatePrefix('orsp|source|');
    await cache.flushPendingWrites();

    final fresh = await cache.getOrLoadJson(
      key: 'orsp|source|browse|latest',
      ttl: const Duration(hours: 1),
      persistToDisk: false,
      loader: () async => {'value': ++loads},
    );
    expect(fresh['value'], 2);
  });

  test('enforces bounded memory and persistent entry quotas', () async {
    final memoryOnly = BookSourceResponseCache(
      cacheDirectory: directory,
      maxMemoryEntries: 1,
      maxDiskEntries: 0,
    );
    addTearDown(memoryOnly.flushPendingWrites);
    var loads = 0;
    Future<Map<String, dynamic>> readMemory(String key) =>
        memoryOnly.getOrLoadJson(
          key: key,
          ttl: const Duration(hours: 1),
          loader: () async => {'value': ++loads},
        );

    await readMemory('a');
    await readMemory('b');
    await readMemory('a');
    expect(loads, 3);

    final disk = BookSourceResponseCache(
      cacheDirectory: directory,
      maxMemoryEntries: 0,
      maxDiskEntries: 2,
    );
    addTearDown(disk.flushPendingWrites);
    for (final key in ['one', 'two', 'three']) {
      await disk.getOrLoadJson(
        key: key,
        ttl: const Duration(hours: 1),
        loader: () async => {'key': key},
      );
    }
    await disk.flushPendingWrites();
    final files = await directory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .toList();
    expect(files, hasLength(2));
  });

  test(
    'revalidates with validators and refreshes not-modified entries',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final cache = BookSourceResponseCache(
        cacheDirectory: directory,
        now: () => now,
      );
      addTearDown(cache.flushPendingWrites);
      BookSourceCacheValidators? received;

      expect(
        await cache.getOrRevalidateJson(
          key: 'validated',
          ttl: const Duration(minutes: 5),
          loader: (_) async => const BookSourceCacheLoadResult.modified(
            {'value': 1},
            etag: '"one"',
            lastModified: 'Wed, 01 Jan 2026 00:00:00 GMT',
          ),
        ),
        {'value': 1},
      );
      now = now.add(const Duration(minutes: 6));
      expect(
        await cache.getOrRevalidateJson(
          key: 'validated',
          ttl: const Duration(minutes: 5),
          loader: (validators) async {
            received = validators;
            return const BookSourceCacheLoadResult.notModified();
          },
        ),
        {'value': 1},
      );
      expect(received?.etag, '"one"');
      expect(received?.lastModified, 'Wed, 01 Jan 2026 00:00:00 GMT');

      now = now.add(const Duration(minutes: 4));
      var loads = 0;
      expect(
        await cache.getOrRevalidateJson(
          key: 'validated',
          ttl: const Duration(minutes: 5),
          loader: (_) async {
            loads++;
            return const BookSourceCacheLoadResult.modified({'value': 2});
          },
        ),
        {'value': 1},
      );
      expect(loads, 0);
    },
  );

  test('modified response replaces payload and validators on disk', () async {
    var now = DateTime.utc(2026, 1, 1);
    final first = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
    );
    addTearDown(first.flushPendingWrites);
    await first.getOrRevalidateJson(
      key: 'disk-validators',
      ttl: const Duration(minutes: 1),
      loader: (_) async =>
          const BookSourceCacheLoadResult.modified({'value': 1}, etag: 'old'),
    );
    await first.flushPendingWrites();
    now = now.add(const Duration(minutes: 2));

    final second = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
    );
    addTearDown(second.flushPendingWrites);
    expect(
      await second.getOrRevalidateJson(
        key: 'disk-validators',
        ttl: const Duration(minutes: 1),
        loader: (validators) async {
          expect(validators.etag, 'old');
          return const BookSourceCacheLoadResult.modified({
            'value': 2,
          }, etag: 'new');
        },
      ),
      {'value': 2},
    );
  });

  test('stale-if-error is bounded and configurable', () async {
    var now = DateTime.utc(2026, 1, 1);
    final cache = BookSourceResponseCache(
      cacheDirectory: directory,
      now: () => now,
      maxDiskEntries: 0,
    );
    await cache.getOrRevalidateJson(
      key: 'stale',
      ttl: const Duration(minutes: 1),
      loader: (_) async =>
          const BookSourceCacheLoadResult.modified({'value': 1}),
    );
    now = now.add(const Duration(minutes: 2));
    expect(
      await cache.getOrRevalidateJson(
        key: 'stale',
        ttl: const Duration(minutes: 1),
        staleIfError: const Duration(minutes: 5),
        loader: (_) async => throw StateError('offline'),
      ),
      {'value': 1},
    );
    now = now.add(const Duration(minutes: 1));
    await expectLater(
      cache.getOrRevalidateJson(
        key: 'stale',
        ttl: const Duration(minutes: 1),
        staleIfError: const Duration(minutes: 5),
        staleErrorTest: (error) => error is TimeoutException,
        loader: (_) async => throw StateError('404'),
      ),
      throwsStateError,
    );
    now = now.add(const Duration(minutes: 4));
    await expectLater(
      cache.getOrRevalidateJson(
        key: 'stale',
        ttl: const Duration(minutes: 1),
        staleIfError: const Duration(minutes: 5),
        loader: (_) async => throw StateError('offline'),
      ),
      throwsStateError,
    );
  });

  test('deduplicates revalidation loads by default', () async {
    final cache = BookSourceResponseCache(cacheDirectory: directory);
    final completer = Completer<BookSourceCacheLoadResult>();
    var loads = 0;
    Future<BookSourceCacheLoadResult> loader(
      BookSourceCacheValidators validators,
    ) {
      loads++;
      return completer.future;
    }

    final first = cache.getOrRevalidateJson(
      key: 'revalidation-flight',
      ttl: Duration.zero,
      persistToDisk: false,
      loader: loader,
    );
    final second = cache.getOrRevalidateJson(
      key: 'revalidation-flight',
      ttl: Duration.zero,
      persistToDisk: false,
      loader: loader,
    );
    expect(loads, 1);
    completer.complete(const BookSourceCacheLoadResult.modified({'value': 1}));
    expect(await first, {'value': 1});
    expect(await second, {'value': 1});
  });

  test('reads schema v1 payloads and supplies empty validators', () async {
    const key = 'legacy';
    final seed = BookSourceResponseCache(cacheDirectory: directory);
    await seed.getOrLoadJson(
      key: key,
      ttl: const Duration(hours: 1),
      loader: () async => {'legacy': true},
    );
    await seed.flushPendingWrites();
    final file =
        await directory.list().where((entity) => entity is File).single as File;
    final contents = await file.readAsString();
    await file.writeAsString(contents.replaceFirst('"schema":2', '"schema":1'));

    final cache = BookSourceResponseCache(cacheDirectory: directory);
    addTearDown(cache.flushPendingWrites);
    BookSourceCacheValidators? validators;
    expect(
      await cache.getOrRevalidateJson(
        key: key,
        ttl: Duration.zero,
        loader: (value) async {
          validators = value;
          return const BookSourceCacheLoadResult.notModified();
        },
      ),
      {'legacy': true},
    );
    expect(validators?.isEmpty, isTrue);
  });

  test('invalidation generation prevents revalidation write-back', () async {
    final cache = BookSourceResponseCache(cacheDirectory: directory);
    addTearDown(cache.flushPendingWrites);
    final response = Completer<BookSourceCacheLoadResult>();
    final pending = cache.getOrRevalidateJson(
      key: 'generation',
      ttl: Duration.zero,
      loader: (_) => response.future,
    );
    await cache.invalidate('generation');
    response.complete(
      const BookSourceCacheLoadResult.modified({'value': 'old'}),
    );
    expect(await pending, {'value': 'old'});
    expect(cache.memoryEntryCount, 0);
    await cache.flushPendingWrites();
    expect(await cache.diskSizeBytes(), 0);
  });

  test(
    'optional in-flight isolation runs cancellable-style loaders separately',
    () async {
      final cache = BookSourceResponseCache(cacheDirectory: directory);
      addTearDown(cache.flushPendingWrites);
      final completers = <Completer<Map<String, dynamic>>>[];
      var loads = 0;

      Future<Map<String, dynamic>> load() {
        loads++;
        final completer = Completer<Map<String, dynamic>>();
        completers.add(completer);
        return completer.future;
      }

      final first = cache.getOrLoadJson(
        key: 'search:source:isolated',
        ttl: const Duration(minutes: 2),
        deduplicateInFlight: false,
        persistToDisk: false,
        loader: load,
      );
      final second = cache.getOrLoadJson(
        key: 'search:source:isolated',
        ttl: const Duration(minutes: 2),
        deduplicateInFlight: false,
        persistToDisk: false,
        loader: load,
      );

      expect(loads, 2);
      completers[0].complete({'value': 1});
      completers[1].complete({'value': 2});
      expect(await first, {'value': 1});
      expect(await second, {'value': 2});
      expect(await cache.diskSizeBytes(), 0);
    },
  );
}
