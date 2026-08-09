import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_change_service.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/book_sources/book_source_change_page.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('change page closes only a factory-created service', (
    tester,
  ) async {
    final ownedService = _CloseTrackingChangeService();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceChangePage(
          sources: const [],
          currentSource: _oldSource,
          currentBook: _oldBook,
          serviceFactory: () => ownedService,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    expect(ownedService.closeCount, 1);

    final borrowedService = _CloseTrackingChangeService();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceChangePage(
          sources: const [],
          currentSource: _oldSource,
          currentBook: _oldBook,
          service: borrowedService,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(borrowedService.closeCount, 0);
    borrowedService.close();
  });

  testWidgets(
    'candidate must be validated before source switching is enabled',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      final service = _PageChangeService();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BookSourceChangePage(
            sources: [_oldSource, _newSource],
            currentSource: _oldSource,
            currentBook: _oldBook,
            service: service,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current source'), findsOneWidget);
      expect(find.text('New source'), findsOneWidget);
      final before = tester.widget<FilledButton>(
        find.byKey(const Key('bookSourceChangeCommit')),
      );
      expect(before.onPressed, isNull);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const ValueKey('bookSourceChangeCandidate-new-source')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current chapter readable'), findsOneWidget);
      final after = tester.widget<FilledButton>(
        find.byKey(const Key('bookSourceChangeCommit')),
      );
      expect(after.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'starts source search before current reading position finishes loading',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      final service = _DeferredPreparationService();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BookSourceChangePage(
            sources: [_oldSource, _newSource],
            currentSource: _oldSource,
            currentBook: _oldBook,
            service: service,
          ),
        ),
      );

      expect(find.text('Finding other sources'), findsOneWidget);
      await tester.pump();
      await tester.pump();

      expect(service.searchCount, 1);
      expect(service.positionCompleted, isFalse);
      expect(find.text('Finding other sources'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      service.completePosition();
      service.completeSearch();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('candidate validation waits for deferred reading position', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    final service = _DeferredCandidateService();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceChangePage(
          sources: [_oldSource, _newSource],
          currentSource: _oldSource,
          currentBook: _oldBook,
          service: service,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(
      find.byKey(const ValueKey('bookSourceChangeCandidate-new-source')),
    );
    await tester.pump();
    expect(service.validateCount, 0);

    service.completePosition();
    await tester.pumpAndSettle();

    expect(service.validateCount, 1);
    final commit = tester.widget<FilledButton>(
      find.byKey(const Key('bookSourceChangeCommit')),
    );
    expect(commit.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an author-matching candidate that arrives later moves above an earlier mismatch',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 900);
      addTearDown(tester.view.reset);
      final service = _CandidateOrderService();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BookSourceChangePage(
            sources: [_oldSource, _mismatchSource, _matchSource],
            currentSource: _oldSource,
            currentBook: _oldBook,
            service: service,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));

      expect(
        find.byKey(const ValueKey('bookSourceChangeCandidate-mismatch-source')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('bookSourceChangeCandidate-match-source')),
        findsNothing,
      );

      service.releaseSecond();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('bookSourceChangeCandidate-match-source')),
        findsOneWidget,
      );
      final matchY = tester
          .getTopLeft(
            find.byKey(
              const ValueKey('bookSourceChangeCandidate-match-source'),
            ),
          )
          .dy;
      final mismatchY = tester
          .getTopLeft(
            find.byKey(
              const ValueKey('bookSourceChangeCandidate-mismatch-source'),
            ),
          )
          .dy;
      expect(matchY, lessThan(mismatchY));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('quick search pauses before scanning every source', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    final client = _FastEmptyClient();
    final sources = <RegisteredBookSource>[
      _oldSource,
      for (var index = 0; index < 65; index++)
        _source('bulk-$index', 'Bulk $index'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BookSourceChangePage(
          sources: sources,
          currentSource: _oldSource,
          currentBook: _oldBook,
          service: BookSourceChangeService(client: client),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(client.searchCount, 60);
    expect(
      find.byKey(const Key('bookSourceChangeSearchRemaining')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('bookSourceChangeSearchRemaining')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    expect(client.searchCount, 65);
    expect(
      find.byKey(const Key('bookSourceChangeSearchRemaining')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

final _oldSource = _source('old-source', 'Old source');
final _newSource = _source('new-source', 'New source');
final _mismatchSource = _source('mismatch-source', 'Mismatch source');
final _matchSource = _source('match-source', 'Match source');

RegisteredBookSource _source(String id, String name) => RegisteredBookSource(
  id: id,
  name: name,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/api/'),
  protocolVersion: '1.5',
  languages: const ['en'],
  capabilities: const {'search', 'detail', 'catalog', 'content'},
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 2),
);

const _oldBook = BookSourceBook(
  id: 'old-book',
  title: 'Test book',
  author: 'Author',
  description: '',
  categories: [],
);

const _newBook = BookSourceBook(
  id: 'new-book',
  title: 'Test book',
  author: 'Author',
  description: '',
  categories: [],
);

class _PageChangeService extends BookSourceChangeService {
  late final candidate = BookSourceChangeCandidate(
    source: _newSource,
    book: _newBook,
    authorMatches: true,
  );

  @override
  Future<BookSourceChangePosition> loadPosition({
    required RegisteredBookSource source,
    required BookSourceBook book,
    Book? shelfBook,
  }) async => const BookSourceChangePosition(
    chapterIndex: 4,
    chapterProgress: 0.5,
    chapterTitle: 'Chapter 5',
    chapterCount: 10,
  );

  @override
  Stream<BookSourceChangeSearchEvent> search({
    required Iterable<RegisteredBookSource> sources,
    required String title,
    required String author,
    required bool checkAuthor,
    String? currentSourceId,
    Set<String> excludedSourceIds = const {},
    int? sourceLimit,
    int? candidateLimit,
  }) async* {
    yield BookSourceChangeSearchEvent(
      source: _newSource,
      completed: 1,
      candidates: [candidate],
    );
  }

  @override
  Future<ValidatedBookSourceChange> validate({
    required BookSourceChangeCandidate candidate,
    required BookSourceChangePosition position,
  }) async => ValidatedBookSourceChange(
    candidate: candidate,
    book: _newBook,
    chapters: List.generate(
      12,
      (index) => BookSourceChapter(
        id: 'chapter-$index',
        title: 'Chapter ${index + 1}',
        order: index,
      ),
    ),
    chapterIndex: 4,
    chapterProgress: 0.5,
    responseTime: const Duration(milliseconds: 240),
  );
}

class _CandidateOrderService extends BookSourceChangeService {
  final _second = Completer<void>();

  void releaseSecond() => _second.complete();

  @override
  Future<BookSourceChangePosition> loadPosition({
    required RegisteredBookSource source,
    required BookSourceBook book,
    Book? shelfBook,
  }) async => const BookSourceChangePosition(
    chapterIndex: 0,
    chapterProgress: 0,
    chapterTitle: '',
    chapterCount: 0,
  );

  @override
  Stream<BookSourceChangeSearchEvent> search({
    required Iterable<RegisteredBookSource> sources,
    required String title,
    required String author,
    required bool checkAuthor,
    String? currentSourceId,
    Set<String> excludedSourceIds = const {},
    int? sourceLimit,
    int? candidateLimit,
  }) async* {
    yield BookSourceChangeSearchEvent(
      source: _mismatchSource,
      completed: 1,
      candidates: [
        BookSourceChangeCandidate(
          source: _mismatchSource,
          book: const BookSourceBook(
            id: 'mismatch-book',
            title: 'Test book',
            author: 'A Different Author',
            description: '',
            categories: [],
          ),
          authorMatches: false,
        ),
      ],
    );
    await _second.future;
    yield BookSourceChangeSearchEvent(
      source: _matchSource,
      completed: 2,
      candidates: [
        BookSourceChangeCandidate(
          source: _matchSource,
          book: const BookSourceBook(
            id: 'match-book',
            title: 'Test book',
            author: 'Author',
            description: '',
            categories: [],
          ),
          authorMatches: true,
        ),
      ],
    );
  }
}

class _CloseTrackingChangeService extends _PageChangeService {
  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    super.close();
  }
}

class _FastEmptyClient extends BookSourceClient {
  int searchCount = 0;

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    searchCount++;
    return BookSourceSearchPage(
      items: const [],
      page: page,
      pageSize: pageSize,
      hasMore: false,
    );
  }

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async => const [
    BookSourceChapter(id: 'chapter-1', title: 'Chapter 1', order: 0),
  ];
}

class _DeferredPreparationService extends BookSourceChangeService {
  final Completer<BookSourceChangePosition> _position = Completer();
  final Completer<void> _search = Completer();
  int searchCount = 0;

  bool get positionCompleted => _position.isCompleted;

  void completePosition() {
    _position.complete(
      const BookSourceChangePosition(
        chapterIndex: 0,
        chapterProgress: 0,
        chapterTitle: 'Chapter 1',
        chapterCount: 1,
      ),
    );
  }

  void completeSearch() => _search.complete();

  @override
  Future<BookSourceChangePosition> loadPosition({
    required RegisteredBookSource source,
    required BookSourceBook book,
    Book? shelfBook,
  }) => _position.future;

  @override
  Stream<BookSourceChangeSearchEvent> search({
    required Iterable<RegisteredBookSource> sources,
    required String title,
    required String author,
    required bool checkAuthor,
    String? currentSourceId,
    Set<String> excludedSourceIds = const {},
    int? sourceLimit,
    int? candidateLimit,
  }) async* {
    searchCount++;
    await _search.future;
  }
}

class _DeferredCandidateService extends BookSourceChangeService {
  final Completer<BookSourceChangePosition> _position = Completer();
  int validateCount = 0;

  void completePosition() {
    _position.complete(
      const BookSourceChangePosition(
        chapterIndex: 4,
        chapterProgress: 0.5,
        chapterTitle: 'Chapter 5',
        chapterCount: 10,
      ),
    );
  }

  @override
  Future<BookSourceChangePosition> loadPosition({
    required RegisteredBookSource source,
    required BookSourceBook book,
    Book? shelfBook,
  }) => _position.future;

  @override
  Stream<BookSourceChangeSearchEvent> search({
    required Iterable<RegisteredBookSource> sources,
    required String title,
    required String author,
    required bool checkAuthor,
    String? currentSourceId,
    Set<String> excludedSourceIds = const {},
    int? sourceLimit,
    int? candidateLimit,
  }) async* {
    yield BookSourceChangeSearchEvent(
      source: _newSource,
      completed: 1,
      candidates: [
        BookSourceChangeCandidate(
          source: _newSource,
          book: _newBook,
          authorMatches: true,
        ),
      ],
    );
  }

  @override
  Future<ValidatedBookSourceChange> validate({
    required BookSourceChangeCandidate candidate,
    required BookSourceChangePosition position,
  }) async {
    validateCount++;
    return ValidatedBookSourceChange(
      candidate: candidate,
      book: _newBook,
      chapters: const [
        BookSourceChapter(id: 'chapter-5', title: 'Chapter 5', order: 4),
      ],
      chapterIndex: 0,
      chapterProgress: position.chapterProgress,
      responseTime: const Duration(milliseconds: 120),
    );
  }
}
