import 'dart:convert';

import '../../models/book.dart';
import '../../services/books/book_dao.dart';
import '../../services/library/library_event_bus_service.dart';
import '../models/source_book_update_info.dart';
import '../protocol/book_source_protocol.dart';
import 'book_source_shelf_service.dart';
import 'source_chapter_state.dart';

/// Checks catalogs only. Downloading/merging local text remains an explicit
/// operation in the download queue, with its existing conflict protection.
class SourceBookUpdateService {
  SourceBookUpdateService({
    BookDao? bookDao,
    BookSourceShelfService Function()? shelfServiceFactory,
    SourceChapterStateStore? stateStore,
    DateTime Function()? now,
  }) : _dao = bookDao ?? BookDao(),
       _createShelf = shelfServiceFactory ?? BookSourceShelfService.new,
       _store = stateStore ?? const SourceChapterStateStore(),
       _now = now ?? DateTime.now;

  final BookDao _dao;
  final BookSourceShelfService Function() _createShelf;
  final SourceChapterStateStore _store;
  final DateTime Function() _now;
  static final Map<(int, String?, String?), _PendingBookCheck> _pending = {};
  static const automaticInterval = Duration(minutes: 30);

  Future<Book> check(Book book, {bool force = true}) {
    if (!book.hasSourceBinding || book.id == null) return Future.value(book);
    final key = (book.id!, book.sourceId, book.sourceBookId);
    final running = _pending[key];
    if (running != null) {
      running.force = running.force || force;
      return running.result;
    }
    final pending = _PendingBookCheck(force);
    _pending[key] = pending;
    pending.result = () async {
      try {
        return await _check(book, pending: pending);
      } finally {
        _pending.remove(key);
      }
    }();
    return pending.result;
  }

  Future<Book> _check(
    Book snapshot, {
    required _PendingBookCheck pending,
  }) async {
    final book = await _dao.getBookById(snapshot.id!);
    if (book == null || !book.hasSourceBinding) return snapshot;
    if (book.sourceId != snapshot.sourceId ||
        book.sourceBookId != snapshot.sourceBookId) {
      return book;
    }
    final old = SourceBookUpdateInfo.fromBook(book);
    final now = _now().toUtc();
    final localRevisionChanged =
        !book.isOnline &&
        book.fileModifiedTime != null &&
        (old.checkedAt == null ||
            book.fileModifiedTime! > old.checkedAt!.millisecondsSinceEpoch);
    if (!pending.force &&
        !localRevisionChanged &&
        old.checkedAt != null &&
        now.difference(old.checkedAt!) < automaticInterval) {
      return book;
    }
    final shelf = _createShelf();
    late SourceBookUpdateInfo info;
    try {
      final catalog = await shelf
          .sourceChaptersFor(book)
          .timeout(const Duration(seconds: 45));
      if (catalog.isEmpty ||
          catalog.map((c) => c.id).toSet().length != catalog.length) {
        throw const BookSourceProtocolException('Invalid update catalog');
      }
      final state = book.isOnline ? null : await _store.load(book);
      info = compareCatalog(
        book: book,
        previous: old,
        catalog: catalog,
        localState: state,
        checkedAt: now,
      );
    } catch (_) {
      info = SourceBookUpdateInfo(
        status: SourceBookCheckStatus.failed,
        checkedAt: now,
        updatedAt: old.updatedAt,
        chapterCount: old.chapterCount,
        latestChapterId: old.latestChapterId,
        latestChapter: old.latestChapter,
        newChapterCount: old.newChapterCount,
      );
    } finally {
      shelf.close();
    }
    final encoded = info.encodeInto(book);
    // A source change, download, or another metadata revision wins over this
    // stale network response. Progress and covers are never part of this write.
    if (await _dao.updateSourceBookMetadata(book, encoded)) {
      LibraryEventBus().notifyLibraryChanged();
    }
    return await _dao.getBookById(book.id!) ?? book;
  }

  static SourceBookUpdateInfo compareCatalog({
    required Book book,
    required SourceBookUpdateInfo previous,
    required List<BookSourceChapter> catalog,
    required DateTime checkedAt,
    SourceChapterState? localState,
  }) {
    var status = SourceBookCheckStatus.current;
    var additions = 0;
    if (!book.isOnline) {
      final tracked = localState?.catalogChapterIds ?? const <String>[];
      if (localState?.sourceId != book.sourceId ||
          localState?.sourceBookId != book.sourceBookId ||
          tracked.isEmpty ||
          tracked.length > catalog.length ||
          tracked.indexed.any((entry) => catalog[entry.$1].id != entry.$2)) {
        status = SourceBookCheckStatus.needsMapping;
      } else {
        additions = catalog.length - tracked.length;
      }
    } else if (previous.latestChapterId != null) {
      final boundary = catalog.indexWhere(
        (c) => c.id == previous.latestChapterId,
      );
      if (boundary >= 0) {
        additions = catalog.length - boundary - 1;
      }
      // Keep the unread update marker until the user opens the online book.
      if (previous.status == SourceBookCheckStatus.available ||
          previous.newChapterCount > 0) {
        status = SourceBookCheckStatus.available;
        additions += previous.newChapterCount;
      }
    } else if (previous.latestChapter?.trim().isNotEmpty == true &&
        previous.latestChapter != catalog.last.title) {
      final boundary = catalog.indexWhere(
        (c) => c.title == previous.latestChapter,
      );
      if (boundary >= 0) additions = catalog.length - boundary - 1;
    }
    if (additions > 0) status = SourceBookCheckStatus.available;
    final sourceDates = catalog.map((c) => c.updatedAt).nonNulls.toList()
      ..sort();
    final changed =
        additions > previous.newChapterCount &&
        (previous.latestChapterId == null ||
            previous.latestChapterId != catalog.last.id);
    return SourceBookUpdateInfo(
      status: status,
      checkedAt: checkedAt,
      updatedAt: sourceDates.isNotEmpty
          ? sourceDates.last
          : changed
          ? checkedAt
          : previous.updatedAt,
      chapterCount: catalog.length,
      latestChapterId: catalog.last.id,
      latestChapter: catalog.last.title,
      newChapterCount: additions,
    );
  }

  Future<void> markOnlineOpened(
    Book book, {
    required String latestChapterId,
  }) async {
    if (!book.isOnline || book.id == null) return;
    final current = await _dao.getBookById(book.id!);
    if (current == null ||
        current.sourceId != book.sourceId ||
        current.sourceBookId != book.sourceBookId) {
      return;
    }
    final json = jsonDecode(current.sourceBookJson!) as Map<String, dynamic>;
    final info = SourceBookUpdateInfo.fromBook(current);
    if (!info.hasNewChapters || info.latestChapterId != latestChapterId) {
      return;
    }
    json[SourceBookUpdateInfo.storageKey] = {
      ...info.toJson(),
      'status': SourceBookCheckStatus.current.name,
      'newChapterCount': 0,
    };
    if (await _dao.updateSourceBookMetadata(current, jsonEncode(json))) {
      LibraryEventBus().notifyLibraryChanged();
    }
  }
}

class _PendingBookCheck {
  _PendingBookCheck(this.force);
  bool force;
  late Future<Book> result;
}
