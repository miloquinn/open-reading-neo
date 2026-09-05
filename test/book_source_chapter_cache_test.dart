import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/caching/book_source_chapter_cache.dart';

void main() {
  setUp(BookSourceChapterCache.clearMemory);

  test('returns loaded chapter before its disk write completes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-chapter-nonblocking-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final writeStarted = Completer<void>();
    final allowWrite = Completer<void>();
    addTearDown(() {
      if (!allowWrite.isCompleted) allowWrite.complete();
    });
    final cache = BookSourceChapterCache(
      cacheDirectory: directory,
      beforeDiskWrite: () {
        writeStarted.complete();
        return allowWrite.future;
      },
    );

    final result = cache.getOrLoad(
      sourceId: 'source',
      bookId: 'book',
      chapterId: 'chapter',
      loader: () async => const BookSourceChapterContent(
        bookId: 'book',
        chapterId: 'chapter',
        title: '第一章',
        content: '正文',
        contentType: 'text/plain',
      ),
    );

    await writeStarted.future;
    expect((await result).content, '正文');
    expect(allowWrite.isCompleted, isFalse);
    allowWrite.complete();
    await _waitForJsonFile(directory);
  });

  test('returns loaded catalog before its disk write completes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-catalog-nonblocking-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final writeStarted = Completer<void>();
    final allowWrite = Completer<void>();
    addTearDown(() {
      if (!allowWrite.isCompleted) allowWrite.complete();
    });
    final cache = BookSourceChapterCache(
      cacheDirectory: directory,
      beforeDiskWrite: () {
        writeStarted.complete();
        return allowWrite.future;
      },
    );

    final result = cache.getChapterCatalogOrLoad(
      sourceId: 'source',
      bookId: 'book',
      loader: () async => const [
        BookSourceChapter(id: 'chapter', title: '第一章', order: 1),
      ],
    );

    await writeStarted.future;
    expect((await result).single.id, 'chapter');
    expect(allowWrite.isCompleted, isFalse);
    allowWrite.complete();
    await _waitForJsonFile(directory);
  });

  test('ignores background disk write failures without async errors', () async {
    final errors = <Object>[];

    await runZonedGuarded(() async {
      final cache = BookSourceChapterCache(
        beforeDiskWrite: () async =>
            throw const FileSystemException('cache unavailable'),
      );

      final chapter = await cache.getOrLoad(
        sourceId: 'failure-source',
        bookId: 'failure-book',
        chapterId: 'failure-chapter',
        loader: () async => const BookSourceChapterContent(
          bookId: 'failure-book',
          chapterId: 'failure-chapter',
          title: '失败缓存章节',
          content: '仍可阅读',
          contentType: 'text/plain',
        ),
      );
      final catalog = await cache.getChapterCatalogOrLoad(
        sourceId: 'failure-source',
        bookId: 'failure-book',
        loader: () async => const [
          BookSourceChapter(id: 'failure-chapter', title: '失败缓存章节', order: 1),
        ],
      );

      expect(chapter.content, '仍可阅读');
      expect(catalog.single.id, 'failure-chapter');
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => errors.add(error));

    expect(errors, isEmpty);
  });

  test(
    'serializes writes for the same chapter and keeps the newest value',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-chapter-write-order-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final firstWriteStarted = Completer<void>();
      final secondWriteStarted = Completer<void>();
      final allowFirstWrite = Completer<void>();
      final allowSecondWrite = Completer<void>();
      addTearDown(() {
        if (!allowFirstWrite.isCompleted) allowFirstWrite.complete();
        if (!allowSecondWrite.isCompleted) allowSecondWrite.complete();
      });
      var writeCount = 0;
      final cache = BookSourceChapterCache(
        cacheDirectory: directory,
        beforeDiskWrite: () {
          writeCount++;
          if (writeCount == 1) {
            firstWriteStarted.complete();
            return allowFirstWrite.future;
          }
          secondWriteStarted.complete();
          return allowSecondWrite.future;
        },
      );

      await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async => const BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter',
          title: '第一版',
          content: '旧正文',
          contentType: 'text/plain',
        ),
      );
      await firstWriteStarted.future;
      await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        refreshAfter: Duration.zero,
        staleWhileRevalidate: false,
        loader: () async => const BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter',
          title: '第二版',
          content: '新正文',
          contentType: 'text/plain',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(secondWriteStarted.isCompleted, isFalse);

      allowFirstWrite.complete();
      await secondWriteStarted.future;
      allowSecondWrite.complete();
      await _waitForJsonContent(directory, '新正文');
      BookSourceChapterCache.clearMemory();

      final restored = await BookSourceChapterCache(cacheDirectory: directory)
          .getOrLoad(
            sourceId: 'source',
            bookId: 'book',
            chapterId: 'chapter',
            loader: () => throw StateError('disk cache should contain newest'),
          );
      expect(restored.content, '新正文');
    },
  );

  test(
    'a cache clear prevents an older background write from reviving disk',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-chapter-clear-generation-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final writeStarted = Completer<void>();
      final allowWrite = Completer<void>();
      addTearDown(() {
        if (!allowWrite.isCompleted) allowWrite.complete();
      });
      final cache = BookSourceChapterCache(
        cacheDirectory: directory,
        beforeDiskWrite: () {
          writeStarted.complete();
          return allowWrite.future;
        },
      );

      await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async => const BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter',
          title: '待清理',
          content: '不应复活',
          contentType: 'text/plain',
        ),
      );
      await writeStarted.future;
      BookSourceChapterCache.clearMemory();
      allowWrite.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        await directory
            .list(recursive: true)
            .where((entity) => entity is File && entity.path.endsWith('.json'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test(
    'clear prevents an active loader from reviving memory or disk',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-chapter-clear-loader-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final loaderStarted = Completer<void>();
      final allowLoader = Completer<void>();
      final cache = BookSourceChapterCache(cacheDirectory: directory);

      final oldLoad = cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async {
          loaderStarted.complete();
          await allowLoader.future;
          return const BookSourceChapterContent(
            bookId: 'book',
            chapterId: 'chapter',
            title: '旧章节',
            content: '旧正文',
            contentType: 'text/plain',
          );
        },
      );
      await loaderStarted.future;
      BookSourceChapterCache.clearMemory();
      allowLoader.complete();
      expect((await oldLoad).content, '旧正文');

      var freshLoads = 0;
      final fresh = await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async {
          freshLoads++;
          return const BookSourceChapterContent(
            bookId: 'book',
            chapterId: 'chapter',
            title: '新章节',
            content: '新正文',
            contentType: 'text/plain',
          );
        },
      );

      expect(fresh.content, '新正文');
      expect(freshLoads, 1);
    },
  );

  test(
    'clear during a disk miss keeps the old call outside the new cache epoch',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-chapter-clear-read-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final readStarted = Completer<void>();
      final allowRead = Completer<void>();
      var loads = 0;
      final cache = BookSourceChapterCache(
        cacheDirectory: directory,
        beforeDiskRead: () {
          if (!readStarted.isCompleted) readStarted.complete();
          return allowRead.future;
        },
      );

      final oldLoad = cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async => _chapter('old-${++loads}'),
      );
      await readStarted.future;
      BookSourceChapterCache.clearMemory();
      allowRead.complete();
      expect((await oldLoad).content, 'old-1');

      final fresh = await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: () async => _chapter('fresh-${++loads}'),
      );
      expect(fresh.content, 'fresh-2');
    },
  );

  test('bounds chapter memory by bytes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-chapter-memory-bytes-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = BookSourceChapterCache(
      cacheDirectory: directory,
      maxMemoryBytes: 120,
    );

    for (var index = 0; index < 3; index++) {
      await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter-$index',
        loader: () async => BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter-$index',
          title: '章节',
          content: '正文' * 30,
          contentType: 'text/plain',
        ),
      );
    }

    expect(BookSourceChapterCache.memorySizeBytes, lessThanOrEqualTo(120));
  });

  test('catalogs share the chapter memory byte budget', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-catalog-memory-bytes-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final allowWrite = Completer<void>();
    addTearDown(() {
      if (!allowWrite.isCompleted) allowWrite.complete();
    });
    var loads = 0;
    final cache = BookSourceChapterCache(
      cacheDirectory: directory,
      maxMemoryBytes: 120,
      beforeDiskWrite: () => allowWrite.future,
    );
    Future<List<BookSourceChapter>> loader() async {
      loads++;
      return List.generate(
        20,
        (index) => BookSourceChapter(
          id: 'chapter-$index',
          title: '很长的章节标题 $index',
          order: index,
        ),
      );
    }

    await cache.getChapterCatalogOrLoad(
      sourceId: 'source',
      bookId: 'book',
      loader: loader,
    );
    await cache.getChapterCatalogOrLoad(
      sourceId: 'source',
      bookId: 'book',
      loader: loader,
    );

    expect(BookSourceChapterCache.memorySizeBytes, lessThanOrEqualTo(120));
    expect(loads, 2);
  });

  test('prunes chapter files to the disk byte budget', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-chapter-disk-bytes-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = BookSourceChapterCache(
      cacheDirectory: directory,
      maxDiskBytes: 450,
      diskMaintenanceInterval: Duration.zero,
    );

    for (var index = 0; index < 3; index++) {
      await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter-$index',
        loader: () async => BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter-$index',
          title: '章节 $index',
          content: '正文' * 30,
          contentType: 'text/plain',
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await cache.maintainDisk(force: true);

    expect(await cache.diskSizeBytes(), lessThanOrEqualTo(450));
    expect(
      await directory
          .list(recursive: true)
          .where((entry) => entry is File && entry.path.endsWith('.json'))
          .length,
      lessThan(3),
    );
  });

  test('memory pressure release preserves a pending disk write', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-chapter-memory-release-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final writeStarted = Completer<void>();
    final allowWrite = Completer<void>();
    addTearDown(() {
      if (!allowWrite.isCompleted) allowWrite.complete();
    });
    final cache = BookSourceChapterCache(
      cacheDirectory: directory,
      beforeDiskWrite: () {
        writeStarted.complete();
        return allowWrite.future;
      },
    );

    await cache.getOrLoad(
      sourceId: 'source',
      bookId: 'book',
      chapterId: 'chapter',
      loader: () async => const BookSourceChapterContent(
        bookId: 'book',
        chapterId: 'chapter',
        title: '可恢复',
        content: '磁盘正文',
        contentType: 'text/plain',
      ),
    );
    await writeStarted.future;
    BookSourceChapterCache.releaseMemory();
    allowWrite.complete();
    await _waitForJsonContent(directory, '磁盘正文');

    BookSourceChapterCache.clearMemory();
    final restored = await BookSourceChapterCache(cacheDirectory: directory)
        .getOrLoad(
          sourceId: 'source',
          bookId: 'book',
          chapterId: 'chapter',
          loader: () => throw StateError('pending disk write was cancelled'),
        );
    expect(restored.content, '磁盘正文');
  });

  test(
    'deduplicates concurrent chapter requests and keeps a memory cache',
    () async {
      const cache = BookSourceChapterCache();
      var loads = 0;

      Future<BookSourceChapterContent> loader() async {
        loads++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return const BookSourceChapterContent(
          bookId: 'book',
          chapterId: 'chapter',
          title: '第一章',
          content: '正文',
          contentType: 'text/plain',
        );
      }

      final results = await Future.wait([
        cache.getOrLoad(
          sourceId: 'source',
          bookId: 'book',
          chapterId: 'chapter',
          loader: loader,
        ),
        cache.getOrLoad(
          sourceId: 'source',
          bookId: 'book',
          chapterId: 'chapter',
          loader: loader,
        ),
      ]);
      final cached = await cache.getOrLoad(
        sourceId: 'source',
        bookId: 'book',
        chapterId: 'chapter',
        loader: loader,
      );

      expect(loads, 1);
      expect(results.first.content, '正文');
      expect(cached.content, '正文');
    },
  );

  test(
    'reuses chapter content from disk after the cache is recreated',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-chapter-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      var loads = 0;

      Future<BookSourceChapterContent> loader() async {
        loads++;
        return const BookSourceChapterContent(
          bookId: 'disk-book',
          chapterId: 'disk-chapter',
          title: '磁盘章节',
          content: '落盘正文',
          contentType: 'text/plain',
        );
      }

      await BookSourceChapterCache(cacheDirectory: directory).getOrLoad(
        sourceId: 'disk-source',
        sourceRevision: 'https://example.org/api/',
        bookId: 'disk-book',
        chapterId: 'disk-chapter',
        loader: loader,
      );
      await _waitForJsonFile(directory);
      BookSourceChapterCache.clearMemory();
      final cached = await BookSourceChapterCache(cacheDirectory: directory)
          .getOrLoad(
            sourceId: 'disk-source',
            sourceRevision: 'https://example.org/api/',
            bookId: 'disk-book',
            chapterId: 'disk-chapter',
            loader: loader,
          );

      expect(loads, 1);
      expect(cached.content, '落盘正文');
    },
  );

  test('persists remote image metadata with chapter content', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-chapter-images-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var loads = 0;

    Future<BookSourceChapterContent> loader() async {
      loads++;
      return BookSourceChapterContent(
        bookId: 'image-book',
        chapterId: 'image-chapter',
        title: '图片章节',
        content: '<img src="https://images.test/1.jpg">',
        contentType: 'text/html',
        images: [
          BookSourceRemoteImage(
            url: Uri.parse('https://images.test/1.jpg'),
            headers: const {'Referer': 'https://books.test/chapter/1'},
          ),
        ],
      );
    }

    await BookSourceChapterCache(cacheDirectory: directory).getOrLoad(
      sourceId: 'image-source',
      bookId: 'image-book',
      chapterId: 'image-chapter',
      loader: loader,
    );
    await _waitForJsonFile(directory);
    BookSourceChapterCache.clearMemory();

    final cached = await BookSourceChapterCache(cacheDirectory: directory)
        .getOrLoad(
          sourceId: 'image-source',
          bookId: 'image-book',
          chapterId: 'image-chapter',
          loader: loader,
        );

    expect(loads, 1);
    expect(cached.images.single.url.toString(), 'https://images.test/1.jpg');
    expect(
      cached.images.single.headers['Referer'],
      'https://books.test/chapter/1',
    );
  });

  test('repairs legacy image HTML cached without page metadata', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-chapter-legacy-images-',
    );
    addTearDown(() => directory.delete(recursive: true));
    var loads = 0;

    Future<BookSourceChapterContent> loader() async {
      loads++;
      return BookSourceChapterContent(
        bookId: 'image-book',
        chapterId: 'image-chapter',
        title: '图片章节',
        content: '<img src="https://images.test/1.jpg">',
        contentType: 'text/html',
        images: loads == 1
            ? const []
            : [
                BookSourceRemoteImage(
                  url: Uri.parse('https://images.test/1.jpg'),
                ),
              ],
      );
    }

    final cache = BookSourceChapterCache(cacheDirectory: directory);
    final legacy = await cache.getOrLoad(
      sourceId: 'image-source',
      bookId: 'image-book',
      chapterId: 'image-chapter',
      loader: loader,
    );
    expect(legacy.images, isEmpty);

    final repaired = await cache.getOrLoad(
      sourceId: 'image-source',
      bookId: 'image-book',
      chapterId: 'image-chapter',
      loader: loader,
    );

    expect(loads, 2);
    expect(repaired.images.single.url.toString(), 'https://images.test/1.jpg');
  });

  test(
    'returns stale chapter content while refreshing it in background',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-chapter-refresh-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = BookSourceChapterCache(cacheDirectory: directory);
      var loads = 0;

      Future<BookSourceChapterContent> loader() async {
        loads++;
        return BookSourceChapterContent(
          bookId: 'refresh-book',
          chapterId: 'refresh-chapter',
          title: '刷新章节',
          content: '正文 $loads',
          contentType: 'text/plain',
        );
      }

      final first = await cache.getOrLoad(
        sourceId: 'refresh-source',
        bookId: 'refresh-book',
        chapterId: 'refresh-chapter',
        refreshAfter: Duration.zero,
        loader: loader,
      );
      final second = await cache.getOrLoad(
        sourceId: 'refresh-source',
        bookId: 'refresh-book',
        chapterId: 'refresh-chapter',
        refreshAfter: Duration.zero,
        loader: loader,
      );

      expect(first.content, '正文 1');
      expect(second.content, '正文 1');
      for (var attempt = 0; attempt < 20 && loads < 2; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(loads, 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final refreshed = await cache.getOrLoad(
        sourceId: 'refresh-source',
        bookId: 'refresh-book',
        chapterId: 'refresh-chapter',
        loader: loader,
      );
      expect(refreshed.content, '正文 2');
    },
  );

  test(
    'returns a cached catalog immediately and refreshes it in background',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-catalog-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = BookSourceChapterCache(cacheDirectory: directory);
      var loads = 0;

      Future<List<BookSourceChapter>> loader() async {
        loads++;
        return [
          BookSourceChapter(
            id: 'chapter-$loads',
            title: '第 $loads 章',
            order: loads,
          ),
        ];
      }

      final first = await cache.getChapterCatalogOrLoad(
        sourceId: 'catalog-source',
        sourceRevision: 'https://example.org/api/',
        bookId: 'catalog-book',
        refreshAfter: Duration.zero,
        loader: loader,
      );
      final second = await cache.getChapterCatalogOrLoad(
        sourceId: 'catalog-source',
        sourceRevision: 'https://example.org/api/',
        bookId: 'catalog-book',
        refreshAfter: Duration.zero,
        loader: loader,
      );

      expect(first.single.id, 'chapter-1');
      expect(second.single.id, 'chapter-1');
      for (var attempt = 0; attempt < 20 && loads < 2; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(loads, 2);

      final refreshed = await cache.getChapterCatalogOrLoad(
        sourceId: 'catalog-source',
        sourceRevision: 'https://example.org/api/',
        bookId: 'catalog-book',
        loader: loader,
      );
      expect(refreshed.single.id, 'chapter-2');
    },
  );
}

Future<void> _waitForJsonFile(Directory directory) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .toList();
    if (files.isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the cache file to be persisted.');
}

Future<void> _waitForJsonContent(Directory directory, String content) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final files = await directory
        .list(recursive: true)
        .where((entity) => entity is File && entity.path.endsWith('.json'))
        .cast<File>()
        .toList();
    for (final file in files) {
      if ((await file.readAsString()).contains(content)) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the newest cache content to be persisted.');
}

BookSourceChapterContent _chapter(String content) => BookSourceChapterContent(
  bookId: 'book',
  chapterId: 'chapter',
  title: 'Chapter',
  content: content,
  contentType: 'text/plain',
);
