import 'dart:async';

import 'package:xxread/models/book.dart';

import '../source_engine/source_config.dart';
import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import 'book_download_cancellation.dart';
import 'book_source_client.dart';
import 'book_source_reading_progress.dart';
import 'book_source_shelf_service.dart';

class BookSourceChangePosition {
  const BookSourceChangePosition({
    required this.chapterIndex,
    required this.chapterProgress,
    required this.chapterTitle,
    required this.chapterCount,
  });

  final int chapterIndex;
  final double chapterProgress;
  final String chapterTitle;
  final int chapterCount;
}

class BookSourceChangeCandidate {
  const BookSourceChangeCandidate({
    required this.source,
    required this.book,
    required this.authorMatches,
  });

  final RegisteredBookSource source;
  final BookSourceBook book;
  final bool authorMatches;
}

class BookSourceChangeSearchEvent {
  const BookSourceChangeSearchEvent({
    required this.source,
    required this.completed,
    this.candidates = const [],
    this.error,
  });

  final RegisteredBookSource source;
  final int completed;
  final List<BookSourceChangeCandidate> candidates;
  final Object? error;
}

class ValidatedBookSourceChange {
  const ValidatedBookSourceChange({
    required this.candidate,
    required this.book,
    required this.chapters,
    required this.chapterIndex,
    required this.chapterProgress,
    required this.responseTime,
  });

  final BookSourceChangeCandidate candidate;
  final BookSourceBook book;
  final List<BookSourceChapter> chapters;
  final int chapterIndex;
  final double chapterProgress;
  final Duration responseTime;

  BookSourceChapter get chapter => chapters[chapterIndex];
}

class BookSourceChangeResult {
  const BookSourceChangeResult({
    required this.source,
    required this.book,
    required this.chapterIndex,
    required this.chapterProgress,
    required this.chapterCount,
    this.shelfBook,
  });

  final RegisteredBookSource source;
  final BookSourceBook book;
  final int chapterIndex;
  final double chapterProgress;
  final int chapterCount;
  final Book? shelfBook;
}

class BookSourceChangeConflict implements Exception {
  const BookSourceChangeConflict();

  @override
  String toString() => 'The selected source version is already on the shelf.';
}

class BookSourceChangeService {
  BookSourceChangeService({
    BookSourceClient? client,
    BookSourceClient Function()? clientFactory,
    BookSourceShelfService? shelfService,
    BookSourceShelfService Function(BookSourceClient client)?
    shelfServiceFactory,
    BookSourceReadingProgressStore? progressStore,
    this.maxConcurrentSearches = 12,
    this.perSourceSearchTimeout = const Duration(seconds: 6),
  }) : assert(client == null || clientFactory == null),
       assert(shelfService == null || shelfServiceFactory == null),
       progressStore = progressStore ?? const BookSourceReadingProgressStore() {
    final resolvedClient = client ?? (clientFactory ?? BookSourceClient.new)();
    this.client = resolvedClient;
    this.shelfService =
        shelfService ??
        (shelfServiceFactory ??
            (resolvedClient) =>
                BookSourceShelfService(client: resolvedClient))(resolvedClient);
    _ownsClient = client == null;
    _ownsShelfService = shelfService == null;
  }

  late final BookSourceClient client;
  late final BookSourceShelfService shelfService;
  final BookSourceReadingProgressStore progressStore;
  final int maxConcurrentSearches;
  final Duration perSourceSearchTimeout;
  late final bool _ownsClient;
  late final bool _ownsShelfService;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsShelfService) shelfService.close();
    if (_ownsClient) client.close();
  }

  Future<BookSourceChangePosition> loadPosition({
    required RegisteredBookSource source,
    required BookSourceBook book,
    Book? shelfBook,
  }) async {
    final saved = await progressStore.load(
      sourceId: source.id,
      bookId: book.id,
    );
    var chapters = const <BookSourceChapter>[];
    try {
      chapters = [
        ...await client.getChapters(
          source,
          book.id,
          sourceVariables: book.sourceVariables,
        ),
      ]..sort(compareBookSourceChapters);
    } catch (_) {
      // A broken current source must not prevent the user from finding a new one.
    }
    final shelfIndex = shelfBook == null
        ? 0
        : shelfBook.currentPage ~/ BookSourceShelfService.unitsPerChapter;
    final requestedIndex = saved?.chapterIndex ?? shelfIndex;
    final index = chapters.isEmpty
        ? requestedIndex.clamp(0, 1 << 30)
        : requestedIndex.clamp(0, chapters.length - 1);
    return BookSourceChangePosition(
      chapterIndex: index,
      chapterProgress:
          saved?.chapterProgress ?? _shelfChapterProgress(shelfBook),
      chapterTitle: chapters.isEmpty ? '' : chapters[index].title,
      chapterCount: chapters.isEmpty
          ? _shelfChapterCount(shelfBook)
          : chapters.length,
    );
  }

  Stream<BookSourceChangeSearchEvent> search({
    required Iterable<RegisteredBookSource> sources,
    required String title,
    required String author,
    required bool checkAuthor,
    String? currentSourceId,
    Set<String> excludedSourceIds = const {},
    int? sourceLimit,
    int? candidateLimit,
  }) {
    final targets = _selectChangeSearchTargets(
      sources: sources,
      currentSourceId: currentSourceId,
      excludedSourceIds: excludedSourceIds,
      sourceLimit: sourceLimit,
    );
    late final StreamController<BookSourceChangeSearchEvent> controller;
    if (targets.isEmpty) {
      controller = StreamController<BookSourceChangeSearchEvent>();
      scheduleMicrotask(controller.close);
      return controller.stream;
    }
    var cancelled = false;
    final activeCancellations = <BookDownloadCancellation>{};
    var nextIndex = 0;
    var completed = 0;
    var candidateCount = 0;
    final concurrency = maxConcurrentSearches.clamp(1, targets.length);

    Future<void> worker() async {
      while (!cancelled) {
        if (candidateLimit != null && candidateCount >= candidateLimit) return;
        final index = nextIndex++;
        if (index >= targets.length) return;
        final source = targets[index];
        List<BookSourceChangeCandidate> candidates = const [];
        Object? error;
        final requestCancellation = BookDownloadCancellation();
        activeCancellations.add(requestCancellation);
        final timeoutTimer = Timer(
          perSourceSearchTimeout,
          requestCancellation.cancel,
        );
        try {
          final page = await client.search(
            source,
            title,
            pageSize: 30,
            cancellation: requestCancellation,
          );
          candidates = page.items
              .where((book) => sameBookTitle(book.title, title))
              .map(
                (book) => BookSourceChangeCandidate(
                  source: source,
                  book: book,
                  authorMatches: sameBookAuthor(book.author, author),
                ),
              )
              .where(
                (candidate) =>
                    !checkAuthor ||
                    author.trim().isEmpty ||
                    candidate.authorMatches,
              )
              .toList(growable: false);
        } catch (caught) {
          error = caught;
        } finally {
          timeoutTimer.cancel();
          activeCancellations.remove(requestCancellation);
        }
        candidateCount += candidates.length;
        if (cancelled) return;
        final progress = ++completed;
        if (!controller.isClosed && controller.hasListener) {
          controller.add(
            BookSourceChangeSearchEvent(
              source: source,
              completed: progress,
              candidates: candidates,
              error: error,
            ),
          );
        }
      }
    }

    controller = StreamController<BookSourceChangeSearchEvent>(
      onListen: () {
        unawaited(() async {
          await Future.wait(List.generate(concurrency, (_) => worker()));
          if (!controller.isClosed) await controller.close();
        }());
      },
      onCancel: () {
        cancelled = true;
        for (final cancellation in activeCancellations.toList()) {
          cancellation.cancel();
        }
      },
    );
    return controller.stream;
  }

  Future<ValidatedBookSourceChange> validate({
    required BookSourceChangeCandidate candidate,
    required BookSourceChangePosition position,
  }) async {
    final stopwatch = Stopwatch()..start();
    final detail = await client.getBook(
      candidate.source,
      candidate.book.id,
      sourceVariables: candidate.book.sourceVariables,
    );
    final chapters = [
      ...await client.getChapters(
        candidate.source,
        detail.id,
        sourceVariables: detail.sourceVariables,
      ),
    ]..sort(compareBookSourceChapters);
    if (chapters.isEmpty) {
      throw const BookSourceProtocolException(
        'The selected source returned an empty chapter catalog.',
      );
    }
    final mappedIndex = matchBookSourceChapter(
      oldIndex: position.chapterIndex,
      oldTitle: position.chapterTitle,
      oldChapterCount: position.chapterCount,
      newChapters: chapters,
    );
    final chapter = chapters[mappedIndex];
    final content = await client.getChapterContent(
      candidate.source,
      bookId: detail.id,
      chapterId: chapter.id,
      sourceVariables: detail.sourceVariables,
    );
    if (content.content.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'The selected source returned empty chapter content.',
      );
    }
    stopwatch.stop();
    return ValidatedBookSourceChange(
      candidate: candidate,
      book: detail,
      chapters: chapters,
      chapterIndex: mappedIndex,
      chapterProgress: position.chapterProgress.clamp(0, 1),
      responseTime: stopwatch.elapsed,
    );
  }

  Future<BookSourceChangeResult> commit({
    required ValidatedBookSourceChange validated,
    Book? shelfBook,
  }) async {
    final targetSource = validated.candidate.source;
    final targetBook = validated.book;
    if (shelfBook?.id != null) {
      final existing = await shelfService.findShelfBook(
        sourceId: targetSource.id,
        sourceBookId: targetBook.id,
      );
      if (existing != null && existing.id != shelfBook!.id) {
        throw const BookSourceChangeConflict();
      }
    }
    final progress = BookSourceReadingProgress(
      chapterId: validated.chapter.id,
      chapterIndex: validated.chapterIndex,
      chapterProgress: validated.chapterProgress,
      updatedAt: DateTime.now().toUtc(),
    );
    await progressStore.save(
      sourceId: targetSource.id,
      bookId: targetBook.id,
      progress: progress,
    );
    Book? updatedShelfBook;
    try {
      if (shelfBook?.id != null) {
        updatedShelfBook = await shelfService.replaceOnlineSourceBinding(
          shelfBook: shelfBook!,
          source: targetSource,
          book: targetBook,
          chapterIndex: validated.chapterIndex,
          chapterCount: validated.chapters.length,
          chapterProgress: validated.chapterProgress,
        );
      }
    } catch (_) {
      await progressStore.delete(
        sourceId: targetSource.id,
        bookId: targetBook.id,
      );
      rethrow;
    }
    return BookSourceChangeResult(
      source: targetSource,
      book: targetBook,
      chapterIndex: validated.chapterIndex,
      chapterProgress: validated.chapterProgress,
      chapterCount: validated.chapters.length,
      shelfBook: updatedShelfBook,
    );
  }
}

List<RegisteredBookSource> _selectChangeSearchTargets({
  required Iterable<RegisteredBookSource> sources,
  required String? currentSourceId,
  required Set<String> excludedSourceIds,
  required int? sourceLimit,
}) {
  bool eligible(RegisteredBookSource source) =>
      source.enabled &&
      source.id != currentSourceId &&
      !excludedSourceIds.contains(source.id) &&
      source.capabilities.contains('search');

  if (sourceLimit == null) {
    final targets = sources.where(eligible).toList(growable: false);
    targets.sort(_compareChangeSourcePriority);
    return targets;
  }
  if (sourceLimit <= 0) return const [];

  // The first pass only needs a small priority window (currently 60). Keep a
  // bounded max-heap instead of sorting thousands of imported sources on the
  // UI isolate before the loading indicator can advance.
  final heap = <RegisteredBookSource>[];
  for (final source in sources) {
    if (!eligible(source)) continue;
    if (heap.length < sourceLimit) {
      heap.add(source);
      _siftChangeSourceUp(heap, heap.length - 1);
      continue;
    }
    if (_compareChangeSourcePriority(source, heap.first) >= 0) continue;
    heap[0] = source;
    _siftChangeSourceDown(heap, 0);
  }
  heap.sort(_compareChangeSourcePriority);
  return heap;
}

void _siftChangeSourceUp(List<RegisteredBookSource> heap, int index) {
  while (index > 0) {
    final parent = (index - 1) ~/ 2;
    if (_compareChangeSourcePriority(heap[parent], heap[index]) >= 0) return;
    final value = heap[parent];
    heap[parent] = heap[index];
    heap[index] = value;
    index = parent;
  }
}

void _siftChangeSourceDown(List<RegisteredBookSource> heap, int index) {
  while (true) {
    final left = index * 2 + 1;
    if (left >= heap.length) return;
    final right = left + 1;
    var larger = left;
    if (right < heap.length &&
        _compareChangeSourcePriority(heap[right], heap[left]) > 0) {
      larger = right;
    }
    if (_compareChangeSourcePriority(heap[index], heap[larger]) >= 0) return;
    final value = heap[index];
    heap[index] = heap[larger];
    heap[larger] = value;
    index = larger;
  }
}

int _compareChangeSourcePriority(
  RegisteredBookSource left,
  RegisteredBookSource right,
) {
  final tier = _changeSourcePriorityTier(
    left,
  ).compareTo(_changeSourcePriorityTier(right));
  if (tier != 0) return tier;
  final responseTime = _storedResponseTime(
    left,
  ).compareTo(_storedResponseTime(right));
  if (responseTime != 0) return responseTime;
  final customOrder = _storedCustomOrder(
    left,
  ).compareTo(_storedCustomOrder(right));
  if (customOrder != 0) return customOrder;
  return left.name.compareTo(right.name);
}

int _changeSourcePriorityTier(RegisteredBookSource source) {
  if (source.sourceProtocol == BookSourceProtocolKind.orsp) return 0;
  if (isReadingChainVerifiedSource(source)) return 1;
  if (_storedResponseTime(source) < 180000) return 2;
  return 3;
}

int _storedResponseTime(RegisteredBookSource source) {
  final value = source.sourceConfig?['respondTime'];
  final milliseconds = value is num
      ? value.toInt()
      : int.tryParse('$value') ?? 180000;
  return milliseconds <= 0 ? 180000 : milliseconds;
}

int _storedCustomOrder(RegisteredBookSource source) {
  final value = source.sourceConfig?['customOrder'];
  return value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}

bool sameBookTitle(String left, String right) =>
    normalizeBookSourceIdentity(left) == normalizeBookSourceIdentity(right);

bool sameBookAuthor(String left, String right) {
  final normalizedRight = normalizeBookSourceAuthor(right);
  if (normalizedRight.isEmpty) return true;
  final normalizedLeft = normalizeBookSourceAuthor(left);
  return normalizedLeft == normalizedRight ||
      normalizedLeft.contains(normalizedRight) ||
      normalizedRight.contains(normalizedLeft);
}

String normalizeBookSourceIdentity(String value) {
  final buffer = StringBuffer();
  for (var rune in value.toLowerCase().trim().runes) {
    if (rune >= 0xff01 && rune <= 0xff5e) rune -= 0xfee0;
    final asciiPunctuation =
        (rune >= 0x21 && rune <= 0x2f) ||
        (rune >= 0x3a && rune <= 0x40) ||
        (rune >= 0x5b && rune <= 0x60) ||
        (rune >= 0x7b && rune <= 0x7e);
    if (rune <= 0x20 ||
        asciiPunctuation ||
        _identityPunctuation.contains(rune)) {
      continue;
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

const _identityPunctuation = <int>{
  0x00b7,
  0x2010,
  0x2011,
  0x2012,
  0x2013,
  0x2014,
  0x2015,
  0x2018,
  0x2019,
  0x201c,
  0x201d,
  0x2022,
  0x2026,
  0x3000,
  0x3001,
  0x3002,
  0x3008,
  0x3009,
  0x300a,
  0x300b,
  0x300c,
  0x300d,
  0x300e,
  0x300f,
  0x3010,
  0x3011,
  0x3014,
  0x3015,
  0x3016,
  0x3017,
  0x3018,
  0x3019,
  0x301a,
  0x301b,
  0xff5f,
  0xff60,
  0xff61,
  0xff62,
  0xff63,
  0xff64,
  0xff65,
};

String normalizeBookSourceAuthor(String value) => normalizeBookSourceIdentity(
  value.replaceAll(
    RegExp(r'(作者|作\s*者|著|编著|編著|author)', caseSensitive: false),
    '',
  ),
);

int matchBookSourceChapter({
  required int oldIndex,
  required String oldTitle,
  required int oldChapterCount,
  required List<BookSourceChapter> newChapters,
}) {
  if (newChapters.isEmpty) return 0;
  if (oldIndex <= 0) return 0;
  final normalizedOld = normalizeChapterTitle(oldTitle);
  final oldNumber = chapterNumberFromTitle(oldTitle);
  final proportional = oldChapterCount <= 0
      ? oldIndex
      : (oldIndex * newChapters.length / oldChapterCount).round();
  final start = (oldIndex < proportional ? oldIndex : proportional) - 12;
  final end = (oldIndex > proportional ? oldIndex : proportional) + 12;
  final boundedStart = start.clamp(0, newChapters.length - 1);
  final boundedEnd = end.clamp(0, newChapters.length - 1);

  if (normalizedOld.isNotEmpty) {
    for (var index = boundedStart; index <= boundedEnd; index++) {
      if (normalizeChapterTitle(newChapters[index].title) == normalizedOld) {
        return index;
      }
    }
  }
  if (oldNumber != null) {
    var closestIndex = -1;
    var closestDistance = 1 << 30;
    for (var index = boundedStart; index <= boundedEnd; index++) {
      final number = chapterNumberFromTitle(newChapters[index].title);
      if (number == null) continue;
      final distance = (number - oldNumber).abs();
      if (distance < closestDistance) {
        closestIndex = index;
        closestDistance = distance;
      }
      if (distance == 0) return index;
    }
    if (closestIndex >= 0 && closestDistance <= 1) return closestIndex;
  }
  return proportional.clamp(0, newChapters.length - 1);
}

String normalizeChapterTitle(String value) =>
    normalizeBookSourceIdentity(value);

int? chapterNumberFromTitle(String value) {
  final match = RegExp(
    r'第?\s*([0-9零〇一二两兩三四五六七八九十百千万萬]+)\s*[章节節回话話集篇卷]',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  final raw = match.group(1)!;
  return int.tryParse(raw) ?? _chineseNumber(raw);
}

int? _chineseNumber(String value) {
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000};
  var total = 0;
  var section = 0;
  var number = 0;
  for (final character in value.split('')) {
    final digit = digits[character];
    if (digit != null) {
      number = digit;
      continue;
    }
    if (character == '万' || character == '萬') {
      total += (section + number).clamp(1, 9999) * 10000;
      section = 0;
      number = 0;
      continue;
    }
    final unit = units[character];
    if (unit == null) return null;
    section += (number == 0 ? 1 : number) * unit;
    number = 0;
  }
  return total + section + number;
}

double _shelfChapterProgress(Book? book) {
  if (book == null) return 0;
  final units = book.currentPage % BookSourceShelfService.unitsPerChapter;
  return (units / BookSourceShelfService.unitsPerChapter).clamp(0, 1);
}

int _shelfChapterCount(Book? book) {
  if (book == null || book.totalPages <= 0) return 0;
  return (book.totalPages / BookSourceShelfService.unitsPerChapter).round();
}
