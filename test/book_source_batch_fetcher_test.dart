import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_batch_fetcher.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';

void main() {
  test('returns an empty list when there are no sources', () async {
    final fetcher = BookSourceBatchFetcher(maxConcurrent: 8);

    expect(await fetcher.fetch(const [], (_) async => ['item']), isEmpty);
  });

  test(
    'keeps source order and drops a failed source when others succeed',
    () async {
      final sources = [_source('a'), _source('b'), _source('c')];
      final fetcher = BookSourceBatchFetcher(maxConcurrent: 8);

      final batches = await fetcher.fetch(sources, (source) async {
        if (source.id == 'b') throw StateError('offline');
        return [source.id];
      });

      expect(batches, [
        ['a'],
        ['c'],
      ]);
    },
  );

  test('throws joined protocol errors when every source fails', () async {
    final sources = [_source('alpha'), _source('beta')];
    final fetcher = BookSourceBatchFetcher(maxConcurrent: 2);

    expect(
      () => fetcher.fetch(sources, (source) async {
        throw StateError('${source.id} down');
      }),
      throwsA(
        isA<BookSourceProtocolException>().having(
          (error) => error.message,
          'message',
          'alpha: Bad state: alpha down\nbeta: Bad state: beta down',
        ),
      ),
    );
  });

  test(
    'throws when every successful batch is empty and another source failed',
    () async {
      final sources = [_source('empty'), _source('broken')];
      final fetcher = BookSourceBatchFetcher(maxConcurrent: 2);

      expect(
        () => fetcher.fetch(sources, (source) async {
          if (source.id == 'broken') throw StateError('timeout');
          return const <String>[];
        }),
        throwsA(isA<BookSourceProtocolException>()),
      );
    },
  );

  test('bounds concurrent source requests', () async {
    final sources = List.generate(12, (index) => _source('source-$index'));
    final fetcher = BookSourceBatchFetcher(maxConcurrent: 3);
    var active = 0;
    var maxActive = 0;

    await fetcher.fetch(sources, (source) async {
      active++;
      if (active > maxActive) maxActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 8));
      active--;
      return [source.id];
    });

    expect(maxActive, lessThanOrEqualTo(3));
  });

  test('interleaves latest batches and caps each source contribution', () {
    final sourceA = _source('source-a', name: 'Source A');
    final sourceB = _source('source-b', name: 'Source B');
    final batches = [
      [
        _sourcedBook(sourceA, 'A1', DateTime.utc(2026, 7, 18)),
        _sourcedBook(sourceA, 'A2', DateTime.utc(2026, 7, 17)),
        _sourcedBook(sourceA, 'A3', DateTime.utc(2026, 7, 16)),
      ],
      [
        _sourcedBook(sourceB, 'B1', DateTime.utc(2026, 7, 19)),
        _sourcedBook(sourceB, 'B2', DateTime.utc(2026, 7, 15)),
        _sourcedBook(sourceB, 'B3', DateTime.utc(2026, 7, 14)),
      ],
    ];

    final merged = mergeLatestSourceBatches(batches, maxItemsPerSource: 2);

    expect(merged.map((item) => item.book.title), ['B1', 'A1', 'B2', 'A2']);
  });

  test('prefers a dated source over an undated source, then source name', () {
    final dated = _source('dated', name: 'Zebra');
    final undated = _source('undated', name: 'Alpha');
    final namedEarlier = _source('named-a', name: 'Alpha');
    final namedLater = _source('named-b', name: 'Beta');

    expect(
      mergeLatestSourceBatches([
        [_sourcedBook(undated, 'U1', null)],
        [_sourcedBook(dated, 'D1', DateTime.utc(2026, 7, 19))],
      ], maxItemsPerSource: 1).map((item) => item.book.title),
      ['D1', 'U1'],
    );
    expect(
      mergeLatestSourceBatches([
        [_sourcedBook(namedLater, 'B1', null)],
        [_sourcedBook(namedEarlier, 'A1', null)],
      ], maxItemsPerSource: 1).map((item) => item.book.title),
      ['A1', 'B1'],
    );
    expect(mergeLatestSourceBatches(const [], maxItemsPerSource: 0), isEmpty);
  });
}

RegisteredBookSource _source(String id, {String? name}) => RegisteredBookSource(
  id: id,
  name: name ?? id,
  description: '',
  manifestUrl: Uri.parse('https://example.org/$id/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/$id/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'discover', 'categories', 'browse'},
  enabled: true,
  addedAt: DateTime.utc(2026, 8, 9),
);

SourcedBook _sourcedBook(
  RegisteredBookSource source,
  String title,
  DateTime? updatedAt,
) => SourcedBook(
  source: source,
  book: BookSourceBook(
    id: title.toLowerCase(),
    title: title,
    author: 'Author',
    description: '',
    categories: const [],
    updatedAt: updatedAt,
  ),
);
