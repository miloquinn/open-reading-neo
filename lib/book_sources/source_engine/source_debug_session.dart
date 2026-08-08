import 'dart:async';

import '../models/registered_book_source.dart';
import '../protocol/book_source_protocol.dart';
import '../services/book_download_cancellation.dart';
import 'source_debug.dart';
import 'source_runtime.dart';

/// Drives a single book source through search → detail → catalog → content
/// on a dedicated [SourceRuntime], recording every request and stage outcome
/// along the way so a source author can see exactly where resolution breaks.
class SourceDebugSession implements SourceDebugRecorder {
  SourceDebugSession(this.source, {SourceRuntime? runtime})
    : runtime = runtime ?? SourceRuntime() {
    this.runtime.debugRecorder = this;
  }

  final RegisteredBookSource source;
  final SourceRuntime runtime;
  final StreamController<SourceDebugEvent> _controller =
      StreamController<SourceDebugEvent>.broadcast();

  BookDownloadCancellation? _cancellation;

  Stream<SourceDebugEvent> get events => _controller.stream;
  bool get isRunning => _cancellation != null && !_cancellation!.isCancelled;

  /// Runs the debug chain for [input]: an HTTP(S) URL is treated as a book
  /// detail page and resolved straight into catalog → content; anything else
  /// is treated as a search keyword and resolved from search onward.
  Future<void> run(String input) async {
    if (isRunning) return;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    final cancellation = BookDownloadCancellation();
    _cancellation = cancellation;
    try {
      if (_looksLikeUrl(trimmed)) {
        await _fromBook(trimmed, const {}, cancellation);
      } else {
        await _fromSearch(trimmed, cancellation);
      }
    } finally {
      if (identical(_cancellation, cancellation)) _cancellation = null;
    }
  }

  void cancel() => _cancellation?.cancel();

  void dispose() {
    cancel();
    runtime.close();
    _controller.close();
  }

  Future<void> _fromSearch(
    String keyword,
    BookDownloadCancellation cancellation,
  ) async {
    final BookSourceSearchPage page;
    try {
      page = await runtime.search(source, keyword, cancellation: cancellation);
    } on Object {
      return;
    }
    final first = page.items.firstOrNull;
    if (first == null || cancellation.isCancelled) return;
    await _fromBook(first.id, first.sourceVariables, cancellation);
  }

  Future<void> _fromBook(
    String bookId,
    Map<String, String> sourceVariables,
    BookDownloadCancellation cancellation,
  ) async {
    final BookSourceBook book;
    try {
      book = await runtime.getBook(
        source,
        bookId,
        sourceVariables: sourceVariables,
      );
    } on Object {
      return;
    }
    if (cancellation.isCancelled) return;
    final List<BookSourceChapter> chapters;
    try {
      chapters = await runtime.getChapters(
        source,
        book.id,
        sourceVariables: book.sourceVariables,
      );
    } on Object {
      return;
    }
    final firstChapter = chapters.firstOrNull;
    if (firstChapter == null || cancellation.isCancelled) return;
    try {
      await runtime.getChapterContent(
        source,
        bookId: book.id,
        chapterId: firstChapter.id,
        sourceVariables: book.sourceVariables,
      );
    } on Object {
      // Already recorded through recordNetwork/stageFailed.
    }
  }

  @override
  void stageStarted(String stage) => _emit(
    SourceDebugEvent(
      kind: SourceDebugEventKind.stageStart,
      stage: stage,
      message: '${stage.toUpperCase()} started',
      timestamp: DateTime.now(),
    ),
  );

  @override
  void stageSucceeded(String stage, String summary) => _emit(
    SourceDebugEvent(
      kind: SourceDebugEventKind.stageSuccess,
      stage: stage,
      message: summary.isEmpty ? '${stage.toUpperCase()} succeeded' : summary,
      timestamp: DateTime.now(),
    ),
  );

  @override
  void stageFailed(String stage, Object error) => _emit(
    SourceDebugEvent(
      kind: SourceDebugEventKind.stageError,
      stage: stage,
      message: '$error',
      error: error,
      timestamp: DateTime.now(),
    ),
  );

  @override
  void recordNetwork({
    required String stage,
    required String method,
    required Uri url,
    int? statusCode,
    String? bodyPreview,
    Object? error,
    Duration? elapsed,
  }) => _emit(
    SourceDebugEvent(
      kind: SourceDebugEventKind.network,
      stage: stage,
      message: error != null
          ? '$method $url failed: $error'
          : '$method $url -> ${statusCode ?? '?'}',
      detail: bodyPreview,
      statusCode: statusCode,
      error: error,
      elapsed: elapsed,
      timestamp: DateTime.now(),
    ),
  );

  void _emit(SourceDebugEvent event) {
    if (!_controller.isClosed) _controller.add(event);
  }
}

bool _looksLikeUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}
