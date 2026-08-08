// 文件说明：统一执行书籍文件、封面残留与数据库记录删除。
// 技术要点：服务层只报告阶段，不持有 BuildContext 或本地化文案。

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_cover_edit_service.dart';
import 'package:xxread/services/books/book_dao.dart';

enum BookDeletionStage { bookFile, coverImage, database, complete }

typedef BookDeletionProgress = void Function(BookDeletionStage stage);

class BookDeletionService {
  BookDeletionService({
    BookDao? bookDao,
    BookCoverEditService? coverEditService,
  }) : _bookDao = bookDao ?? BookDao(),
       _coverEditService = coverEditService ?? BookCoverEditService();

  final BookDao _bookDao;
  final BookCoverEditService _coverEditService;

  Future<void> delete(Book book, {BookDeletionProgress? onProgress}) async {
    final bookId = ArgumentError.checkNotNull(book.id, 'book.id');
    final startedAt = DateTime.now();
    debugPrint('Deleting book: ${book.title}');

    try {
      onProgress?.call(BookDeletionStage.bookFile);
      if (!kIsWeb && book.filePath.isNotEmpty) {
        await _deleteIfExists(File(book.filePath));
      }

      onProgress?.call(BookDeletionStage.coverImage);
      if (!kIsWeb) {
        final coverPath = book.coverImagePath;
        if (coverPath != null && coverPath.isNotEmpty) {
          await _deleteIfExists(File(coverPath));
        }
        await _coverEditService.cleanupForDeletedBook(book);
      }

      onProgress?.call(BookDeletionStage.database);
      await _bookDao.deleteBook(bookId);

      onProgress?.call(BookDeletionStage.complete);
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      debugPrint('Deleted book ${book.title} in ${elapsed}ms');
    } catch (error, stackTrace) {
      debugPrint('Failed to delete book ${book.title}: $error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }
}
