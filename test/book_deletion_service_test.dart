import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_cover_edit_service.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/book_deletion_service.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('book-deletion-test-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test(
    'deletes owned files, cover leftovers, and database record in order',
    () async {
      final bookFile = File('${sandbox.path}/book.epub');
      final coverFile = File('${sandbox.path}/cover.jpg');
      await bookFile.writeAsString('book');
      await coverFile.writeAsString('cover');
      final dao = _RecordingBookDao();
      final coverService = _RecordingCoverEditService();
      final service = BookDeletionService(
        bookDao: dao,
        coverEditService: coverService,
      );
      final stages = <BookDeletionStage>[];

      await service.delete(
        Book(
          id: 7,
          title: 'Clean Architecture',
          filePath: bookFile.path,
          format: 'EPUB',
          coverImagePath: coverFile.path,
        ),
        onProgress: stages.add,
      );

      expect(await bookFile.exists(), isFalse);
      expect(await coverFile.exists(), isFalse);
      expect(coverService.cleanedBookId, 7);
      expect(dao.deletedBookId, 7);
      expect(stages, BookDeletionStage.values);
    },
  );
}

class _RecordingBookDao extends BookDao {
  int? deletedBookId;

  @override
  Future<void> deleteBook(int bookId) async {
    deletedBookId = bookId;
  }
}

class _RecordingCoverEditService extends BookCoverEditService {
  int? cleanedBookId;

  @override
  Future<void> cleanupForDeletedBook(Book book) async {
    cleanedBookId = book.id;
  }
}
