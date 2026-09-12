import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../source_engine/source_login_ui.dart';
import 'book_download_cancellation.dart';

class DiscoveredBookSource {
  final Uri manifestUrl;
  final BookSourceManifest manifest;

  const DiscoveredBookSource({
    required this.manifestUrl,
    required this.manifest,
  });
}

abstract interface class BookSourceGateway {
  Future<List<SourceLoginField>> loadLoginFields(RegisteredBookSource source);

  Future<void> loginSource(
    RegisteredBookSource source,
    Map<String, String> values, {
    String? action,
  });

  Future<void> clearSourceLogin(RegisteredBookSource source);

  Future<DiscoveredBookSource> discover(String input);

  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  });

  /// Discovery operations may publish a bounded cached snapshot via [onCached]
  /// before the returned future completes with fresh data (or the snapshot if
  /// refresh fails). Callers must guard both deliveries against navigation.
  Future<BookSourceDiscoveryPage> getDiscovery(
    RegisteredBookSource source, {
    void Function(BookSourceDiscoveryPage)? onCached,
  });

  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source, {
    void Function(List<BookSourceCategory>)? onCached,
  });

  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    String sort = 'latest',
    int page = 1,
    int pageSize = 20,
    void Function(BookSourceSearchPage)? onCached,
  });

  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  });

  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  });

  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  });

  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  });

  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  });

  Future<void> prefetchChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  });

  Future<void> invalidateResponseCache(RegisteredBookSource source);

  Future<void> invalidateResponseCaches(Iterable<RegisteredBookSource> sources);

  Future<void> invalidateDiscoveryResponseCache(String input);
}
