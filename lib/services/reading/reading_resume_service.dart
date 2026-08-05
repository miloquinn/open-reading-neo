// 文件说明：阅读恢复服务，记录进行中的阅读会话，供启动时自动回到上次阅读页面。
// 技术要点：服务层、SharedPreferences；正常关闭阅读器时清除会话，阅读中杀进程则保留，
// 下次启动由 main.dart 消费记录并重新打开书籍（阅读位置由各阅读器自身持久化恢复）。

import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/models/book.dart';

class ReadingResumeSnapshot {
  const ReadingResumeSnapshot({
    required this.bookId,
    this.canonicalLocator,
    this.chapterIndex,
  });

  final int bookId;
  final String? canonicalLocator;
  final int? chapterIndex;

  Book applyTo(Book book) => book.copyWith(
    currentPage: chapterIndex ?? book.currentPage,
    lastCanonicalLocator: canonicalLocator,
  );
}

/// 「启动时回到上次阅读」的会话记录。
///
/// 语义：阅读器打开时记下书库书籍 ID，正常关闭（返回书架）时清除；
/// 应用在阅读中退出/被杀时记录保留，下次启动据此自动回到阅读页。
/// 记录一经启动消费即清除，避免陈旧会话在开关稍后打开时误触发。
class ReadingResumeService {
  ReadingResumeService._();

  /// 设置开关（默认关闭），设置页「阅读设置」读写。
  static const String enabledPreferenceKey = 'autoResumeReadingOnLaunch';

  /// 进行中阅读会话的书库书籍 ID。
  static const String _sessionBookIdKey = 'activeReadingSessionBookId';
  static const String _sessionCanonicalLocatorKey =
      'activeReadingSessionCanonicalLocator';
  static const String _sessionChapterIndexKey =
      'activeReadingSessionChapterIndex';
  static Future<void> _sessionOperations = Future<void>.value();

  static Future<T> _serializeSessionOperation<T>(
    Future<T> Function() operation,
  ) {
    final result = _sessionOperations.then((_) => operation());
    _sessionOperations = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  /// 阅读器进入时调用；[bookId] 为空（书不在书库，例如书源试读）时不记录。
  static Future<void> markReading(int? bookId) {
    if (bookId == null) return Future<void>.value();
    return _serializeSessionOperation(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_sessionBookIdKey) != bookId) {
        await prefs.remove(_sessionCanonicalLocatorKey);
        await prefs.remove(_sessionChapterIndexKey);
      }
      await prefs.setInt(_sessionBookIdKey, bookId);
    });
  }

  /// Records the exact reader position used when the app is restored from a
  /// process death. SQLite remains the durable book record, while this small
  /// session snapshot closes the gap before an in-flight database write wins.
  static Future<void> recordPosition({
    required int? bookId,
    required String canonicalLocator,
    required int chapterIndex,
  }) {
    if (bookId == null) return Future<void>.value();
    return _serializeSessionOperation(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_sessionBookIdKey, bookId);
      await prefs.setString(_sessionCanonicalLocatorKey, canonicalLocator);
      await prefs.setInt(_sessionChapterIndexKey, chapterIndex);
    });
  }

  /// 阅读器正常关闭时调用；只清除自己的记录，避免误清其他阅读器刚写入的会话。
  static Future<void> markClosed(int? bookId) {
    if (bookId == null) return Future<void>.value();
    return _serializeSessionOperation(() async {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_sessionBookIdKey) != bookId) return;
      await prefs.remove(_sessionBookIdKey);
      await prefs.remove(_sessionCanonicalLocatorKey);
      await prefs.remove(_sessionChapterIndexKey);
    });
  }

  /// 启动时消费待恢复的会话：无论开关状态都清除记录（一次性语义），
  /// 仅在开关开启且存在记录时返回书籍 ID。
  static Future<ReadingResumeSnapshot?> takePendingResume() =>
      _serializeSessionOperation(() async {
        final prefs = await SharedPreferences.getInstance();
        final bookId = prefs.getInt(_sessionBookIdKey);
        final canonicalLocator = prefs.getString(_sessionCanonicalLocatorKey);
        final chapterIndex = prefs.getInt(_sessionChapterIndexKey);
        if (bookId != null) {
          await prefs.remove(_sessionBookIdKey);
          await prefs.remove(_sessionCanonicalLocatorKey);
          await prefs.remove(_sessionChapterIndexKey);
        }
        final enabled = prefs.getBool(enabledPreferenceKey) ?? false;
        if (!enabled || bookId == null) return null;
        return ReadingResumeSnapshot(
          bookId: bookId,
          canonicalLocator: canonicalLocator,
          chapterIndex: chapterIndex,
        );
      });

  /// Legacy convenience API for callers that only need the session book ID.
  static Future<int?> takePendingResumeBookId() async =>
      (await takePendingResume())?.bookId;
}
