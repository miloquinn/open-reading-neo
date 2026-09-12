// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

import '../../models/book.dart';
import '../../services/books/book_dao.dart';
import '../../services/books/cover_generator_service.dart';
import '../../services/books/txt_edit_service.dart';
import '../../services/books/txt_edit_reference_service.dart';
import '../../services/books/txt_content_change_bus.dart';
import '../../services/library/library_event_bus_service.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_download_cancellation.dart';
import 'book_source_client.dart';
import 'source_chapter_state.dart';
import '../caching/source_cover_cache.dart';

class OnlineShelfBookBinding {
  const OnlineShelfBookBinding({required this.source, required this.book});

  final RegisteredBookSource source;
  final BookSourceBook book;
}

class OnlineShelfBookBindingException implements Exception {
  const OnlineShelfBookBindingException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

enum SourceUpdateMode { appendNewChapters, refreshDownloadedChapters }

enum SourceUpdateStatus {
  noChanges,
  updated,
  baselineUnknown,
  needsConfirmation,
  conflicts,
}

class SourceUpdateResult {
  const SourceUpdateResult({
    required this.book,
    required this.status,
    required this.addedChapterCount,
    required this.refreshedChapterCount,
    required this.conflictCount,
    required this.materializedContentHash,
    required this.revisionOrigin,
  });

  final Book book;
  final SourceUpdateStatus status;
  final int addedChapterCount;
  final int refreshedChapterCount;
  final int conflictCount;
  final String materializedContentHash;
  final SourceRevisionOrigin revisionOrigin;
}

typedef SourceTxtRevisionCommitter =
    Future<Book> Function(Book book, TxtEditCommit commit);

class BookSourceShelfService {
  static const int _downloadBatchSize = 3;

  /// 在线书源书籍的进度编码单位：currentPage/totalPages 存储的是
  /// "章节序号 * unitsPerChapter + 章内进度"，而不是真实页码。
  /// UI 展示总量/当前值时需要除以该常量换算回章节数，避免把它当作页数显示。
  static const int unitsPerChapter = 1000;

  /// Repairs books downloaded by versions that changed `storage_type` to
  /// local but left `currentPage` in online chapter-unit encoding.
  static Book repairLegacyDownloadedProgress(Book book) {
    final normalizedProgress = book.readingProgress;
    if (book.isOnline ||
        book.format.toLowerCase() != 'txt' ||
        book.sourceId == null ||
        book.sourceBookId == null ||
        book.totalPages <= 0 ||
        book.currentPage <= 0 ||
        normalizedProgress == null ||
        (book.lastCanonicalLocator?.trim().isNotEmpty ?? false)) {
      return book;
    }
    final localEstimate = book.currentPage / book.totalPages;
    final encodedEstimate =
        book.currentPage / (book.totalPages * unitsPerChapter);
    final localDistance = (normalizedProgress - localEstimate).abs();
    final encodedDistance = (normalizedProgress - encodedEstimate).abs();
    if (encodedDistance + 0.000001 >= localDistance) return book;
    final chapterIndex = (book.currentPage ~/ unitsPerChapter).clamp(
      0,
      book.totalPages - 1,
    );
    return book.copyWith(currentPage: chapterIndex);
  }

  BookSourceShelfService({
    BookDao? bookDao,
    BookSourceClient? client,
    BookSourceClient Function()? clientFactory,
    SourceCoverCache? sourceCoverCache,
    SourceChapterStateStore? sourceChapterStateStore,
    TxtEditService? txtEditService,
    SourceTxtRevisionCommitter? sourceRevisionCommitter,
    Directory? downloadDirectory,
  }) : assert(client == null || clientFactory == null),
       _downloadDirectory = downloadDirectory,
       _bookDao = bookDao ?? BookDao(),
       _client = client ?? (clientFactory ?? BookSourceClient.new)(),
       _ownsClient = client == null,
       _sourceCoverCache = sourceCoverCache ?? SourceCoverCache.instance,
       _sourceChapterStateStore =
           sourceChapterStateStore ?? const SourceChapterStateStore(),
       _txtEditService = txtEditService ?? TxtEditService(),
       _revisionCommitter =
           sourceRevisionCommitter ??
           ((book, commit) => TxtEditReferenceService().commitRevision(
             book: book,
             commit: commit,
           ));

  final BookDao _bookDao;
  final BookSourceClient _client;
  final bool _ownsClient;
  final SourceCoverCache _sourceCoverCache;
  final SourceChapterStateStore _sourceChapterStateStore;
  final TxtEditService _txtEditService;
  final SourceTxtRevisionCommitter _revisionCommitter;
  final Directory? _downloadDirectory;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  Future<Book?> findShelfBook({
    required String sourceId,
    required String sourceBookId,
  }) =>
      _bookDao.getBookBySource(sourceId: sourceId, sourceBookId: sourceBookId);

  Future<Book> addOnline({
    required RegisteredBookSource source,
    required BookSourceBook book,
  }) async {
    final existing = await findShelfBook(
      sourceId: source.id,
      sourceBookId: book.id,
    );
    if (existing != null) return existing;
    final shelfBook = Book(
      title: book.title,
      author: book.author,
      filePath: '',
      format: 'source',
      storageType: 'online',
      sourceId: source.id,
      sourceBookId: book.id,
      sourceJson: jsonEncode(source.toJson()),
      sourceBookJson: jsonEncode(book.toJson()),
    );
    final id = await _bookDao.insertBook(shelfBook);
    LibraryEventBus().notifyLibraryChanged();
    final added = shelfBook.copyWith(id: id);
    // Cover retrieval must not block leaving the reader. Persist it as a
    // point update so a concurrent progress update cannot be overwritten.
    unawaited(_persistOnlineCover(source, book, id));
    return added;
  }

  Future<void> _persistOnlineCover(
    RegisteredBookSource source,
    BookSourceBook book,
    int shelfBookId,
  ) async {
    try {
      final coverPath = await _storedCoverPath(source, book);
      if (coverPath == null) return;
      await _bookDao.updateBookCoverPath(shelfBookId, coverPath);
      LibraryEventBus().notifyLibraryChanged();
    } catch (_) {
      // Cover persistence is best effort and must not affect shelf creation.
    }
  }

  Future<void> updateShelfProgress({
    required int shelfBookId,
    required int chapterIndex,
    required int chapterCount,
    required double chapterProgress,
  }) async {
    final currentUnits =
        chapterIndex * unitsPerChapter +
        (chapterProgress.clamp(0, 1) * unitsPerChapter).round();
    final totalUnits = chapterCount * unitsPerChapter;
    await _bookDao.updateBookProgress(
      shelfBookId,
      currentUnits,
      readingProgress: totalUnits <= 0 ? 0 : currentUnits / totalUnits,
    );
    await _bookDao.updateBookTotalPages(shelfBookId, totalUnits);
  }

  Future<Book> replaceOnlineSourceBinding({
    required Book shelfBook,
    required RegisteredBookSource source,
    required BookSourceBook book,
    required int chapterIndex,
    required int chapterCount,
    required double chapterProgress,
  }) async {
    if (shelfBook.id == null) {
      throw const BookSourceProtocolException(
        'Only a saved shelf book can change source.',
      );
    }
    final currentUnits =
        chapterIndex * unitsPerChapter +
        (chapterProgress.clamp(0, 1) * unitsPerChapter).round();
    final totalUnits = chapterCount * unitsPerChapter;
    final updated = shelfBook.copyWith(
      currentPage: shelfBook.isOnline ? currentUnits : shelfBook.currentPage,
      totalPages: shelfBook.isOnline ? totalUnits : shelfBook.totalPages,
      readingProgress: shelfBook.isOnline
          ? (totalUnits <= 0 ? 0 : currentUnits / totalUnits)
          : shelfBook.readingProgress,
      sourceId: source.id,
      sourceBookId: book.id,
      sourceJson: jsonEncode(source.toJson()),
      sourceBookJson: jsonEncode(book.toJson()),
    );
    final oldState = shelfBook.isOnline
        ? null
        : await _sourceChapterStateStore.load(shelfBook);
    if (oldState != null) {
      await _sourceChapterStateStore.save(
        updated,
        oldState.copyWith(
          sourceId: source.id,
          sourceBookId: book.id,
          baselineKnown: false,
          chapters: const [],
          catalogChapterIds: const [],
          revisionOrigin: SourceRevisionOrigin.sourceRebind,
        ),
      );
    }
    try {
      await _bookDao.updateBook(updated);
    } catch (_) {
      if (oldState != null) {
        await _sourceChapterStateStore.save(shelfBook, oldState);
      }
      rethrow;
    }
    if (!shelfBook.isOnline) {
      final hash = await SourceChapterStateStore.hashFile(
        File(updated.filePath),
      );
      _notifySourceSidecarChanged(updated, hash);
    }
    LibraryEventBus().notifyLibraryChanged();
    return updated;
  }

  Future<Book> downloadToLocal({
    required RegisteredBookSource source,
    required BookSourceBook book,
    String? bookUid,
    void Function(int completed, int total)? onProgress,
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final existing = await findShelfBook(
      sourceId: source.id,
      sourceBookId: book.id,
    );
    if (existing != null &&
        !existing.isOnline &&
        existing.filePath.trim().isNotEmpty &&
        await File(existing.filePath).exists()) {
      // Re-running an initial download must never replace a user's readable
      // file. Updates require the explicit append/refresh API below.
      return existing;
    }
    final chapters = [
      ...await _client.getChaptersForDownload(
        source,
        book.id,
        sourceVariables: book.sourceVariables,
        cancellation: cancellation,
      ),
    ]..sort(compareBookSourceChapters);
    cancellation?.throwIfCancelled();
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'This book source returned an empty chapter catalog.',
      );
    }

    final documents =
        _downloadDirectory ?? await getApplicationDocumentsDirectory();
    final directory = Directory(path.join(documents.path, 'books'));
    await directory.create(recursive: true);
    final file = File(
      path.join(
        directory.path,
        '${_safeFileName(book.title)}-${_downloadIdentity(source, book)}.txt',
      ),
    );
    final temporaryFile = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    IOSink? sink;
    final trackedChapters = <TrackedSourceChapter>[];
    var completed = 0;
    onProgress?.call(0, chapters.length);

    try {
      sink = temporaryFile.openWrite(mode: FileMode.write, encoding: utf8);
      for (
        var offset = 0;
        offset < chapters.length;
        offset += _downloadBatchSize
      ) {
        cancellation?.throwIfCancelled();
        final end = (offset + _downloadBatchSize).clamp(0, chapters.length);
        final batch = chapters.sublist(offset, end);
        final contents = await Future.wait(
          batch.asMap().entries.map((entry) async {
            final chapter = entry.value;
            final chapterIndex = offset + entry.key;
            final content = await _client.getChapterContentForDownload(
              source,
              bookId: book.id,
              chapterId: chapter.id,
              sourceVariables: {
                ...book.sourceVariables,
                'chapterIndex': '$chapterIndex',
                'chapterTitle': chapter.title,
                'bookName': book.title,
                'bookAuthor': book.author,
                'bookType': '${book.type}',
              },
              cancellation: cancellation,
            );
            cancellation?.throwIfCancelled();
            completed++;
            onProgress?.call(completed, chapters.length);
            return content;
          }),
        );
        cancellation?.throwIfCancelled();
        for (var index = 0; index < batch.length; index++) {
          final body = _plainText(contents[index]);
          sink
            ..writeln(batch[index].title)
            ..writeln()
            ..writeln(body)
            ..writeln()
            ..writeln();
          final bodyHash = SourceChapterStateStore.hashText(body);
          trackedChapters.add(
            TrackedSourceChapter(
              sourceChapterId: batch[index].id,
              ordinal: offset + index,
              title: batch[index].title,
              sourceMarker: batch[index].updatedAt?.toUtc().toIso8601String(),
              baselineHash: bodyHash,
              currentHash: bodyHash,
              body: body,
              userModified: false,
            ),
          );
        }
        await sink.flush();
      }
      cancellation?.throwIfCancelled();
      await sink.close();
      sink = null;
      cancellation?.throwIfCancelled();
      await _commitDownloadedFile(temporaryFile, file);
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {
        // Preserve the download error; cleanup is best effort.
      }
      try {
        if (await temporaryFile.exists()) await temporaryFile.delete();
      } catch (_) {
        // Preserve the download error; cleanup is best effort.
      }
      rethrow;
    }

    if (cancellation?.isCancelled ?? false) {
      throw const BookDownloadCancelledException();
    }

    final generatedCoverPath =
        existing?.coverImagePath ?? await _storedCoverPath(source, book);
    cancellation?.throwIfCancelled();
    if (existing != null) {
      final localChapterIndex =
          (existing.isOnline
                  ? existing.currentPage ~/ unitsPerChapter
                  : existing.currentPage)
              .clamp(0, chapters.length - 1);
      final downloaded = existing.copyWith(
        title: book.title,
        author: book.author,
        filePath: file.path,
        format: 'txt',
        currentPage: localChapterIndex,
        totalPages: chapters.length,
        storageType: 'local',
        sourceJson: jsonEncode(source.toJson()),
        sourceBookJson: jsonEncode(book.toJson()),
        coverImagePath: generatedCoverPath,
      );
      await _bookDao.updateBook(downloaded);
      await _saveInitialSourceState(
        downloaded,
        bookUid: bookUid,
        source: source,
        sourceBook: book,
        chapters: trackedChapters,
      );
      LibraryEventBus().notifyLibraryChanged();
      return downloaded;
    }

    final downloaded = Book(
      title: book.title,
      author: book.author,
      filePath: file.path,
      format: 'txt',
      totalPages: chapters.length,
      storageType: 'local',
      sourceId: source.id,
      sourceBookId: book.id,
      sourceJson: jsonEncode(source.toJson()),
      sourceBookJson: jsonEncode(book.toJson()),
      coverImagePath: generatedCoverPath,
    );
    final id = await _bookDao.insertBook(downloaded);
    final inserted = downloaded.copyWith(id: id);
    await _saveInitialSourceState(
      inserted,
      bookUid: bookUid,
      source: source,
      sourceBook: book,
      chapters: trackedChapters,
    );
    LibraryEventBus().notifyLibraryChanged();
    return inserted;
  }

  Future<void> _saveInitialSourceState(
    Book downloaded, {
    required String? bookUid,
    required RegisteredBookSource source,
    required BookSourceBook sourceBook,
    required List<TrackedSourceChapter> chapters,
  }) async {
    final withAssets = <TrackedSourceChapter>[];
    for (final chapter in chapters) {
      final asset = await _sourceChapterStateStore.writeConflictAsset(
        book: downloaded,
        conflictId: 'baseline-${chapter.ordinal}-${chapter.sourceChapterId}',
        label: 'source',
        title: chapter.title,
        body: chapter.body,
      );
      withAssets.add(chapter.copyWith(baselineAsset: asset));
    }
    final hash = await SourceChapterStateStore.hashFile(
      File(downloaded.filePath),
    );
    await _sourceChapterStateStore.save(
      downloaded,
      SourceChapterState(
        schemaVersion: 1,
        bookUid: _resolvedBookUid(downloaded, bookUid),
        sourceId: source.id,
        sourceBookId: sourceBook.id,
        materializedContentHash: hash,
        baselineKnown: true,
        chapters: withAssets,
        catalogChapterIds: withAssets
            .map((chapter) => chapter.sourceChapterId)
            .toList(growable: false),
        conflicts: const [],
        revisionOrigin: SourceRevisionOrigin.initialDownload,
      ),
    );
    _notifySourceSidecarChanged(downloaded, hash);
  }

  /// Establishes an explicit catalog boundary for a legacy local download.
  /// The readable text is retained byte-for-byte. Existing chapters have no
  /// trusted source baseline, so a later refresh produces candidates instead
  /// of replacing them; chapters after [lastDownloadedChapterId] may be safely
  /// appended.
  Future<SourceChapterState> establishTrackingBaseline({
    required Book shelfBook,
    required List<BookSourceChapter> sourceChapters,
    required String lastDownloadedChapterId,
    required bool mappingConfirmed,
    String? bookUid,
  }) async {
    if (!mappingConfirmed) {
      throw const BookSourceProtocolException(
        'A legacy chapter mapping must be explicitly confirmed.',
      );
    }
    final binding = bindingFrom(shelfBook);
    final boundary = sourceChapters.indexWhere(
      (chapter) => chapter.id == lastDownloadedChapterId,
    );
    if (boundary < 0) {
      throw const BookSourceProtocolException(
        'The selected chapter is not present in the current catalog.',
      );
    }
    final hash = await SourceChapterStateStore.hashFile(
      File(shelfBook.filePath),
    );
    final state = SourceChapterState(
      schemaVersion: 1,
      bookUid: _resolvedBookUid(shelfBook, bookUid),
      sourceId: binding.source.id,
      sourceBookId: binding.book.id,
      materializedContentHash: hash,
      baselineKnown: false,
      catalogChapterIds: sourceChapters
          .take(boundary + 1)
          .map((chapter) => chapter.id)
          .toList(growable: false),
      chapters: const [],
      conflicts: const [],
      revisionOrigin: SourceRevisionOrigin.sourceRebind,
    );
    await _sourceChapterStateStore.save(shelfBook, state);
    LibraryEventBus().notifyLibraryChanged();
    _notifySourceSidecarChanged(shelfBook, hash);
    return state;
  }

  Future<SourceUpdateResult> updateDownloadedBook({
    required Book shelfBook,
    required SourceUpdateMode mode,
    String? bookUid,
    void Function(int completed, int total)? onProgress,
    BookDownloadCancellation? cancellation,
  }) async {
    final binding = bindingFrom(shelfBook);
    final file = File(shelfBook.filePath);
    if (shelfBook.isOnline ||
        shelfBook.format.toLowerCase() != 'txt' ||
        !await file.exists()) {
      throw const BookSourceProtocolException(
        'Source updates require a downloaded TXT book.',
      );
    }
    var state = await _sourceChapterStateStore.load(shelfBook);
    final actualHash = await SourceChapterStateStore.hashFile(file);
    if (state == null) {
      return SourceUpdateResult(
        book: shelfBook,
        status: SourceUpdateStatus.baselineUnknown,
        addedChapterCount: 0,
        refreshedChapterCount: 0,
        conflictCount: 0,
        materializedContentHash: actualHash,
        revisionOrigin: SourceRevisionOrigin.initialDownload,
      );
    }
    if (state.sourceId != binding.source.id ||
        state.sourceBookId != binding.book.id) {
      return SourceUpdateResult(
        book: shelfBook,
        status: SourceUpdateStatus.baselineUnknown,
        addedChapterCount: 0,
        refreshedChapterCount: 0,
        conflictCount: state.conflicts
            .where((c) => c.resolution == null)
            .length,
        materializedContentHash: actualHash,
        revisionOrigin: SourceRevisionOrigin.sourceRebind,
      );
    }
    if (actualHash != state.materializedContentHash) {
      final reconciled = _reconcileEditedContent(
        await file.readAsString(),
        state.chapters,
      );
      if (reconciled == null) {
        return SourceUpdateResult(
          book: shelfBook,
          status: SourceUpdateStatus.baselineUnknown,
          addedChapterCount: 0,
          refreshedChapterCount: 0,
          conflictCount: state.conflicts
              .where((c) => c.resolution == null)
              .length,
          materializedContentHash: actualHash,
          revisionOrigin: SourceRevisionOrigin.userEdit,
        );
      }
      state = state.copyWith(
        chapters: reconciled,
        materializedContentHash: actualHash,
        revisionOrigin: SourceRevisionOrigin.userEdit,
      );
      await _sourceChapterStateStore.save(shelfBook, state);
    }

    cancellation?.throwIfCancelled();
    final catalog = [
      ...await _client.getChaptersForDownload(
        binding.source,
        binding.book.id,
        sourceVariables: binding.book.sourceVariables,
        cancellation: cancellation,
      ),
    ]..sort(compareBookSourceChapters);
    cancellation?.throwIfCancelled();
    if (mode == SourceUpdateMode.appendNewChapters) {
      return _appendNewChapters(
        shelfBook: shelfBook,
        binding: binding,
        state: state,
        catalog: catalog,
        onProgress: onProgress,
        cancellation: cancellation,
      );
    }
    if (!state.baselineKnown) {
      return SourceUpdateResult(
        book: shelfBook,
        status: SourceUpdateStatus.baselineUnknown,
        addedChapterCount: 0,
        refreshedChapterCount: 0,
        conflictCount: state.conflicts
            .where((c) => c.resolution == null)
            .length,
        materializedContentHash: state.materializedContentHash,
        revisionOrigin: state.revisionOrigin,
      );
    }
    return _refreshDownloadedChapters(
      shelfBook: shelfBook,
      binding: binding,
      state: state,
      catalog: catalog,
      onProgress: onProgress,
      cancellation: cancellation,
    );
  }

  Future<List<BookSourceChapter>> sourceChaptersFor(Book book) async {
    final binding = bindingFrom(book);
    return [
      ...await _client.getChaptersForDownload(
        binding.source,
        binding.book.id,
        sourceVariables: binding.book.sourceVariables,
      ),
    ]..sort(compareBookSourceChapters);
  }

  /// Downloads a readable source snapshot without changing the user's current
  /// TXT. This is the recovery path when an old or externally edited file can
  /// no longer be mapped safely to the persisted chapter baseline.
  Future<SourceStateAsset> downloadSourceCandidate({
    required Book shelfBook,
    void Function(int completed, int total)? onProgress,
    BookDownloadCancellation? cancellation,
  }) async {
    final binding = bindingFrom(shelfBook);
    final catalog = await sourceChaptersFor(shelfBook);
    final candidate = <TrackedSourceChapter>[];
    onProgress?.call(0, catalog.length);
    for (var index = 0; index < catalog.length; index++) {
      cancellation?.throwIfCancelled();
      final chapter = catalog[index];
      final value = await _client.getChapterContentForDownload(
        binding.source,
        bookId: binding.book.id,
        chapterId: chapter.id,
        sourceVariables: _chapterVariables(binding.book, chapter, index),
        cancellation: cancellation,
      );
      final body = _plainText(value);
      final hash = SourceChapterStateStore.hashText(body);
      candidate.add(
        TrackedSourceChapter(
          sourceChapterId: chapter.id,
          ordinal: index,
          title: chapter.title,
          sourceMarker: chapter.updatedAt?.toUtc().toIso8601String(),
          baselineHash: hash,
          currentHash: hash,
          body: body,
          userModified: false,
        ),
      );
      onProgress?.call(index + 1, catalog.length);
    }
    final asset = await _sourceChapterStateStore.writeBookCandidate(
      book: shelfBook,
      id: '${DateTime.now().microsecondsSinceEpoch}-${binding.source.id}',
      content: SourceChapterStateStore.materialize(candidate),
    );
    final hash = await SourceChapterStateStore.hashFile(
      File(shelfBook.filePath),
    );
    LibraryEventBus().notifyLibraryChanged();
    _notifySourceSidecarChanged(shelfBook, hash);
    return asset;
  }

  Future<SourceUpdateResult> _appendNewChapters({
    required Book shelfBook,
    required OnlineShelfBookBinding binding,
    required SourceChapterState state,
    required List<BookSourceChapter> catalog,
    required void Function(int completed, int total)? onProgress,
    required BookDownloadCancellation? cancellation,
  }) async {
    final trackedIds = state.catalogChapterIds;
    if (catalog.length < trackedIds.length ||
        catalog
                .take(trackedIds.length)
                .map((c) => c.id)
                .toList()
                .join('\u0000') !=
            trackedIds.join('\u0000')) {
      return _unchangedResult(
        shelfBook,
        state,
        SourceUpdateStatus.needsConfirmation,
      );
    }
    final additions = catalog.skip(trackedIds.length).toList(growable: false);
    if (additions.isEmpty) {
      return _unchangedResult(shelfBook, state, SourceUpdateStatus.noChanges);
    }
    final added = <TrackedSourceChapter>[];
    onProgress?.call(0, additions.length);
    for (var index = 0; index < additions.length; index++) {
      cancellation?.throwIfCancelled();
      final chapter = additions[index];
      final content = await _client.getChapterContentForDownload(
        binding.source,
        bookId: binding.book.id,
        chapterId: chapter.id,
        sourceVariables: _chapterVariables(
          binding.book,
          chapter,
          trackedIds.length + index,
        ),
        cancellation: cancellation,
      );
      final body = _plainText(content);
      final hash = SourceChapterStateStore.hashText(body);
      final baselineAsset = await _sourceChapterStateStore.writeConflictAsset(
        book: shelfBook,
        conflictId: 'baseline-${trackedIds.length + index}-${chapter.id}',
        label: 'source',
        title: chapter.title,
        body: body,
      );
      added.add(
        TrackedSourceChapter(
          sourceChapterId: chapter.id,
          ordinal: trackedIds.length + index,
          title: chapter.title,
          sourceMarker: chapter.updatedAt?.toUtc().toIso8601String(),
          baselineHash: hash,
          currentHash: hash,
          body: body,
          userModified: false,
          baselineAsset: baselineAsset,
        ),
      );
      onProgress?.call(index + 1, additions.length);
    }
    final chapters = [...state.chapters, ...added];
    return _commitSourceRevision(
      shelfBook: shelfBook,
      state: state.copyWith(
        baselineKnown: state.baselineKnown,
        chapters: chapters,
        catalogChapterIds: [
          ...trackedIds,
          ...additions.map((value) => value.id),
        ],
        revisionOrigin: SourceRevisionOrigin.sourceAppend,
      ),
      chapters: chapters,
      addedChapterCount: added.length,
      refreshedChapterCount: 0,
      invalidateAllReferences: false,
    );
  }

  Future<SourceUpdateResult> _refreshDownloadedChapters({
    required Book shelfBook,
    required OnlineShelfBookBinding binding,
    required SourceChapterState state,
    required List<BookSourceChapter> catalog,
    required void Function(int completed, int total)? onProgress,
    required BookDownloadCancellation? cancellation,
  }) async {
    final byId = {for (final chapter in catalog) chapter.id: chapter};
    final next = [...state.chapters];
    final conflicts = [...state.conflicts];
    var refreshed = 0;
    onProgress?.call(0, state.chapters.length);
    for (var index = 0; index < state.chapters.length; index++) {
      cancellation?.throwIfCancelled();
      final tracked = state.chapters[index];
      final chapter = byId[tracked.sourceChapterId];
      if (chapter == null) {
        return _unchangedResult(
          shelfBook,
          state,
          SourceUpdateStatus.needsConfirmation,
        );
      }
      final content = await _client.getChapterContentForDownload(
        binding.source,
        bookId: binding.book.id,
        chapterId: chapter.id,
        sourceVariables: _chapterVariables(binding.book, chapter, index),
        cancellation: cancellation,
      );
      final sourceBody = _plainText(content);
      final sourceHash = SourceChapterStateStore.hashText(sourceBody);
      if (sourceHash != tracked.baselineHash) {
        if (tracked.userModified ||
            tracked.currentHash != tracked.baselineHash) {
          final alreadyOpen = conflicts.any(
            (value) =>
                value.sourceChapterId == tracked.sourceChapterId &&
                value.resolution == null,
          );
          if (alreadyOpen) {
            onProgress?.call(index + 1, state.chapters.length);
            continue;
          }
          final conflictId =
              '${DateTime.now().microsecondsSinceEpoch}-${tracked.sourceChapterId}';
          final baselineBody = tracked.baselineAsset == null
              ? ''
              : _bodyFromReadableChapter(
                  await _sourceChapterStateStore.readAsset(
                    shelfBook,
                    tracked.baselineAsset!,
                  ),
                );
          final baselineAsset = await _sourceChapterStateStore
              .writeConflictAsset(
                book: shelfBook,
                conflictId: conflictId,
                label: 'baseline',
                title: tracked.title,
                body: baselineBody,
              );
          final localAsset = await _sourceChapterStateStore.writeConflictAsset(
            book: shelfBook,
            conflictId: conflictId,
            label: 'local',
            title: tracked.title,
            body: tracked.body,
          );
          final sourceAsset = await _sourceChapterStateStore.writeConflictAsset(
            book: shelfBook,
            conflictId: conflictId,
            label: 'source',
            title: chapter.title,
            body: sourceBody,
          );
          conflicts.add(
            SourceContentConflict(
              id: conflictId,
              sourceChapterId: tracked.sourceChapterId,
              baselineAsset: baselineAsset,
              localAsset: localAsset,
              sourceAsset: sourceAsset,
              createdAt: DateTime.now().toUtc(),
            ),
          );
        } else {
          final baselineAsset = await _sourceChapterStateStore
              .writeConflictAsset(
                book: shelfBook,
                conflictId: 'baseline-$index-${chapter.id}-$sourceHash',
                label: 'source',
                title: chapter.title,
                body: sourceBody,
              );
          next[index] = tracked.copyWith(
            title: chapter.title,
            sourceMarker: chapter.updatedAt?.toUtc().toIso8601String(),
            baselineHash: sourceHash,
            currentHash: sourceHash,
            body: sourceBody,
            userModified: false,
            baselineAsset: baselineAsset,
          );
          refreshed++;
        }
      }
      onProgress?.call(index + 1, state.chapters.length);
    }
    final unresolved = conflicts
        .where((conflict) => conflict.resolution == null)
        .length;
    if (refreshed == 0) {
      final nextState = state.copyWith(
        conflicts: conflicts,
        revisionOrigin: SourceRevisionOrigin.sourceRefresh,
      );
      await _sourceChapterStateStore.save(shelfBook, nextState);
      LibraryEventBus().notifyLibraryChanged();
      _notifySourceSidecarChanged(shelfBook, nextState.materializedContentHash);
      return _unchangedResult(
        shelfBook,
        nextState,
        unresolved > 0
            ? SourceUpdateStatus.conflicts
            : SourceUpdateStatus.noChanges,
      );
    }
    return _commitSourceRevision(
      shelfBook: shelfBook,
      state: state.copyWith(
        chapters: next,
        conflicts: conflicts,
        revisionOrigin: SourceRevisionOrigin.sourceRefresh,
      ),
      chapters: next,
      addedChapterCount: 0,
      refreshedChapterCount: refreshed,
      invalidateAllReferences: true,
    );
  }

  Future<SourceUpdateResult> resolveSourceConflict({
    required Book shelfBook,
    required String conflictId,
    required SourceConflictResolution resolution,
  }) async {
    final state = await _sourceChapterStateStore.load(shelfBook);
    if (state == null) throw StateError('Source chapter state is missing');
    final conflictIndex = state.conflicts.indexWhere(
      (value) => value.id == conflictId,
    );
    if (conflictIndex < 0) throw StateError('Source conflict is missing');
    final conflict = state.conflicts[conflictIndex];
    if (conflict.resolution != null) {
      return _unchangedResult(shelfBook, state, SourceUpdateStatus.noChanges);
    }
    final chapters = [...state.chapters];
    final chapterIndex = chapters.indexWhere(
      (chapter) => chapter.sourceChapterId == conflict.sourceChapterId,
    );
    if (chapterIndex < 0) throw StateError('Conflicted chapter is missing');
    if (resolution == SourceConflictResolution.useSource) {
      final raw = await _sourceChapterStateStore.readAsset(
        shelfBook,
        conflict.sourceAsset,
      );
      final body = _bodyFromReadableChapter(raw);
      final hash = SourceChapterStateStore.hashText(body);
      chapters[chapterIndex] = chapters[chapterIndex].copyWith(
        body: body,
        baselineHash: hash,
        currentHash: hash,
        userModified: false,
        baselineAsset: conflict.sourceAsset,
      );
    } else {
      final raw = await _sourceChapterStateStore.readAsset(
        shelfBook,
        conflict.sourceAsset,
      );
      final sourceBody = _bodyFromReadableChapter(raw);
      chapters[chapterIndex] = chapters[chapterIndex].copyWith(
        baselineHash: SourceChapterStateStore.hashText(sourceBody),
        baselineAsset: conflict.sourceAsset,
        userModified: true,
      );
    }
    final conflictValues = [...state.conflicts]
      ..[conflictIndex] = conflict.copyWith(resolution: resolution);
    return _commitSourceRevision(
      shelfBook: shelfBook,
      state: state.copyWith(
        chapters: chapters,
        conflicts: conflictValues,
        revisionOrigin: SourceRevisionOrigin.conflictResolution,
      ),
      chapters: chapters,
      addedChapterCount: 0,
      refreshedChapterCount: 0,
      invalidateAllReferences: resolution == SourceConflictResolution.useSource,
    );
  }

  Future<SourceUpdateResult> _commitSourceRevision({
    required Book shelfBook,
    required SourceChapterState state,
    required List<TrackedSourceChapter> chapters,
    required int addedChapterCount,
    required int refreshedChapterCount,
    required bool invalidateAllReferences,
  }) async {
    final content = await _materializeWithPreservedPrefix(
      shelfBook,
      state,
      chapters,
    );
    late Book updatedBook;
    late SourceChapterState committedState;
    final commit = await _txtEditService.replaceContent(
      book: shelfBook,
      content: content,
      expectedBaseContentHash: state.materializedContentHash,
      invalidateAllReferences: invalidateAllReferences,
      preserveReferenceOffsets:
          addedChapterCount > 0 && !invalidateAllReferences,
      onCommitted: (revision) async {
        committedState = state.copyWith(
          materializedContentHash: revision.contentHash,
          chapters: chapters,
        );
        await _sourceChapterStateStore.save(shelfBook, committedState);
        try {
          updatedBook = await _revisionCommitter(shelfBook, revision);
        } catch (_) {
          await _sourceChapterStateStore.save(shelfBook, state);
          rethrow;
        }
      },
    );
    LibraryEventBus().notifyLibraryChanged();
    TxtContentChangeBus.instance.notify(
      TxtContentChanged(
        book: updatedBook,
        contentHash: commit.contentHash,
        modifiedAt: commit.modifiedAt,
        origin: TxtContentChangeOrigin.localEdit,
      ),
    );
    final unresolved = committedState.conflicts
        .where((c) => c.resolution == null)
        .length;
    return SourceUpdateResult(
      book: updatedBook,
      status: unresolved > 0
          ? SourceUpdateStatus.conflicts
          : SourceUpdateStatus.updated,
      addedChapterCount: addedChapterCount,
      refreshedChapterCount: refreshedChapterCount,
      conflictCount: unresolved,
      materializedContentHash: commit.contentHash,
      revisionOrigin: committedState.revisionOrigin,
    );
  }

  SourceUpdateResult _unchangedResult(
    Book book,
    SourceChapterState state,
    SourceUpdateStatus status,
  ) => SourceUpdateResult(
    book: book,
    status: status,
    addedChapterCount: 0,
    refreshedChapterCount: 0,
    conflictCount: state.conflicts.where((c) => c.resolution == null).length,
    materializedContentHash: state.materializedContentHash,
    revisionOrigin: state.revisionOrigin,
  );

  List<TrackedSourceChapter>? _reconcileEditedContent(
    String content,
    List<TrackedSourceChapter> chapters,
  ) {
    if (chapters.isEmpty) return null;
    final bodies = <String>[];
    final firstHeader = '${chapters.first.title}\n\n';
    final firstStart = content.indexOf(firstHeader);
    // Untracked text must never disappear when a source revision is rebuilt.
    if (firstStart != 0) return null;
    var bodyStart = firstStart + firstHeader.length;
    for (var index = 0; index < chapters.length; index++) {
      final end = index + 1 == chapters.length
          ? content.length
          : content.indexOf(
              '\n\n\n${chapters[index + 1].title}\n\n',
              bodyStart,
            );
      if (end < 0) return null;
      if (index + 1 < chapters.length) {
        final separator = '\n\n\n${chapters[index + 1].title}\n\n';
        if (content.indexOf(separator, end + separator.length) >= 0) {
          return null;
        }
      }
      bodies.add(
        content.substring(bodyStart, end).replaceFirst(RegExp(r'\n\n\n$'), ''),
      );
      if (index + 1 < chapters.length) {
        bodyStart = end + '\n\n\n${chapters[index + 1].title}\n\n'.length;
      }
    }
    final reconciled = chapters
        .asMap()
        .entries
        .map((entry) {
          final body = bodies[entry.key].replaceFirst(RegExp(r'\n+$'), '');
          final hash = SourceChapterStateStore.hashText(body);
          return entry.value.copyWith(
            body: body,
            currentHash: hash,
            userModified: hash != entry.value.baselineHash,
          );
        })
        .toList(growable: false);
    // Accept a mapping only when it reconstructs every character exactly.
    return SourceChapterStateStore.materialize(reconciled) == content
        ? reconciled
        : null;
  }

  Future<String> _materializeWithPreservedPrefix(
    Book book,
    SourceChapterState previous,
    List<TrackedSourceChapter> chapters,
  ) async {
    final untrackedCount =
        previous.catalogChapterIds.length - previous.chapters.length;
    if (untrackedCount <= 0) {
      return SourceChapterStateStore.materialize(chapters);
    }
    final current = await File(book.filePath).readAsString();
    String prefix;
    if (previous.chapters.isEmpty) {
      prefix = current;
    } else {
      final trackedSuffix = SourceChapterStateStore.materialize(
        previous.chapters,
      );
      if (!current.endsWith(trackedSuffix)) {
        throw const BookSourceProtocolException(
          'Downloaded chapter boundaries no longer match the local text.',
        );
      }
      prefix = current.substring(0, current.length - trackedSuffix.length);
    }
    final separator = prefix.endsWith('\n\n\n') ? '' : '\n\n\n';
    return '$prefix$separator${SourceChapterStateStore.materialize(chapters)}';
  }

  Map<String, String> _chapterVariables(
    BookSourceBook book,
    BookSourceChapter chapter,
    int chapterIndex,
  ) => {
    ...book.sourceVariables,
    'chapterIndex': '$chapterIndex',
    'chapterTitle': chapter.title,
    'bookName': book.title,
    'bookAuthor': book.author,
    'bookType': '${book.type}',
  };

  String _bodyFromReadableChapter(String value) {
    final separator = value.indexOf('\n\n');
    return (separator < 0 ? value : value.substring(separator + 2)).trimRight();
  }

  String _resolvedBookUid(Book book, String? explicit) {
    if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();
    if (book.id != null) return 'local-book-${book.id}';
    return sha256.convert(utf8.encode(book.filePath)).toString();
  }

  void _notifySourceSidecarChanged(Book book, String contentHash) {
    final modified = File(book.filePath).lastModifiedSync();
    TxtContentChangeBus.instance.notify(
      TxtContentChanged(
        book: book,
        contentHash: contentHash,
        modifiedAt: modified,
        origin: TxtContentChangeOrigin.localEdit,
      ),
    );
  }

  OnlineShelfBookBinding bindingFrom(Book book) {
    if ((book.sourceId?.trim().isEmpty ?? true) ||
        (book.sourceBookId?.trim().isEmpty ?? true)) {
      throw const OnlineShelfBookBindingException(
        'This shelf record is not bound to a book source.',
      );
    }
    try {
      final sourceJson = _storedJsonObject(book.sourceJson, 'source metadata');
      final sourceBookJson = _storedJsonObject(
        book.sourceBookJson,
        'source book metadata',
      );
      final source = RegisteredBookSource.fromJson(sourceJson);
      final sourceBook = BookSourceBook.fromJson(
        sourceBookJson,
        baseUri: source.apiBaseUrl,
      );
      final sourceId = book.sourceId?.trim() ?? '';
      if (sourceId.isEmpty || source.id != sourceId) {
        throw const BookSourceProtocolException(
          'Stored source identity does not match the shelf record.',
        );
      }
      final sourceBookId = book.sourceBookId?.trim() ?? '';
      if (sourceBookId.isEmpty || sourceBook.id != sourceBookId) {
        throw const BookSourceProtocolException(
          'Stored source-book identity does not match the shelf record.',
        );
      }
      return OnlineShelfBookBinding(source: source, book: sourceBook);
    } on OnlineShelfBookBindingException {
      rethrow;
    } catch (error) {
      throw OnlineShelfBookBindingException(
        'Stored online book data is invalid.',
        cause: error,
      );
    }
  }

  RegisteredBookSource sourceFrom(Book book) => bindingFrom(book).source;

  BookSourceBook sourceBookFrom(Book book) => bindingFrom(book).book;

  Map<String, dynamic> _storedJsonObject(String? raw, String label) {
    if (raw == null || raw.trim().isEmpty) {
      throw BookSourceProtocolException(
        'Stored online book is missing $label.',
      );
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw BookSourceProtocolException(
        'Stored online book $label must be a JSON object.',
      );
    }
    return decoded.map((key, value) => MapEntry('$key', value));
  }

  String _safeFileName(String value) {
    final safe = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return safe.isEmpty ? 'book' : safe.substring(0, safe.length.clamp(0, 80));
  }

  String _downloadIdentity(RegisteredBookSource source, BookSourceBook book) =>
      sha256
          .convert(utf8.encode('${source.id}\u0000${book.id}'))
          .toString()
          .substring(0, 20);

  Future<void> _commitDownloadedFile(File temporary, File destination) async {
    final backup = File('${destination.path}.backup');
    final hadDestination = await destination.exists();
    if (await backup.exists()) await backup.delete();
    try {
      if (hadDestination) await destination.rename(backup.path);
      await temporary.rename(destination.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await destination.exists() && await backup.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    }
  }

  String _plainText(BookSourceChapterContent content) {
    if (content.contentType != 'text/html') return content.content.trim();
    final fragment = html_parser.parseFragment(content.content);
    final paragraphs = <String>[];

    void visit(dom.Node node) {
      if (node is dom.Element &&
          const {'p', 'div', 'li', 'blockquote'}.contains(node.localName)) {
        final text = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isNotEmpty) paragraphs.add(text);
        return;
      }
      for (final child in node.nodes) {
        visit(child);
      }
    }

    for (final node in fragment.nodes) {
      visit(node);
    }
    return paragraphs.isEmpty
        ? (fragment.text ?? '').trim()
        : paragraphs.join('\n');
  }

  Future<String?> _storedCoverPath(
    RegisteredBookSource source,
    BookSourceBook book,
  ) async {
    try {
      final documents =
          _downloadDirectory ?? await getApplicationDocumentsDirectory();
      if (book.coverUrl != null) {
        final bytes = await _sourceCoverCache.load(
          book.coverUrl!,
          headers: book.coverHeaders,
        );
        return CoverGenerator.saveCover(
          bytes,
          '${source.id}_${book.id}',
          documentsDirectory: documents,
          fileTag: 'source',
          fileExtension: 'img',
        );
      }
      final bytes = await CoverGenerator.generateTextCover(
        title: book.title,
        author: book.author,
      );
      return CoverGenerator.saveCover(
        bytes,
        '${source.id}_${book.id}.png',
        documentsDirectory: documents,
      );
    } catch (_) {
      // 持久化失败不应阻止用户加入书架；UI 会继续使用同一绘制器实时兜底。
      return null;
    }
  }
}
