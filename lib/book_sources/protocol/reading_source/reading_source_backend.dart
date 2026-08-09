import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/core/app_settings_service.dart';
import '../../models/registered_book_source.dart';
import '../../services/book_download_cancellation.dart';
import '../../source_engine/source_login_ui.dart';
import '../../source_engine/source_runtime.dart';
import '../book_source_protocol.dart';

abstract interface class ReadingSourceBackendPort {
  Future<List<SourceLoginField>> loadLoginFields(RegisteredBookSource source);
  Future<void> loginSource(
    RegisteredBookSource source,
    Map<String, String> values,
  );
  Future<void> clearSourceLogin(RegisteredBookSource source);
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  });
  Future<List<BookSourceCategory>> getCategories(RegisteredBookSource source);
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    int page = 1,
    int pageSize = 20,
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
}

class ReadingSourceBackend implements ReadingSourceBackendPort {
  ReadingSourceBackend(
    this._runtime, {
    Future<bool> Function()? additionalProtocolsEnabled,
  }) : _additionalProtocolsEnabled =
           additionalProtocolsEnabled ?? _loadAdditionalProtocolsEnabled;

  final SourceRuntime Function() _runtime;
  final Future<bool> Function() _additionalProtocolsEnabled;

  @override
  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource source,
  ) async {
    await _ensureEnabled();
    return _runtime().loadLoginFields(source);
  }

  @override
  Future<void> loginSource(
    RegisteredBookSource source,
    Map<String, String> values,
  ) async {
    await _ensureEnabled();
    await _runtime().login(source, values);
  }

  @override
  Future<void> clearSourceLogin(RegisteredBookSource source) async {
    await _ensureEnabled();
    await _runtime().clearLoginSession(source);
  }

  @override
  Future<BookSourceSearchPage> search(
    RegisteredBookSource source,
    String query, {
    int page = 1,
    int pageSize = 20,
    BookDownloadCancellation? cancellation,
  }) async {
    await _ensureEnabled();
    return _runtime().search(
      source,
      query,
      page: page,
      pageSize: pageSize,
      cancellation: cancellation,
    );
  }

  @override
  Future<List<BookSourceCategory>> getCategories(
    RegisteredBookSource source,
  ) async {
    await _ensureEnabled();
    return _runtime().getExploreCategories(source);
  }

  @override
  Future<BookSourceSearchPage> browse(
    RegisteredBookSource source, {
    String? category,
    int page = 1,
    int pageSize = 20,
  }) async {
    await _ensureEnabled();
    return _runtime().browse(
      source,
      category: category,
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<BookSourceBook> getBook(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    await _ensureEnabled();
    return _runtime().getBook(source, bookId, sourceVariables: sourceVariables);
  }

  @override
  Future<List<BookSourceChapter>> getChapters(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
  }) async {
    await _ensureEnabled();
    return _runtime().getChapters(
      source,
      bookId,
      sourceVariables: sourceVariables,
    );
  }

  @override
  Future<List<BookSourceChapter>> getChaptersForDownload(
    RegisteredBookSource source,
    String bookId, {
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    await _ensureEnabled();
    final chapters = await _runtime().getChapters(
      source,
      bookId,
      sourceVariables: sourceVariables,
    );
    cancellation?.throwIfCancelled();
    return chapters;
  }

  @override
  Future<BookSourceChapterContent> getChapterContent(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
  }) async {
    await _ensureEnabled();
    return _runtime().getChapterContent(
      source,
      bookId: bookId,
      chapterId: chapterId,
      sourceVariables: sourceVariables,
    );
  }

  @override
  Future<BookSourceChapterContent> getChapterContentForDownload(
    RegisteredBookSource source, {
    required String bookId,
    required String chapterId,
    Map<String, String> sourceVariables = const {},
    BookDownloadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    await _ensureEnabled();
    final content = await _runtime().getChapterContent(
      source,
      bookId: bookId,
      chapterId: chapterId,
      sourceVariables: sourceVariables,
    );
    cancellation?.throwIfCancelled();
    return content;
  }

  Future<void> _ensureEnabled() async {
    if (!await _additionalProtocolsEnabled()) {
      throw const BookSourceProtocolException(
        'Additional source protocols are disabled in advanced settings.',
      );
    }
  }

  static Future<bool> _loadAdditionalProtocolsEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(additionalSourceProtocolsPreferenceKey) == true;
  }
}
