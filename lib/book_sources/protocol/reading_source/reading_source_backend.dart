import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/core/app_settings_service.dart';
import '../../models/registered_book_source.dart';
import '../../services/book_download_cancellation.dart';
import '../../services/book_source_chapter_cache.dart';
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
    this._chapterCache = const BookSourceChapterCache(),
    Future<bool> Function()? additionalProtocolsEnabled,
  }) : _additionalProtocolsEnabled =
           additionalProtocolsEnabled ?? _loadAdditionalProtocolsEnabled;

  static const _cacheAuthRevisionPrefix =
      'reading_source_chapter_cache_auth_revision_v1:';

  final SourceRuntime Function() _runtime;
  final BookSourceChapterCache _chapterCache;
  final Future<bool> Function() _additionalProtocolsEnabled;
  final Map<String, int> _cacheAuthRevisions = {};

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
    await _bumpCacheAuthRevision(source.id);
  }

  @override
  Future<void> clearSourceLogin(RegisteredBookSource source) async {
    await _ensureEnabled();
    await _runtime().clearLoginSession(source);
    await _bumpCacheAuthRevision(source.id);
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
    return _chapterCache.getChapterCatalogOrLoad(
      sourceId: source.id,
      sourceRevision: await _cacheRevision(source, sourceVariables),
      bookId: bookId,
      loader: () => _runtime().getChapters(
        source,
        bookId,
        sourceVariables: sourceVariables,
      ),
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
    return _chapterCache.getOrLoad(
      sourceId: source.id,
      sourceRevision: await _cacheRevision(source, sourceVariables),
      bookId: bookId,
      chapterId: chapterId,
      loader: () => _runtime().getChapterContent(
        source,
        bookId: bookId,
        chapterId: chapterId,
        sourceVariables: sourceVariables,
      ),
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

  Future<String> _cacheRevision(
    RegisteredBookSource source,
    Map<String, String> sourceVariables,
  ) async {
    final authRevision = await _cacheAuthRevision(source.id);
    final stable = _stableCacheJson({
      'manifestUrl': source.manifestUrl.toString(),
      'apiBaseUrl': source.apiBaseUrl.toString(),
      'protocolVersion': source.protocolVersion,
      'sourceConfig': source.sourceConfig,
      'sourceVariables': sourceVariables,
      'authRevision': authRevision,
    });
    return sha256.convert(utf8.encode(jsonEncode(stable))).toString();
  }

  Future<int> _cacheAuthRevision(String sourceId) async {
    final remembered = _cacheAuthRevisions[sourceId];
    if (remembered != null) return remembered;
    final preferences = await SharedPreferences.getInstance();
    final revision =
        preferences.getInt('$_cacheAuthRevisionPrefix$sourceId') ?? 0;
    _cacheAuthRevisions[sourceId] = revision;
    return revision;
  }

  Future<void> _bumpCacheAuthRevision(String sourceId) async {
    final revision = DateTime.now().microsecondsSinceEpoch;
    _cacheAuthRevisions[sourceId] = revision;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt('$_cacheAuthRevisionPrefix$sourceId', revision);
    } catch (_) {
      // A cache invalidation failure must not turn a successful login into an
      // apparent authentication failure. This runtime still uses the new key.
    }
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

Object? _stableCacheJson(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((left, right) => '${left.key}'.compareTo('${right.key}'));
    return <String, Object?>{
      for (final entry in entries)
        '${entry.key}': _stableCacheJson(entry.value),
    };
  }
  if (value is Iterable) {
    return value.map(_stableCacheJson).toList(growable: false);
  }
  return value;
}
