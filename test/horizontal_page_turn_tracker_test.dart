import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/horizontal_page_turn_tracker.dart';

void main() {
  const chapter0Page0 = ReaderPagePosition(chapterIndex: 0, pageIndex: 0);

  test('records the exact pending page and one forward read', () {
    final tracker = HorizontalPageTurnTracker<String>();

    final pending = tracker.record(
      page: 'chapter-0-page-1',
      position: const ReaderPagePosition(chapterIndex: 0, pageIndex: 1),
      committedPosition: chapter0Page0,
    );

    expect(pending.page, 'chapter-0-page-1');
    expect(pending.pagesReadDelta, 1);
    expect(tracker.hasPending, isTrue);
  });

  test('accumulates forward turns while replacing the pending target', () {
    final tracker = HorizontalPageTurnTracker<String>();

    tracker.record(
      page: 'chapter-0-page-1',
      position: const ReaderPagePosition(chapterIndex: 0, pageIndex: 1),
      committedPosition: chapter0Page0,
    );
    final pending = tracker.record(
      page: 'chapter-1-page-0',
      position: const ReaderPagePosition(chapterIndex: 1, pageIndex: 0),
      committedPosition: chapter0Page0,
    );

    expect(pending.page, 'chapter-1-page-0');
    expect(pending.pagesReadDelta, 2);
  });

  test('backward observations keep the accumulated read count', () {
    final tracker = HorizontalPageTurnTracker<String>();

    tracker.record(
      page: 'chapter-0-page-2',
      position: const ReaderPagePosition(chapterIndex: 0, pageIndex: 2),
      committedPosition: chapter0Page0,
    );
    final pending = tracker.record(
      page: 'chapter-0-page-1',
      position: const ReaderPagePosition(chapterIndex: 0, pageIndex: 1),
      committedPosition: chapter0Page0,
    );

    expect(pending.page, 'chapter-0-page-1');
    expect(pending.pagesReadDelta, 1);
  });

  test('take returns the exit target and clears pending state', () {
    final tracker = HorizontalPageTurnTracker<String>();
    tracker.record(
      page: 'chapter-2-page-3',
      position: const ReaderPagePosition(chapterIndex: 2, pageIndex: 3),
      committedPosition: chapter0Page0,
    );

    final pending = tracker.take();

    expect(pending?.page, 'chapter-2-page-3');
    expect(tracker.pending, isNull);
    expect(tracker.hasPending, isFalse);
  });
}
