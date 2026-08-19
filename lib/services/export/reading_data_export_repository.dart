import 'package:xxread/models/book_note.dart';
import 'package:xxread/services/books/book_note_dao.dart';

abstract interface class ReadingDataExportRepository {
  Future<List<BookNote>> annotationsForBook(int bookId);
}

class BookNoteReadingDataExportRepository
    implements ReadingDataExportRepository {
  BookNoteReadingDataExportRepository({BookNoteDao? bookNoteDao})
    : _bookNoteDao = bookNoteDao ?? BookNoteDao();

  final BookNoteDao _bookNoteDao;

  @override
  Future<List<BookNote>> annotationsForBook(int bookId) =>
      _bookNoteDao.selectBookNotesByBookId(bookId);
}
