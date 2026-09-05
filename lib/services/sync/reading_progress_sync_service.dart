import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/reader/canonical_locator.dart';
import '../../models/book.dart';
import '../../book_sources/services/book_source_reading_progress.dart';
import '../books/book_dao.dart';
import 'book_sync_identity.dart';
import 'reading_progress_event.dart';
import 'sync_change_store.dart';

enum ReadingProgressSyncEventKind { positionSaved, readerClosed }

class ReadingProgressSyncEvent {
  const ReadingProgressSyncEvent({
    required this.kind,
    required this.bookId,
    required this.bookUid,
    required this.createdAt,
  });

  final ReadingProgressSyncEventKind kind;
  final int bookId;
  final String bookUid;
  final DateTime createdAt;
}

class ReadingProgressSnapshot {
  const ReadingProgressSnapshot({
    required this.currentPage,
    required this.readingProgress,
    required this.canonicalLocator,
    this.eventId,
    this.savedAt,
    this.deviceId,
    this.deviceSequence,
    this.vector,
    this.locatorRevision,
    this.totalPages,
    this.sourceProgress,
  });

  final int currentPage;
  final double? readingProgress;
  final String? canonicalLocator;
  final String? eventId;
  final DateTime? savedAt;
  final String? deviceId;
  final int? deviceSequence;
  final Map<String, int>? vector;
  final String? locatorRevision;
  final int? totalPages;
  final Map<String, dynamic>? sourceProgress;

  factory ReadingProgressSnapshot.fromBook(Book book) =>
      ReadingProgressSnapshot(
        currentPage: book.currentPage,
        readingProgress: book.readingProgress,
        canonicalLocator: book.lastCanonicalLocator,
        totalPages: book.totalPages,
        locatorRevision: book.contentHash,
      );

  Map<String, Object?> toJson() => {
    'current_page': currentPage,
    'reading_progress': readingProgress,
    'canonical_locator': canonicalLocator,
    if (eventId != null) 'event_id': eventId,
    if (savedAt != null) 'saved_at': savedAt!.toUtc().toIso8601String(),
    if (deviceId != null) 'device_id': deviceId,
    if (deviceSequence != null) 'device_sequence': deviceSequence,
    if (vector != null) 'vector': vector,
    if (locatorRevision != null) 'locator_revision': locatorRevision,
    if (totalPages != null) 'total_pages': totalPages,
    if (sourceProgress != null) 'source_progress': sourceProgress,
  };

  Map<String, Object?> toEventJson() => {
    if (eventId != null) 'event_id': eventId,
    if (savedAt != null) 'saved_at': savedAt!.toUtc().toIso8601String(),
    if (deviceId != null) 'device_id': deviceId,
    if (deviceSequence != null) 'device_sequence': deviceSequence,
    if (vector != null) 'vector': vector,
    if (locatorRevision != null) 'locator_revision': locatorRevision,
  };

  factory ReadingProgressSnapshot.fromJson(Map<String, dynamic> json) =>
      ReadingProgressSnapshot(
        currentPage: (json['current_page'] as num?)?.toInt() ?? 0,
        readingProgress: (json['reading_progress'] as num?)?.toDouble(),
        canonicalLocator: json['canonical_locator'] as String?,
        eventId: json['event_id'] as String?,
        savedAt: DateTime.tryParse(json['saved_at'] as String? ?? ''),
        deviceId: json['device_id'] as String?,
        deviceSequence: (json['device_sequence'] as num?)?.toInt(),
        vector: readingProgressEventVector(json),
        locatorRevision: json['locator_revision'] as String?,
        totalPages: (json['total_pages'] as num?)?.toInt(),
        sourceProgress: json['source_progress'] is Map
            ? (json['source_progress'] as Map).cast<String, dynamic>()
            : null,
      );
}

class ReadingProgressRemoteCandidate {
  const ReadingProgressRemoteCandidate({
    required this.bookUid,
    required this.snapshot,
    required this.receivedAt,
  });

  final String bookUid;
  final ReadingProgressSnapshot snapshot;
  final DateTime receivedAt;
}

/// Owns durable reading-position events and continuation decisions.
/// Network scheduling remains owned by WebDavSyncController.
class ReadingProgressSyncService {
  ReadingProgressSyncService._();

  static final ReadingProgressSyncService instance =
      ReadingProgressSyncService._();

  static const String localEventStatePrefix = 'progress_event:';
  static const String headStatePrefix = 'progress_head:';
  static const String deviceSequenceStatePrefix = 'progress_device_sequence:';
  static const String candidateStatePrefix = 'progress_candidate:';
  static const String candidateDecisionStatePrefix =
      'progress_candidate_decision:';
  static const String candidateSnoozeStatePrefix = 'progress_candidate_snooze:';
  static const Duration candidateSnoozeDuration = Duration(hours: 1);

  final StreamController<ReadingProgressSyncEvent> _events =
      StreamController<ReadingProgressSyncEvent>.broadcast(sync: true);
  final Set<int> _openingBooks = <int>{};
  final Set<int> _activeBooks = <int>{};
  final Map<int, ReadingProgressSnapshot> _preSyncPositions =
      <int, ReadingProgressSnapshot>{};
  final Map<int, String?> _preSyncHeads = <int, String?>{};
  final Set<int> _continuationApplied = <int>{};
  final Map<int, Future<void>> _positionWrites = <int, Future<void>>{};

  Stream<ReadingProgressSyncEvent> get events => _events.stream;

  bool isOpening(int bookId) => _openingBooks.contains(bookId);
  bool isActive(int bookId) => _activeBooks.contains(bookId);
  bool wasContinuationApplied(int bookId) =>
      _continuationApplied.contains(bookId);
  bool takeContinuationApplied(int bookId) =>
      _continuationApplied.remove(bookId);

  void beginOpening(Book book) {
    final id = book.id;
    if (id == null) return;
    _openingBooks.add(id);
    _continuationApplied.remove(id);
    _preSyncHeads.remove(id);
    _preSyncPositions[id] = ReadingProgressSnapshot.fromBook(book);
  }

  void activate(int bookId) {
    _openingBooks.remove(bookId);
    _activeBooks.add(bookId);
  }

  void cancelOpening(int bookId) {
    _openingBooks.remove(bookId);
    _preSyncPositions.remove(bookId);
    _preSyncHeads.remove(bookId);
    _continuationApplied.remove(bookId);
  }

  void abandonSession(int bookId) {
    _openingBooks.remove(bookId);
    _activeBooks.remove(bookId);
    _preSyncPositions.remove(bookId);
    _preSyncHeads.remove(bookId);
    _continuationApplied.remove(bookId);
  }

  Future<void> endSession(int bookId) async {
    _openingBooks.remove(bookId);
    _activeBooks.remove(bookId);
    _preSyncPositions.remove(bookId);
    _preSyncHeads.remove(bookId);
    _continuationApplied.remove(bookId);
    final book = await BookDao().getBookById(bookId);
    if (book == null) return;
    final uid = await stableBookUid(book);
    _events.add(
      ReadingProgressSyncEvent(
        kind: ReadingProgressSyncEventKind.readerClosed,
        bookId: bookId,
        bookUid: uid,
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> recordLocalPosition(int bookId) async {
    final previous = _positionWrites[bookId] ?? Future<void>.value();
    final write = previous
        .catchError((_) {})
        .then((_) => _recordLocalPosition(bookId));
    _positionWrites[bookId] = write;
    try {
      await write;
    } finally {
      if (identical(_positionWrites[bookId], write)) {
        _positionWrites.remove(bookId);
      }
    }
  }

  Future<void> _recordLocalPosition(int bookId) async {
    final book = await BookDao().getBookById(bookId);
    if (book == null) return;
    final uid = await stableBookUid(book);
    final store = SyncChangeStore();
    var deviceId = await store.getState('device_id');
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await store.setState('device_id', deviceId);
    }
    final sequenceKey = '$deviceSequenceStatePrefix$uid:$deviceId';
    final sequence =
        (int.tryParse(await store.getState(sequenceKey) ?? '') ?? 0) + 1;
    final head =
        _decodeSnapshot(await store.getState('$headStatePrefix$uid')) ??
        _decodeSnapshot(await store.getState('$localEventStatePrefix$uid'));
    final vector = <String, int>{...?head?.vector, deviceId: sequence};
    final now = DateTime.now();
    final snapshot = ReadingProgressSnapshot(
      currentPage: book.currentPage,
      readingProgress: book.readingProgress,
      canonicalLocator: book.lastCanonicalLocator,
      eventId: const Uuid().v4(),
      savedAt: now,
      deviceId: deviceId,
      deviceSequence: sequence,
      vector: vector,
      locatorRevision: book.contentHash,
    );
    await store.setState(sequenceKey, '$sequence');
    await store.setState(
      '$localEventStatePrefix$uid',
      jsonEncode(snapshot.toJson()),
    );
    await store.setState('$headStatePrefix$uid', jsonEncode(snapshot.toJson()));
    _events.add(
      ReadingProgressSyncEvent(
        kind: ReadingProgressSyncEventKind.positionSaved,
        bookId: bookId,
        bookUid: uid,
        createdAt: now,
      ),
    );
  }

  Future<List<ReadingProgressRemoteCandidate>> candidatesFor(
    int bookId, {
    bool includeSnoozed = true,
  }) async {
    final book = await BookDao().getBookById(bookId);
    if (book == null) return const [];
    final uid = await stableBookUid(book);
    return candidatesForUid(uid, includeSnoozed: includeSnoozed);
  }

  Future<List<ReadingProgressRemoteCandidate>> candidatesForUid(
    String uid, {
    bool includeSnoozed = true,
    SyncChangeStore? changeStore,
  }) async {
    final store = changeStore ?? SyncChangeStore();
    final states = await store.statesWithPrefix('$candidateStatePrefix$uid:');
    final result = <ReadingProgressRemoteCandidate>[];
    for (final entry in states.entries) {
      final candidateId = entry.key.substring(entry.key.lastIndexOf(':') + 1);
      if (await store.getState(
            '$candidateDecisionStatePrefix$uid:$candidateId',
          ) !=
          null) {
        continue;
      }
      if (!includeSnoozed) {
        final snoozeKey = '$candidateSnoozeStatePrefix$uid:$candidateId';
        final rawSnooze = await store.getState(snoozeKey);
        final snoozedAt = DateTime.tryParse(rawSnooze ?? '');
        if (snoozedAt != null &&
            DateTime.now().toUtc().isBefore(
              snoozedAt.toUtc().add(candidateSnoozeDuration),
            )) {
          continue;
        }
        if (rawSnooze != null) await store.deleteState(snoozeKey);
      }
      try {
        final json = (jsonDecode(entry.value) as Map).cast<String, dynamic>();
        result.add(
          ReadingProgressRemoteCandidate(
            bookUid: uid,
            snapshot: ReadingProgressSnapshot.fromJson(
              (json['snapshot'] as Map).cast<String, dynamic>(),
            ),
            receivedAt: DateTime.parse(json['received_at'] as String),
          ),
        );
      } catch (_) {
        // Ignore one damaged candidate without hiding other devices.
      }
    }
    result.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    return result;
  }

  Future<ReadingProgressRemoteCandidate?> remoteCandidateFor(int bookId) async {
    final candidates = await candidatesFor(bookId, includeSnoozed: false);
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<Book> applySafeCandidateBeforeOpen(Book book) async {
    final id = book.id;
    if (id == null) return book;
    final uid = await stableBookUid(book);
    final store = SyncChangeStore();
    final candidates = await candidatesFor(id, includeSnoozed: false);
    final matching = candidates
        .where((candidate) => candidateMatchesBook(candidate, book))
        .toList(growable: false);
    if (matching.isEmpty) return book;
    final head = _decodeSnapshot(await store.getState('$headStatePrefix$uid'));
    final safe = chooseCandidateForOpen(book, head, matching);
    if (safe == null) return book;
    final applied = await applyCandidate(id, safe, currentBook: book);
    return applied ? (await BookDao().getBookById(id) ?? book) : book;
  }

  ReadingProgressRemoteCandidate? chooseCausallyNewest(
    ReadingProgressSnapshot? head,
    List<ReadingProgressRemoteCandidate> candidates,
  ) {
    final eligible = candidates
        .where((candidate) {
          if (head == null) return candidate.snapshot.vector != null;
          return compareReadingProgressEvents(
                head.toEventJson(),
                candidate.snapshot.toEventJson(),
              ) ==
              ReadingProgressEventRelation.incomingDominates;
        })
        .toList(growable: false);
    for (final candidate in eligible) {
      final dominatesAll = candidates.every((other) {
        if (identical(candidate, other)) return true;
        return compareReadingProgressEvents(
              other.snapshot.toEventJson(),
              candidate.snapshot.toEventJson(),
            ) ==
            ReadingProgressEventRelation.incomingDominates;
      });
      if (dominatesAll) return candidate;
    }
    return null;
  }

  ReadingProgressRemoteCandidate? chooseCandidateForOpen(
    Book book,
    ReadingProgressSnapshot? head,
    List<ReadingProgressRemoteCandidate> candidates,
  ) {
    final causal = chooseCausallyNewest(head, candidates);
    if (causal != null) return causal;
    final isDemonstrablyUnread =
        head == null &&
        book.currentPage <= 0 &&
        (book.readingProgress == null || book.readingProgress! <= 0) &&
        book.lastCanonicalLocator == null;
    if (!isDemonstrablyUnread || candidates.length != 1) return null;
    final candidate = candidates.single;
    return candidate.snapshot.vector == null ? candidate : null;
  }

  bool candidateMatchesBook(
    ReadingProgressRemoteCandidate candidate,
    Book book,
  ) {
    final revision = candidate.snapshot.locatorRevision;
    if (revision != null && revision != book.contentHash) return false;
    final raw = candidate.snapshot.canonicalLocator;
    if (raw == null) return true;
    final signature = LocatorCodec.decodeCanonicalLocator(
      raw,
    )?.contentSignature;
    return signature == null || signature == book.contentHash;
  }

  Future<bool> applyCandidate(
    int bookId,
    ReadingProgressRemoteCandidate candidate, {
    Book? currentBook,
  }) async {
    final book = currentBook ?? await BookDao().getBookById(bookId);
    if (book == null || !candidateMatchesBook(candidate, book)) return false;
    final uid = candidate.bookUid;
    final eventId = candidate.snapshot.eventId;
    if (eventId == null) return false;
    final candidateId = readingProgressCandidateId(
      candidate.snapshot.toEventJson(),
    );
    _preSyncPositions.putIfAbsent(
      bookId,
      () => ReadingProgressSnapshot.fromBook(book),
    );
    final store = SyncChangeStore();
    if (!_preSyncHeads.containsKey(bookId)) {
      _preSyncHeads[bookId] =
          await store.getState('$headStatePrefix$uid') ??
          await store.getState('$localEventStatePrefix$uid');
    }
    BookSourceReadingProgress? previousSourceProgress;
    var sourceProgressApplied = false;
    if (book.isOnline &&
        book.sourceId != null &&
        book.sourceBookId != null &&
        candidate.snapshot.sourceProgress != null) {
      const sourceStore = BookSourceReadingProgressStore();
      previousSourceProgress = await sourceStore.load(
        sourceId: book.sourceId!,
        bookId: book.sourceBookId!,
      );
      await sourceStore.save(
        sourceId: book.sourceId!,
        bookId: book.sourceBookId!,
        progress: BookSourceReadingProgress.fromJson(
          candidate.snapshot.sourceProgress!,
        ),
      );
      sourceProgressApplied = true;
    }
    try {
      await BookDao().replaceBookProgress(
        bookId,
        currentPage: candidate.snapshot.currentPage,
        readingProgress: candidate.snapshot.readingProgress,
        canonicalLocator: candidate.snapshot.canonicalLocator,
        totalPages: candidate.snapshot.totalPages,
        emitSyncEvent: false,
      );
    } catch (_) {
      if (sourceProgressApplied &&
          book.sourceId != null &&
          book.sourceBookId != null) {
        const sourceStore = BookSourceReadingProgressStore();
        if (previousSourceProgress == null) {
          await sourceStore.delete(
            sourceId: book.sourceId!,
            bookId: book.sourceBookId!,
          );
        } else {
          await sourceStore.save(
            sourceId: book.sourceId!,
            bookId: book.sourceBookId!,
            progress: previousSourceProgress,
          );
        }
      }
      rethrow;
    }
    final encoded = jsonEncode(candidate.snapshot.toJson());
    await store.setState('$headStatePrefix$uid', encoded);
    await store.setState('$localEventStatePrefix$uid', encoded);
    await store.setState(
      '$candidateDecisionStatePrefix$uid:$candidateId',
      'applied',
    );
    await store.deleteState(readingProgressCandidateKey(uid, candidateId));
    _continuationApplied.add(bookId);
    return true;
  }

  Future<void> snoozeCandidate(
    int bookId,
    ReadingProgressRemoteCandidate candidate, {
    SyncChangeStore? changeStore,
  }) async {
    final eventId = candidate.snapshot.eventId;
    if (eventId == null) return;
    final candidateId = readingProgressCandidateId(
      candidate.snapshot.toEventJson(),
    );
    await (changeStore ?? SyncChangeStore()).setState(
      '$candidateSnoozeStatePrefix${candidate.bookUid}:$candidateId',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> ignoreCandidate(
    ReadingProgressRemoteCandidate candidate, {
    SyncChangeStore? changeStore,
  }) async {
    final eventId = candidate.snapshot.eventId;
    if (eventId == null) return;
    final candidateId = readingProgressCandidateId(
      candidate.snapshot.toEventJson(),
    );
    final store = changeStore ?? SyncChangeStore();
    await store.setState(
      '$candidateDecisionStatePrefix${candidate.bookUid}:$candidateId',
      'ignored',
    );
    await store.deleteState(
      readingProgressCandidateKey(candidate.bookUid, candidateId),
    );
  }

  ReadingProgressSnapshot? preSyncPositionFor(int bookId) =>
      _preSyncPositions[bookId];

  Future<Book?> restorePreSyncPosition(int bookId) async {
    final snapshot = _preSyncPositions[bookId];
    if (snapshot == null) return null;
    final current = await BookDao().getBookById(bookId);
    if (current == null ||
        (snapshot.locatorRevision != null &&
            snapshot.locatorRevision != current.contentHash)) {
      _preSyncPositions.remove(bookId);
      _preSyncHeads.remove(bookId);
      _continuationApplied.remove(bookId);
      return null;
    }
    await BookDao().replaceBookProgress(
      bookId,
      currentPage: snapshot.currentPage,
      readingProgress: snapshot.readingProgress,
      canonicalLocator: snapshot.canonicalLocator,
      totalPages: snapshot.totalPages,
      emitSyncEvent: false,
    );
    final book = await BookDao().getBookById(bookId);
    if (book != null && _preSyncHeads.containsKey(bookId)) {
      final uid = await stableBookUid(book);
      final store = SyncChangeStore();
      final head = _preSyncHeads[bookId];
      if (head == null) {
        await store.deleteState('$headStatePrefix$uid');
        await store.deleteState('$localEventStatePrefix$uid');
      } else {
        await store.setState('$headStatePrefix$uid', head);
        await store.setState('$localEventStatePrefix$uid', head);
      }
    }
    _continuationApplied.remove(bookId);
    return book;
  }
}

ReadingProgressSnapshot? _decodeSnapshot(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    return ReadingProgressSnapshot.fromJson(
      (jsonDecode(raw) as Map).cast<String, dynamic>(),
    );
  } catch (_) {
    return null;
  }
}
