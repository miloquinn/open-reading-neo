import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/source_book_update_info.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/book_sources/services/source_book_update_service.dart';
import 'package:xxread/book_sources/services/source_chapter_state.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';

final _now = DateTime.utc(2026, 9, 16, 12);
final _oldDate = DateTime.utc(2026, 9, 15, 12);
Book _book({bool online = true, SourceBookUpdateInfo? info}) {
  final book = Book(
    id: 501,
    title: 'Novel',
    filePath: '/tmp/novel.txt',
    format: online ? 'source' : 'txt',
    storageType: online ? 'online' : 'local',
    sourceId: 'source',
    sourceBookId: 'novel',
    sourceJson: '{}',
    sourceBookJson: jsonEncode({
      'id': 'novel',
      'title': 'Novel',
      'sourceVariables': {'token': 'keep'},
    }),
  );
  return info == null
      ? book
      : book.copyWith(sourceBookJson: info.encodeInto(book));
}

List<BookSourceChapter> _catalog(int length) => List.generate(
  length,
  (i) => BookSourceChapter(id: '$i', title: 'Chapter $i', order: i),
);
SourceChapterState _state(List<String> ids) => SourceChapterState(
  schemaVersion: 1,
  bookUid: 'uid',
  sourceId: 'source',
  sourceBookId: 'novel',
  materializedContentHash: 'hash',
  baselineKnown: true,
  catalogChapterIds: ids,
  chapters: const [],
  conflicts: const [],
  revisionOrigin: SourceRevisionOrigin.initialDownload,
);

void main() {
  test(
    'first online check establishes a baseline without inventing update time',
    () {
      final info = SourceBookUpdateService.compareCatalog(
        book: _book(),
        previous: const SourceBookUpdateInfo(),
        catalog: _catalog(3),
        checkedAt: _now,
      );
      expect(info.status, SourceBookCheckStatus.current);
      expect(info.checkedAt, _now);
      expect(info.updatedAt, isNull);
      expect(info.latestChapter, 'Chapter 2');
    },
  );
  test(
    'online additions persist across repeated checks and preserve update time',
    () {
      final old = SourceBookUpdateInfo(
        latestChapterId: '1',
        chapterCount: 2,
        checkedAt: _oldDate,
      );
      final first = SourceBookUpdateService.compareCatalog(
        book: _book(),
        previous: old,
        catalog: _catalog(4),
        checkedAt: _now,
      );
      final second = SourceBookUpdateService.compareCatalog(
        book: _book(),
        previous: first,
        catalog: _catalog(4),
        checkedAt: _now.add(const Duration(hours: 1)),
      );
      expect(first.newChapterCount, 2);
      expect(first.updatedAt, _now);
      expect(second.status, SourceBookCheckStatus.available);
      expect(second.newChapterCount, 2);
      expect(second.updatedAt, _now);
    },
  );
  test(
    'local comparison uses downloaded boundary instead of previous check',
    () {
      final old = SourceBookUpdateInfo(
        latestChapterId: '3',
        chapterCount: 4,
        newChapterCount: 2,
        status: SourceBookCheckStatus.available,
        updatedAt: _oldDate,
      );
      final pending = SourceBookUpdateService.compareCatalog(
        book: _book(online: false),
        previous: old,
        localState: _state(['0', '1']),
        catalog: _catalog(4),
        checkedAt: _now,
      );
      final downloaded = SourceBookUpdateService.compareCatalog(
        book: _book(online: false),
        previous: pending,
        localState: _state(['0', '1', '2', '3']),
        catalog: _catalog(4),
        checkedAt: _now,
      );
      expect(pending.newChapterCount, 2);
      expect(pending.updatedAt, _oldDate);
      expect(downloaded.newChapterCount, 0);
      expect(downloaded.status, SourceBookCheckStatus.current);
    },
  );
  test(
    'unbound baseline and reordered local catalogs require confirmation',
    () {
      for (final state in [
        null,
        _state(['1', '0']),
        _state(['0', '1', '2', '3']),
      ]) {
        final info = SourceBookUpdateService.compareCatalog(
          book: _book(online: false),
          previous: const SourceBookUpdateInfo(),
          catalog: _catalog(3),
          checkedAt: _now,
          localState: state,
        );
        expect(info.status, SourceBookCheckStatus.needsMapping);
        expect(info.newChapterCount, 0);
      }
    },
  );
  test('source timestamps are used when provided', () {
    final catalog = [
      ..._catalog(2),
      BookSourceChapter(
        id: '2',
        title: 'New chapter',
        order: 2,
        updatedAt: _oldDate,
      ),
    ];
    final info = SourceBookUpdateService.compareCatalog(
      book: _book(),
      previous: const SourceBookUpdateInfo(latestChapterId: '1'),
      catalog: catalog,
      checkedAt: _now,
    );
    expect(info.updatedAt, _oldDate);
  });
  test(
    'failure is persisted without deleting previous chapter metadata',
    () async {
      final dao = _Dao(
        _book(
          info: SourceBookUpdateInfo(
            latestChapterId: '1',
            chapterCount: 2,
            updatedAt: _oldDate,
          ),
        ),
      );
      final shelf = _Shelf(() async => throw StateError('offline'));
      final service = SourceBookUpdateService(
        bookDao: dao,
        shelfServiceFactory: () => shelf,
        now: () => _now,
      );
      final result = await service.check(dao.book!);
      final info = SourceBookUpdateInfo.fromBook(result);
      expect(info.status, SourceBookCheckStatus.failed);
      expect(info.latestChapterId, '1');
      expect(info.updatedAt, _oldDate);
      expect(info.checkedAt, _now);
      expect(shelf.closed, isTrue);
      expect((jsonDecode(result.sourceBookJson!) as Map)['sourceVariables'], {
        'token': 'keep',
      });
    },
  );
  test(
    'automatic checks throttle, manual checks bypass and coalesce',
    () async {
      final dao = _Dao(_book(info: SourceBookUpdateInfo(checkedAt: _now)));
      final gate = Completer<List<BookSourceChapter>>();
      var requests = 0;
      final shelf = _Shelf(() {
        requests++;
        return gate.future;
      });
      final service = SourceBookUpdateService(
        bookDao: dao,
        shelfServiceFactory: () => shelf,
        now: () => _now,
      );
      await service.check(dao.book!, force: false);
      expect(requests, 0);
      final a = service.check(dao.book!);
      final b = service.check(dao.book!);
      gate.complete(_catalog(2));
      await Future.wait([a, b]);
      expect(requests, 1);
      expect(dao.writes, 1);
    },
  );
  test(
    'manual check upgrades an automatic check while storage is loading',
    () async {
      final gate = Completer<void>();
      final dao = _DelayedDao(
        _book(info: SourceBookUpdateInfo(checkedAt: _now)),
        gate.future,
      );
      var requests = 0;
      final service = SourceBookUpdateService(
        bookDao: dao,
        now: () => _now,
        shelfServiceFactory: () => _Shelf(() async {
          requests++;
          return _catalog(2);
        }),
      );
      final automatic = service.check(dao.book!, force: false);
      await dao.started.future;
      final manual = service.check(dao.book!);
      gate.complete();
      await Future.wait([automatic, manual]);
      expect(requests, 1);
      expect(dao.writes, 1);
    },
  );

  test('source changes during a request win over stale results', () async {
    final dao = _Dao(_book());
    final gate = Completer<List<BookSourceChapter>>();
    final started = Completer<void>();
    final service = SourceBookUpdateService(
      bookDao: dao,
      shelfServiceFactory: () => _Shelf(() {
        started.complete();
        return gate.future;
      }),
      now: () => _now,
    );
    final check = service.check(dao.book!);
    await started.future;
    dao.book = dao.book!.copyWith(
      sourceId: 'other',
      sourceBookJson: '{"id":"other"}',
    );
    gate.complete(_catalog(2));
    final result = await check;
    expect(result.sourceId, 'other');
    expect(result.sourceBookJson, '{"id":"other"}');
    expect(dao.writes, 0);
  });
  test('opening an old catalog never clears newer update marker', () async {
    final dao = _Dao(
      _book(
        info: const SourceBookUpdateInfo(
          status: SourceBookCheckStatus.available,
          latestChapterId: '3',
          newChapterCount: 2,
        ),
      ),
    );
    final service = SourceBookUpdateService(bookDao: dao);
    await service.markOnlineOpened(dao.book!, latestChapterId: '1');
    expect(SourceBookUpdateInfo.fromBook(dao.book!).newChapterCount, 2);
    await service.markOnlineOpened(dao.book!, latestChapterId: '3');
    expect(
      SourceBookUpdateInfo.fromBook(dao.book!).status,
      SourceBookCheckStatus.current,
    );
    expect(SourceBookUpdateInfo.fromBook(dao.book!).newChapterCount, 0);
  });
}

class _Dao extends BookDao {
  _Dao(this.book);
  Book? book;
  int writes = 0;
  @override
  Future<Book?> getBookById(int id) async => book;
  @override
  Future<bool> updateSourceBookMetadata(Book expected, String metadata) async {
    if (book?.sourceId != expected.sourceId ||
        book?.sourceBookId != expected.sourceBookId ||
        book?.sourceBookJson != expected.sourceBookJson) {
      return false;
    }
    book = book!.copyWith(sourceBookJson: metadata);
    writes++;
    return true;
  }
}

class _Shelf extends BookSourceShelfService {
  _Shelf(this.load);
  final Future<List<BookSourceChapter>> Function() load;
  bool closed = false;
  @override
  Future<List<BookSourceChapter>> sourceChaptersFor(Book book) => load();
  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _DelayedDao extends _Dao {
  _DelayedDao(super.book, this.gate);
  final Future<void> gate;
  final started = Completer<void>();
  @override
  Future<Book?> getBookById(int id) async {
    if (!started.isCompleted) started.complete();
    await gate;
    return book;
  }
}
