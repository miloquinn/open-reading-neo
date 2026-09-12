import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/book_sources/caching/source_cover_cache.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/txt_edit_service.dart';

void main() {
  test(
    'adds a source book as an online shelf record without a local file',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-shelf-');
      addTearDown(() => directory.delete(recursive: true));
      final dao = _MemoryBookDao();
      final service = BookSourceShelfService(
        bookDao: dao,
        downloadDirectory: directory,
      );
      final added = await service.addOnline(source: _source, book: _sourceBook);
      final duplicate = await service.addOnline(
        source: _source,
        book: _sourceBook,
      );

      expect(added.isOnline, isTrue);
      expect(added.filePath, isEmpty);
      await dao.coverSaved.future.timeout(const Duration(seconds: 5));
      expect(dao.stored?.coverImagePath, isNotNull);
      expect(await File(dao.stored!.coverImagePath!).exists(), isTrue);
      expect(added.sourceId, _source.id);
      expect(service.sourceFrom(added).apiBaseUrl, _source.apiBaseUrl);
      expect(service.sourceBookFrom(added).title, _sourceBook.title);
      expect(duplicate.id, added.id);
      expect(dao.insertCount, 1);
    },
  );

  test('validates online shelf metadata before opening', () async {
    final service = BookSourceShelfService(bookDao: _MemoryBookDao());
    final added = await service.addOnline(source: _source, book: _sourceBook);

    final binding = service.bindingFrom(added);

    expect(binding.source.id, _source.id);
    expect(binding.book.id, _sourceBook.id);
    expect(
      () => service.bindingFrom(
        added.copyWith(sourceBookId: 'different-book-id'),
      ),
      throwsA(isA<OnlineShelfBookBindingException>()),
    );
    expect(
      () => service.bindingFrom(
        Book(
          title: 'Broken online book',
          filePath: '',
          format: 'source',
          storageType: 'online',
          sourceId: _source.id,
          sourceBookId: _sourceBook.id,
          sourceJson: '{broken',
          sourceBookJson: added.sourceBookJson,
        ),
      ),
      throwsA(isA<OnlineShelfBookBindingException>()),
    );
  });

  test(
    'large downloads use bounded workers and report every chapter',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final dao = _MemoryBookDao();
      final client = _DownloadClient();
      final service = BookSourceShelfService(
        bookDao: dao,
        client: client,
        downloadDirectory: directory,
      );
      final progress = <(int, int)>[];

      final downloaded = await service.downloadToLocal(
        source: _source,
        book: _sourceBook,
        onProgress: (completed, total) => progress.add((completed, total)),
      );

      expect(client.maxActive, lessThanOrEqualTo(3));
      expect(progress.first, (0, 7));
      expect(progress.last, (7, 7));
      expect(downloaded.isOnline, isFalse);
      expect(await File(downloaded.filePath).exists(), isTrue);
      expect(downloaded.coverImagePath, isNotNull);
      expect(await File(downloaded.coverImagePath!).exists(), isTrue);
      final text = await File(downloaded.filePath).readAsString();
      expect(text.indexOf('正文0'), lessThan(text.indexOf('正文6')));
    },
  );

  test('uses source identity in offline download paths', () async {
    final directory = await Directory.systemTemp.createTemp('source-identity-');
    addTearDown(() => directory.delete(recursive: true));
    final serviceA = BookSourceShelfService(
      bookDao: _MemoryBookDao(),
      client: _DownloadClient(),
      downloadDirectory: directory,
    );
    final serviceB = BookSourceShelfService(
      bookDao: _MemoryBookDao(),
      client: _DownloadClient(),
      downloadDirectory: directory,
    );
    final sourceB = RegisteredBookSource(
      id: 'different-source',
      name: 'Different source',
      description: '',
      manifestUrl: Uri.parse('https://other.example/source.json'),
      apiBaseUrl: Uri.parse('https://other.example/api/'),
      protocolVersion: '1.5',
      languages: const ['zh-CN'],
      capabilities: const {'search', 'detail', 'catalog', 'content'},
      enabled: true,
      addedAt: DateTime.utc(2026, 7, 31),
    );

    final first = await serviceA.downloadToLocal(
      source: _source,
      book: _sourceBook,
    );
    final second = await serviceB.downloadToLocal(
      source: sourceB,
      book: _sourceBook,
    );

    expect(
      path.basename(first.filePath),
      isNot(path.basename(second.filePath)),
    );
    expect(await File(first.filePath).exists(), isTrue);
    expect(await File(second.filePath).exists(), isTrue);
  });

  test(
    'converts encoded online progress before opening the downloaded TXT',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-progress-download-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final dao = _MemoryBookDao()
        ..stored = Book(
          id: 7,
          title: _sourceBook.title,
          author: _sourceBook.author,
          filePath: '',
          format: 'source',
          currentPage: 3456,
          totalPages: 7000,
          readingProgress: 0.4937,
          storageType: 'online',
          sourceId: _source.id,
          sourceBookId: _sourceBook.id,
          sourceJson: '{}',
          sourceBookJson: '{}',
        );
      final service = BookSourceShelfService(
        bookDao: dao,
        client: _DownloadClient(),
        downloadDirectory: directory,
      );

      final downloaded = await service.downloadToLocal(
        source: _source,
        book: _sourceBook,
      );

      expect(downloaded.isOnline, isFalse);
      expect(downloaded.currentPage, 3);
      expect(downloaded.totalPages, 7);
      expect(downloaded.readingProgress, closeTo(0.4937, 0.0001));
      expect(dao.stored?.currentPage, 3);
    },
  );

  test('repairs already-downloaded legacy chapter units once', () {
    final legacy = Book(
      id: 7,
      title: 'Legacy download',
      filePath: '/books/legacy.txt',
      format: 'txt',
      currentPage: 68000,
      totalPages: 485,
      readingProgress: 0.14020618556701031,
      storageType: 'local',
      sourceId: 'source-id',
      sourceBookId: 'source-book-id',
    );

    final repaired = BookSourceShelfService.repairLegacyDownloadedProgress(
      legacy,
    );
    final alreadyLocal = BookSourceShelfService.repairLegacyDownloadedProgress(
      repaired,
    );

    expect(repaired.currentPage, 68);
    expect(alreadyLocal.currentPage, 68);
  });

  test('streams completed batches before the whole book finishes', () async {
    final directory = await Directory.systemTemp.createTemp('source-stream-');
    addTearDown(() => directory.delete(recursive: true));
    final client = _StreamingDownloadClient();
    final service = BookSourceShelfService(
      bookDao: _MemoryBookDao(),
      client: client,
      downloadDirectory: directory,
    );

    final download = service.downloadToLocal(
      source: _source,
      book: _sourceBook,
    );
    await client.secondBatchStarted.future;

    final booksDirectory = Directory('${directory.path}/books');
    final partials = await booksDirectory
        .list()
        .where((entry) => entry.path.endsWith('.part'))
        .toList();
    expect(partials, hasLength(1));
    final partialText = await File(partials.single.path).readAsString();
    expect(partialText, contains('正文0'));
    expect(partialText, contains('正文2'));
    expect(partialText, isNot(contains('正文3')));
    expect(
      await booksDirectory
          .list()
          .where((entry) => entry.path.endsWith('.txt'))
          .isEmpty,
      isTrue,
    );

    client.releaseSecondBatch.complete();
    final downloaded = await download;
    expect(client.maxActive, lessThanOrEqualTo(3));
    expect(await File(downloaded.filePath).exists(), isTrue);
    expect(
      await booksDirectory
          .list()
          .where((entry) => entry.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
  });

  test(
    'removes the partial file when a streaming download is cancelled',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-cancel-');
      addTearDown(() => directory.delete(recursive: true));
      final client = _StreamingDownloadClient();
      final cancellation = BookDownloadCancellation();
      final service = BookSourceShelfService(
        bookDao: _MemoryBookDao(),
        client: client,
        downloadDirectory: directory,
      );

      final download = service.downloadToLocal(
        source: _source,
        book: _sourceBook,
        cancellation: cancellation,
      );
      await client.secondBatchStarted.future;
      cancellation.cancel();
      client.releaseSecondBatch.complete();

      await expectLater(
        download,
        throwsA(isA<BookDownloadCancelledException>()),
      );
      final booksDirectory = Directory('${directory.path}/books');
      expect(
        await booksDirectory
            .list()
            .where(
              (entry) =>
                  entry.path.endsWith('.part') || entry.path.endsWith('.txt'),
            )
            .isEmpty,
        isTrue,
      );
    },
  );

  test('persists a source-provided cover for offline shelf display', () async {
    final directory = await Directory.systemTemp.createTemp('source-cover-');
    addTearDown(() => directory.delete(recursive: true));
    final dao = _MemoryBookDao();
    final sourceCoverCache = SourceCoverCache(
      cacheDirectory: Directory('${directory.path}/cache'),
      loader: (_) async => Uint8List.fromList([1, 2, 3, 4]),
    );
    final service = BookSourceShelfService(
      bookDao: dao,
      downloadDirectory: directory,
      sourceCoverCache: sourceCoverCache,
    );

    final added = await service.addOnline(
      source: _source,
      book: _sourceBookWithCover,
    );

    await dao.coverSaved.future.timeout(const Duration(seconds: 5));
    expect(await File(dao.stored!.coverImagePath!).readAsBytes(), [1, 2, 3, 4]);
    expect(
      service.sourceBookFrom(added).coverUrl,
      _sourceBookWithCover.coverUrl,
    );
  });

  test('returns before a slow online cover finishes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-slow-cover-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final coverStarted = Completer<void>();
    final releaseCover = Completer<void>();
    final sourceCoverCache = SourceCoverCache(
      cacheDirectory: Directory('${directory.path}/cache'),
      loader: (_) async {
        coverStarted.complete();
        await releaseCover.future;
        return Uint8List.fromList([1, 2, 3]);
      },
    );
    final dao = _MemoryBookDao();
    final service = BookSourceShelfService(
      bookDao: dao,
      downloadDirectory: directory,
      sourceCoverCache: sourceCoverCache,
    );

    final adding = service.addOnline(
      source: _source,
      book: _sourceBookWithCover,
    );
    await coverStarted.future;
    await expectLater(adding.timeout(const Duration(seconds: 1)), completes);
    expect(dao.stored?.id, 7);
    await service.updateShelfProgress(
      shelfBookId: 7,
      chapterIndex: 2,
      chapterCount: 10,
      chapterProgress: .5,
    );
    service.close();
    releaseCover.complete();
    await dao.coverSaved.future.timeout(const Duration(seconds: 5));
    expect(dao.stored?.currentPage, 2500);
    expect(dao.stored?.coverImagePath, isNotNull);
  });

  test('keeps the shelf record when cover persistence fails', () async {
    final directory = await Directory.systemTemp.createTemp(
      'source-cover-fail-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final dao = _MemoryBookDao();
    final sourceCoverCache = SourceCoverCache(
      cacheDirectory: Directory('${directory.path}/cache'),
      loader: (_) async => throw StateError('cover unavailable'),
    );
    final service = BookSourceShelfService(
      bookDao: dao,
      downloadDirectory: directory,
      sourceCoverCache: sourceCoverCache,
    );

    final added = await service.addOnline(
      source: _source,
      book: _sourceBookWithCover,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(added.id, 7);
    expect(dao.stored?.id, 7);
    expect(dao.stored?.coverImagePath, isNull);
  });

  test(
    'downloaded serial appends only new chapters and keeps user edits',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-serial-');
      addTearDown(() => directory.delete(recursive: true));
      final dao = _MemoryBookDao();
      final client = _MutableSerialClient(chapterCount: 3);
      final service = BookSourceShelfService(
        bookDao: dao,
        client: client,
        downloadDirectory: directory,
        txtEditService: TxtEditService(
          historyRootProvider: () async =>
              Directory('${directory.path}/history'),
        ),
        sourceRevisionCommitter: _memoryRevisionCommitter(dao),
      );

      var downloaded = await service.downloadToLocal(
        source: _source,
        book: _sourceBook,
        bookUid: 'stable-book',
      );
      final store = const SourceChapterStateStore();
      final initial = await store.load(downloaded);
      expect(initial?.bookUid, 'stable-book');
      expect(initial?.chapters, hasLength(3));
      expect(initial?.materializedContentHash, isNotEmpty);

      final file = File(downloaded.filePath);
      await file.writeAsString(
        (await file.readAsString()).replaceFirst('正文0', '我的正文0'),
        flush: true,
      );
      client
        ..chapterCount = 5
        ..requested.clear();
      final result = await service.updateDownloadedBook(
        shelfBook: downloaded,
        mode: SourceUpdateMode.appendNewChapters,
      );
      downloaded = result.book;

      expect(result.status, SourceUpdateStatus.updated);
      expect(result.addedChapterCount, 2);
      expect(result.refreshedChapterCount, 0);
      expect(client.requested, ['chapter-3', 'chapter-4']);
      final text = await file.readAsString();
      expect(text, contains('我的正文0'));
      expect(text, contains('正文4'));
      expect(
        (await store.load(downloaded))?.chapters.first.userModified,
        isTrue,
      );
    },
  );

  for (final ambiguousHeader in [false, true]) {
    test(
      'source update preserves unmapped edits (duplicate header: $ambiguousHeader)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'source-unmapped-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final dao = _MemoryBookDao();
        final client = _MutableSerialClient(chapterCount: 2);
        final service = BookSourceShelfService(
          bookDao: dao,
          client: client,
          downloadDirectory: directory,
          sourceRevisionCommitter: _memoryRevisionCommitter(dao),
        );
        final downloaded = await service.downloadToLocal(
          source: _source,
          book: _sourceBook,
          bookUid: 'unmapped-book',
        );
        final file = File(downloaded.filePath);
        final original = await file.readAsString();
        final state = (await const SourceChapterStateStore().load(downloaded))!;
        final edited = ambiguousHeader
            ? original.replaceFirst(
                '正文0',
                '正文0\n\n\n${state.chapters[1].title}\n\n引用文字',
              )
            : '我的前言\n$original';
        await file.writeAsString(edited);
        client
          ..chapterCount = 3
          ..requested.clear();
        final result = await service.updateDownloadedBook(
          shelfBook: downloaded,
          mode: SourceUpdateMode.appendNewChapters,
        );
        expect(result.status, SourceUpdateStatus.baselineUnknown);
        expect(await file.readAsString(), edited);
        expect(client.requested, isEmpty);
      },
    );
  }

  test(
    'explicit refresh preserves local text and creates readable conflict assets',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'source-conflict-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final dao = _MemoryBookDao();
      final client = _MutableSerialClient(chapterCount: 2);
      final store = const SourceChapterStateStore();
      final service = BookSourceShelfService(
        bookDao: dao,
        client: client,
        sourceChapterStateStore: store,
        downloadDirectory: directory,
        txtEditService: TxtEditService(
          historyRootProvider: () async =>
              Directory('${directory.path}/history'),
        ),
        sourceRevisionCommitter: _memoryRevisionCommitter(dao),
      );
      final downloaded = await service.downloadToLocal(
        source: _source,
        book: _sourceBook,
        bookUid: 'stable-book',
      );
      final file = File(downloaded.filePath);
      await file.writeAsString(
        (await file.readAsString()).replaceFirst('正文0', '我的正文0'),
        flush: true,
      );
      client.contents['chapter-0'] = '书源修订0';
      client.requested.clear();

      final result = await service.updateDownloadedBook(
        shelfBook: downloaded,
        mode: SourceUpdateMode.refreshDownloadedChapters,
      );

      expect(result.status, SourceUpdateStatus.conflicts);
      expect(result.conflictCount, 1);
      expect(await file.readAsString(), contains('我的正文0'));
      expect(client.requested, ['chapter-0', 'chapter-1']);
      final state = await store.load(downloaded);
      final conflict = state!.conflicts.single;
      expect(
        await store.readAsset(downloaded, conflict.localAsset),
        contains('我的正文0'),
      );
      expect(
        await store.readAsset(downloaded, conflict.sourceAsset),
        contains('书源修订0'),
      );

      final resolved = await service.resolveSourceConflict(
        shelfBook: result.book,
        conflictId: conflict.id,
        resolution: SourceConflictResolution.useSource,
      );
      expect(resolved.revisionOrigin, SourceRevisionOrigin.conflictResolution);
      expect(await file.readAsString(), contains('书源修订0'));
      expect(await file.readAsString(), isNot(contains('我的正文0')));
    },
  );

  test(
    'legacy local download requires explicit baseline mapping and is never overwritten',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-legacy-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/legacy.txt');
      await file.writeAsString('用户旧正文  \n\n');
      final book = Book(
        id: 9,
        title: _sourceBook.title,
        author: _sourceBook.author,
        filePath: file.path,
        format: 'txt',
        storageType: 'local',
        sourceId: _source.id,
        sourceBookId: _sourceBook.id,
        sourceJson: jsonEncode(_source.toJson()),
        sourceBookJson: jsonEncode(_sourceBook.toJson()),
      );
      final dao = _MemoryBookDao()..stored = book;
      final client = _MutableSerialClient(chapterCount: 3);
      final service = BookSourceShelfService(
        bookDao: dao,
        client: client,
        downloadDirectory: directory,
        txtEditService: TxtEditService(
          historyRootProvider: () async =>
              Directory('${directory.path}/history'),
        ),
        sourceRevisionCommitter: _memoryRevisionCommitter(dao),
      );

      final blocked = await service.updateDownloadedBook(
        shelfBook: book,
        mode: SourceUpdateMode.appendNewChapters,
      );
      expect(blocked.status, SourceUpdateStatus.baselineUnknown);
      expect(await file.readAsString(), '用户旧正文  \n\n');

      final candidate = await service.downloadSourceCandidate(shelfBook: book);
      expect(await candidate.file.readAsString(), contains('正文2'));
      expect(await file.readAsString(), '用户旧正文  \n\n');

      await service.establishTrackingBaseline(
        shelfBook: book,
        sourceChapters: await client.getChaptersForDownload(
          _source,
          _sourceBook.id,
        ),
        lastDownloadedChapterId: 'chapter-1',
        mappingConfirmed: true,
        bookUid: 'legacy-stable',
      );
      client.requested.clear();
      final appended = await service.updateDownloadedBook(
        shelfBook: book,
        mode: SourceUpdateMode.appendNewChapters,
      );
      expect(appended.addedChapterCount, 1);
      expect(client.requested, ['chapter-2']);
      expect(await file.readAsString(), startsWith('用户旧正文  \n\n'));
      final firstAppend = await file.readAsString();
      client.chapterCount = 4;
      await service.updateDownloadedBook(
        shelfBook: appended.book,
        mode: SourceUpdateMode.appendNewChapters,
      );
      expect(await file.readAsString(), startsWith(firstAppend));
    },
  );
  test(
    'changing a downloaded source preserves readable content and progress',
    () async {
      final directory = await Directory.systemTemp.createTemp('source-rebind-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/book.txt');
      await file.writeAsString('用户正文');
      final original = Book(
        id: 7,
        title: '本地书',
        author: '作者',
        filePath: file.path,
        format: 'txt',
        currentPage: 12,
        totalPages: 99,
        readingProgress: .42,
        storageType: 'local',
        sourceId: _source.id,
        sourceBookId: _sourceBook.id,
        sourceJson: jsonEncode(_source.toJson()),
        sourceBookJson: jsonEncode(_sourceBook.toJson()),
      );
      final dao = _MemoryBookDao()..stored = original;
      final service = BookSourceShelfService(bookDao: dao);
      final replacement = RegisteredBookSource(
        id: 'replacement-source',
        name: '新书源',
        description: '',
        manifestUrl: Uri.parse('https://new.example/source.json'),
        apiBaseUrl: Uri.parse('https://new.example/api/'),
        protocolVersion: '1.0',
        languages: const ['zh-CN'],
        capabilities: const {'catalog', 'content'},
        enabled: true,
        addedAt: DateTime.utc(2026, 9, 12),
      );

      final rebound = await service.replaceOnlineSourceBinding(
        shelfBook: original,
        source: replacement,
        book: _sourceBook,
        chapterIndex: 5,
        chapterCount: 200,
        chapterProgress: .8,
      );

      expect(rebound.filePath, original.filePath);
      expect(rebound.currentPage, 12);
      expect(rebound.totalPages, 99);
      expect(rebound.readingProgress, .42);
      expect(rebound.sourceId, replacement.id);
      expect(await file.readAsString(), '用户正文');
    },
  );
}

SourceTxtRevisionCommitter _memoryRevisionCommitter(_MemoryBookDao dao) =>
    (book, commit) async {
      final updated = book.copyWith(
        contentHash: commit.contentHash,
        fileModifiedTime: commit.modifiedAt.millisecondsSinceEpoch,
        textEncoding: commit.textEncoding,
      );
      await dao.updateBook(updated);
      return updated;
    };

final _source = RegisteredBookSource(
  id: 'source-id',
  name: '测试书源',
  description: '',
  manifestUrl: Uri.parse('https://example.org/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.0',
  languages: const ['zh-CN'],
  capabilities: const {'search', 'catalog', 'content'},
  enabled: true,
  addedAt: DateTime.utc(2026, 7, 12),
);

const _sourceBook = BookSourceBook(
  id: 'book-id',
  title: '测试书籍',
  author: '作者',
  description: '简介',
  categories: [],
);

final _sourceBookWithCover = BookSourceBook(
  id: 'book-with-cover',
  title: '有封面的书',
  author: '作者',
  description: '简介',
  coverUrl: Uri.parse('https://example.org/cover.jpg'),
  categories: const [],
);

class _MemoryBookDao extends BookDao {
  final coverSaved = Completer<void>();
  Book? stored;
  int insertCount = 0;

  @override
  Future<Book?> getBookBySource({
    required String sourceId,
    required String sourceBookId,
  }) async => stored;

  @override
  Future<int> insertBook(Book book) async {
    insertCount++;
    stored = book.copyWith(id: 7);
    return 7;
  }

  @override
  Future<void> updateBook(Book book) async {
    stored = book;
  }

  @override
  Future<void> updateBookProgress(
    int bookId,
    int currentPage, {
    double? readingProgress,
    bool emitSyncEvent = true,
  }) async {
    stored = stored?.copyWith(
      currentPage: currentPage,
      readingProgress: readingProgress,
    );
  }

  @override
  Future<void> updateBookTotalPages(int bookId, int totalPages) async {
    stored = stored?.copyWith(totalPages: totalPages);
  }

  @override
  Future<void> updateBookCoverPath(int bookId, String? coverImagePath) async {
    stored = stored?.copyWith(coverImagePath: coverImagePath);
    if (!coverSaved.isCompleted) coverSaved.complete();
  }
}

class _DownloadClient extends BookSourceClient {
  int active = 0;
  int maxActive = 0;

  @override
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async => List.generate(
    7,
    (index) => BookSourceChapter(
      id: 'chapter-$index',
      title: '第${index + 1}章',
      order: index,
    ),
  );

  @override
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    active--;
    final index = int.parse(chapterId.split('-').last);
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: '',
      content: '正文$index',
      contentType: 'text/plain',
    );
  }
}

class _StreamingDownloadClient extends BookSourceClient {
  final secondBatchStarted = Completer<void>();
  final releaseSecondBatch = Completer<void>();
  int active = 0;
  int maxActive = 0;

  @override
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async => List.generate(
    6,
    (index) => BookSourceChapter(
      id: 'chapter-$index',
      title: '第${index + 1}章',
      order: index,
    ),
  );

  @override
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      final index = int.parse(chapterId.split('-').last);
      if (index >= 3) {
        if (!secondBatchStarted.isCompleted) secondBatchStarted.complete();
        await releaseSecondBatch.future;
      }
      return BookSourceChapterContent(
        bookId: bookId,
        chapterId: chapterId,
        title: '',
        content: '正文$index',
        contentType: 'text/plain',
      );
    } finally {
      active--;
    }
  }
}

class _MutableSerialClient extends BookSourceClient {
  _MutableSerialClient({required this.chapterCount});

  int chapterCount;
  final requested = <String>[];
  final contents = <String, String>{};

  @override
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async => List.generate(
    chapterCount,
    (index) => BookSourceChapter(
      id: 'chapter-$index',
      title: '第${index + 1}章',
      order: index,
      updatedAt: DateTime.utc(2026, 9, index + 1),
    ),
  );

  @override
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    requested.add(chapterId);
    return BookSourceChapterContent(
      bookId: bookId,
      chapterId: chapterId,
      title: sourceVariables['chapterTitle'] ?? '',
      content: contents[chapterId] ?? '正文${chapterId.split('-').last}',
      contentType: 'text/plain',
    );
  }
}
