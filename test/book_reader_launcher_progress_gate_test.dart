import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/reader/book_reader_launcher.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/services/sync/sync_models.dart';

void main() {
  testWidgets('pre-open gate refreshes progress before the reader is built', (
    tester,
  ) async {
    final sync = _ProgressGateController();
    final result = Completer<Book>();
    final calls = <String>[];
    final local = Book(
      id: 7,
      title: 'TXT',
      filePath: '/tmp/book.txt',
      format: 'txt',
      currentPage: 1,
    );
    final remote = local.copyWith(
      currentPage: 8,
      readingProgress: 0.8,
      lastCanonicalLocator:
          '{"format":"txt","chapterId":"txt-8","progression":0.4}',
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<WebDavSyncController>.value(
        value: sync,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result.complete(
                  await BookReaderLauncher.refreshProgressBeforeOpen(
                    context,
                    local,
                    reloadBook: (_) async {
                      calls.add('reload');
                      return remote;
                    },
                    applyCandidate: (book) async {
                      calls.add('apply:${book.currentPage}');
                      return book;
                    },
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect(sync.checkCount, 1);
    expect((await result.future).currentPage, 8);
    expect(calls, ['reload', 'apply:8']);
  });

  testWidgets('slow WebDAV check is bounded and still opens locally', (
    tester,
  ) async {
    final sync = _ProgressGateController(block: true);
    final result = Completer<Book>();
    final local = Book(
      id: 9,
      title: 'TXT',
      filePath: '/tmp/book.txt',
      format: 'txt',
      currentPage: 3,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<WebDavSyncController>.value(
        value: sync,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result.complete(
                  await BookReaderLauncher.refreshProgressBeforeOpen(
                    context,
                    local,
                    timeout: const Duration(milliseconds: 10),
                    reloadBook: (_) async => local,
                    applyCandidate: (book) async => book,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 20));

    expect((await result.future).currentPage, 3);
    expect(sync.checkCount, 1);
  });

  testWidgets('candidate apply failure still opens at the local position', (
    tester,
  ) async {
    final sync = _ProgressGateController();
    final result = Completer<Book>();
    final local = Book(
      id: 11,
      title: 'TXT',
      filePath: '/tmp/book.txt',
      format: 'txt',
      currentPage: 3,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<WebDavSyncController>.value(
        value: sync,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result.complete(
                  await BookReaderLauncher.refreshProgressBeforeOpen(
                    context,
                    local,
                    reloadBook: (_) async => local.copyWith(currentPage: 8),
                    applyCandidate: (_) async => throw StateError('damaged'),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    expect((await result.future).currentPage, 3);
  });

  testWidgets('disabled auto resume preserves the local position', (
    tester,
  ) async {
    final sync = _ProgressGateController(resume: false);
    final result = Completer<Book>();
    final local = Book(
      id: 10,
      title: 'TXT',
      filePath: '/tmp/book.txt',
      format: 'txt',
      currentPage: 3,
    );
    var applied = false;
    await tester.pumpWidget(
      ChangeNotifierProvider<WebDavSyncController>.value(
        value: sync,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result.complete(
                  await BookReaderLauncher.refreshProgressBeforeOpen(
                    context,
                    local,
                    reloadBook: (_) async => local.copyWith(currentPage: 8),
                    applyCandidate: (book) async {
                      applied = true;
                      return book;
                    },
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();

    expect((await result.future).currentPage, 3);
    expect(sync.checkCount, 0);
    expect(applied, isFalse);
  });

  testWidgets('online chooser keeps local progress and records the decision', (
    tester,
  ) async {
    final result = Completer<Book>();
    final local = Book(
      id: 12,
      title: 'Online',
      filePath: '',
      format: 'source',
      storageType: 'online',
      currentPage: 3,
      readingProgress: 0.3,
    );
    final candidate = ReadingProgressRemoteCandidate(
      bookUid: 'source:book',
      snapshot: const ReadingProgressSnapshot(
        currentPage: 8,
        readingProgress: 0.8,
        canonicalLocator: null,
        eventId: 'remote-event',
        sourceProgress: {'chapterId': 'Chapter 8', 'chapterProgress': 0.5},
      ),
      receivedAt: DateTime.utc(2026),
    );
    ReadingProgressRemoteCandidate? ignored;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result.complete(
                await BookReaderLauncher.chooseOnlineCandidate(
                  context,
                  local,
                  candidatesOverride: [candidate],
                  keepLocal: (value) async => ignored = value,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Reading position from another device'), findsOneWidget);
    expect(find.textContaining('Chapter 8, 50%'), findsOneWidget);
    await tester.tap(find.text('Keep local position'));
    await tester.pumpAndSettle();

    expect((await result.future).currentPage, 3);
    expect(ignored, same(candidate));
  });
}

class _ProgressGateController extends WebDavSyncController {
  _ProgressGateController({this.block = false, this.resume = true});

  final bool block;
  final bool resume;
  int checkCount = 0;

  @override
  bool get autoResume => resume;

  @override
  bool get autoSync => true;

  @override
  WebDavSyncScope get scope => const WebDavSyncScope(progress: true);

  @override
  Future<void> checkProgressBeforeOpen() {
    checkCount++;
    return block ? Completer<void>().future : Future<void>.value();
  }
}
