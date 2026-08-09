import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/pages/book_sources/models/book_search_relevance.dart';
import 'package:xxread/pages/book_sources/models/sourced_book.dart';

void main() {
  group('sourcedBookRelevance', () {
    test('ranks an exact title match above a partial match', () {
      expect(
        sourcedBookRelevance('三体', _book(title: '三体')),
        greaterThan(sourcedBookRelevance('三体', _book(title: '三体全集'))),
      );
    });

    test('ranks a title prefix match above a mid-string match', () {
      expect(
        sourcedBookRelevance('三体', _book(title: '三体全集')),
        greaterThan(sourcedBookRelevance('三体', _book(title: '解读三体'))),
      );
    });

    test('ranks a title match above an author-only match', () {
      expect(
        sourcedBookRelevance('刘慈欣', _book(title: '刘慈欣作品集')),
        greaterThan(
          sourcedBookRelevance('刘慈欣', _book(title: '三体', author: '刘慈欣')),
        ),
      );
    });

    test('an author-only match still outranks no match at all', () {
      expect(
        sourcedBookRelevance('刘慈欣', _book(title: '三体', author: '刘慈欣')),
        greaterThan(sourcedBookRelevance('刘慈欣', _book(title: '球状闪电'))),
      );
    });

    test('ignores full-width/half-width and case differences', () {
      expect(
        sourcedBookRelevance('TEST', _book(title: 'ｔｅｓｔ')),
        sourcedBookRelevance('test', _book(title: 'Test')),
      );
    });

    test('an empty query never boosts any result', () {
      expect(sourcedBookRelevance('', _book(title: 'Anything')), 0);
    });
  });
}

SourcedBook _book({required String title, String author = ''}) => SourcedBook(
  source: _source,
  book: BookSourceBook(
    id: 'book-id',
    title: title,
    author: author,
    description: '',
    categories: const [],
  ),
);

final _source = RegisteredBookSource(
  id: 'source-a',
  name: 'Source A',
  description: '',
  manifestUrl: Uri.parse('https://example.org/source.json'),
  apiBaseUrl: Uri.parse('https://example.org/api/'),
  protocolVersion: '1.1',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026, 7, 13),
);
