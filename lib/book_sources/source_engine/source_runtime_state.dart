import 'source_config.dart';
import 'source_response.dart';

class SourceRuntimeState {
  SourceRuntimeState({
    this.maxRememberedBookStates = 1024,
    this.maxChapters = 30000,
  });

  final int maxRememberedBookStates;
  final int maxChapters;

  final Map<String, Map<String, Object?>> _bookRuleStates = {};
  final Map<String, Map<String, Object?>> _bookEntityContexts = {};
  final Map<String, Map<String, Object?>> _chapterRuleContexts = {};
  final Map<String, SourceResponse> _bookInfoResponses = {};

  Map<String, Object?> ruleStateFor(
    ReadingSourceConfig source,
    String bookId,
    Map<String, String> sourceVariables,
  ) => <String, Object?>{
    ...?_bookRuleStates[bookKey(source, bookId)],
    ...sourceVariables,
  };

  void rememberRuleState(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> state,
  ) {
    if (bookId.trim().isEmpty || state.isEmpty) return;
    _rememberBounded(
      _bookRuleStates,
      bookKey(source, bookId),
      Map<String, Object?>.from(state),
      maxRememberedBookStates,
    );
  }

  Map<String, Object?> bookContext(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> state, {
    required int bookType,
  }) {
    final context = <String, Object?>{
      ...?_bookEntityContexts[bookKey(source, bookId)],
      ...state,
    };
    context['bookUrl'] = bookId;
    context['name'] ??= state['bookName'];
    context['author'] ??= state['bookAuthor'];
    context['type'] =
        int.tryParse('${state['bookType'] ?? ''}') ??
        context['type'] ??
        bookType;
    context['durChapterIndex'] ??= 0;
    context['durChapterTitle'] ??= '';
    return context;
  }

  void rememberBookContext(
    ReadingSourceConfig source,
    String bookId,
    Map<String, Object?> context,
  ) => _rememberBounded(
    _bookEntityContexts,
    bookKey(source, bookId),
    Map<String, Object?>.from(context),
    maxRememberedBookStates,
  );

  Map<String, Object?> chapterContext(
    ReadingSourceConfig source,
    String bookId,
    String chapterId,
  ) => Map<String, Object?>.from(
    _chapterRuleContexts[chapterKey(source, bookId, chapterId)] ?? const {},
  );

  void rememberChapterContext(
    ReadingSourceConfig source,
    String bookId,
    String chapterId,
    Map<String, Object?> context,
  ) => _rememberBounded(
    _chapterRuleContexts,
    chapterKey(source, bookId, chapterId),
    Map<String, Object?>.from(context),
    maxChapters,
  );

  void rememberBookInfoResponse(
    ReadingSourceConfig source,
    String bookId,
    SourceResponse response,
  ) => _rememberBounded(
    _bookInfoResponses,
    bookKey(source, bookId),
    response,
    maxRememberedBookStates,
  );

  SourceResponse? takeBookInfoResponse(
    ReadingSourceConfig source,
    String bookId,
  ) => _bookInfoResponses.remove(bookKey(source, bookId));

  String bookKey(ReadingSourceConfig source, String bookId) =>
      '${source.stableId}\u0000$bookId';

  String chapterKey(
    ReadingSourceConfig source,
    String bookId,
    String chapterId,
  ) => '${source.stableId}\u0000$bookId\u0000$chapterId';

  void clear() {
    _bookRuleStates.clear();
    _bookEntityContexts.clear();
    _chapterRuleContexts.clear();
    _bookInfoResponses.clear();
  }
}

void _rememberBounded<K, V>(Map<K, V> values, K key, V value, int limit) {
  values.remove(key);
  values[key] = value;
  while (values.length > limit) {
    values.remove(values.keys.first);
  }
}
