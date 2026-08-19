import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';

bool isOnlineComicSource(RegisteredBookSource source, BookSourceBook book) {
  if (book.type == 64) {
    comicDebugLog(
      'route',
      'source=${source.name} book=${book.title} routed=comic reason=bookType64',
    );
    return true;
  }
  final raw = source.sourceConfig;
  if (raw == null) {
    comicDebugLog(
      'route',
      'source=${source.name} book=${book.title} routed=text '
          'reason=noSourceConfig bookType=${book.type}',
    );
    return false;
  }
  try {
    final config = ReadingSourceConfig.fromJson(raw);
    final image = config.isImageSource;
    comicDebugLog(
      'route',
      'source=${source.name} book=${book.title} '
          'declaredSourceType=${config.type} effectiveBookType=${config.effectiveBookType} '
          'bookType=${book.type} routed=${image ? 'comic' : 'text'}',
    );
    return image;
  } on FormatException catch (error) {
    final image = raw['bookSourceType'] == 2;
    comicDebugLog(
      'route',
      'source=${source.name} book=${book.title} fallbackType=${raw['bookSourceType']} '
          'routed=${image ? 'comic' : 'text'}',
      error: error,
    );
    return image;
  }
}
