import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/book_note.dart';
import 'package:xxread/services/export/reading_data_export_models.dart';
import 'package:xxread/services/export/reading_data_export_repository.dart';
import 'package:xxread/services/export/reading_data_export_service.dart';

void main() {
  final book = Book(
    id: 7,
    title: 'Unsafe: <book>',
    author: 'A "writer"',
    filePath: '/book.epub',
    format: 'epub',
  );

  test('prepare filters ink, deduplicates UUID and sorts stably', () async {
    final repository = _Repository([
      _note(id: null, annotationId: '', page: 2),
      _note(id: null, annotationId: '', page: 1, type: 'note'),
      _note(id: 3, annotationId: 'same', page: 3),
      _note(id: 4, annotationId: 'same', page: 4),
      _note(id: 5, annotationId: 'ink', page: 0, type: 'ink'),
      _note(id: 6, annotationId: 'underline', page: 1, type: 'underline'),
    ]);
    final service = ReadingDataExportService(
      repository: repository,
      backend: _Backend(),
      clock: () => DateTime.utc(2025),
    );

    final prepared = await service.prepare(book);

    expect(prepared.annotations.map((note) => note.id), [6, null, null, 3]);
    expect(prepared.counts.total, 4);
    expect(prepared.counts.highlights, 2);
    expect(prepared.counts.underlines, 1);
    expect(prepared.counts.notes, 1);
  });

  test('markdown is safe, private ids absent, LF terminated once', () async {
    final service = ReadingDataExportService(
      repository: _Repository([
        _note(
          id: 99,
          annotationId: 'secret-uuid',
          page: 1,
          content: '<script>x</script>\r\n<!-- comment -->',
          readerNote: 'first\r\nsecond',
        ),
      ]),
      backend: _Backend(),
      clock: () => DateTime.utc(2025, 1, 2, 3, 4, 5),
    );

    final document = await service.prepareDocument(book);

    expect(document.markdown, isNot(contains('<script>')));
    expect(document.markdown, isNot(contains('<!--')));
    expect(document.markdown, isNot(contains('secret-uuid')));
    expect(document.markdown, isNot(contains('book_id')));
    expect(document.markdown, isNot(contains('\r')));
    expect(document.markdown, endsWith('\n'));
    expect(document.markdown, isNot(endsWith('\n\n')));
    expect(document.markdown, contains('> &lt;script&gt;x&lt;/script&gt;'));
    expect(document.markdown, contains('# 《Unsafe: &lt;book&gt;》'));
    expect(document.markdown, contains('**Author**'));
    expect(document.markdown, contains('**My note**'));
    expect(document.fileName, 'Unsafe_ _book_.md');
  });

  test('prepare failure does not invoke backend', () async {
    final backend = _Backend();
    final service = ReadingDataExportService(
      repository: _ThrowingRepository(),
      backend: backend,
    );

    final result = await service.export(book);

    expect(result.status, ReadingDataExportStatus.failure);
    expect(backend.calls, 0);
  });

  test('maps backend statuses', () async {
    for (final status in ReadingDataExportStatus.values) {
      final backend = _Backend(status);
      final service = ReadingDataExportService(
        repository: _Repository([]),
        backend: backend,
      );
      expect((await service.export(book)).status, status);
    }
  });

  test('safe filename handles reserved, traversal, unicode separators', () {
    expect(safeReadingDataExportFileName('CON'), '_CON.md');
    expect(safeReadingDataExportFileName(' <>:"/\\|?* '), isNot(contains('/')));
    expect(safeReadingDataExportFileName('...'), isNot('....md'));
    expect(safeReadingDataExportFileName('../evil'), isNot(contains('/')));
    expect(safeReadingDataExportFileName('a∕b⁄c'), 'a-b-c.md');
    expect(safeReadingDataExportFileName('safe\u202Ename'), 'safename.md');
  });
}

BookNote _note({
  required int? id,
  required String annotationId,
  required int page,
  String type = 'highlight',
  String content = 'quote',
  String? readerNote,
}) => BookNote(
  id: id,
  annotationId: annotationId,
  bookId: 7,
  content: content,
  cfi: 'cfi-$page-$id',
  chapter: 'Chapter',
  type: type,
  color: 'FF0000',
  readerNote: readerNote,
  pageNumber: page,
  updateTime: DateTime.utc(2025),
);

class _Repository implements ReadingDataExportRepository {
  _Repository(this.rows);
  final List<BookNote> rows;
  @override
  Future<List<BookNote>> annotationsForBook(int bookId) async => rows;
}

class _ThrowingRepository implements ReadingDataExportRepository {
  @override
  Future<List<BookNote>> annotationsForBook(int bookId) async =>
      throw StateError('prepare failed');
}

class _Backend implements ReadingDataExportBackend {
  _Backend([this.resultStatus = ReadingDataExportStatus.success]);
  final ReadingDataExportStatus resultStatus;
  int calls = 0;

  @override
  Future<ReadingDataExportBackendResult> export(
    ReadingDataExportRequest request,
  ) async {
    calls++;
    return switch (resultStatus) {
      ReadingDataExportStatus.success =>
        const ReadingDataExportBackendResult.success(displayName: 'notes.md'),
      ReadingDataExportStatus.cancelled =>
        const ReadingDataExportBackendResult.cancelled(),
      ReadingDataExportStatus.unsupported =>
        const ReadingDataExportBackendResult.unsupported(),
      ReadingDataExportStatus.failure =>
        const ReadingDataExportBackendResult.failure('failed'),
    };
  }
}
