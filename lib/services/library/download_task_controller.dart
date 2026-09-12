import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_download_cancellation.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/core/background_download_notifier.dart';

enum DownloadTaskState { queued, downloading, completed, failed, cancelled }

@immutable
class BookDownloadTask {
  const BookDownloadTask({
    required this.id,
    required this.source,
    required this.book,
    required this.state,
    this.completed = 0,
    this.total = 0,
    this.downloadedBook,
    this.error,
    this.shelfBook,
    this.updateMode,
    this.sourceUpdateResult,
    this.bookUid,
  });

  final String id;
  final RegisteredBookSource source;
  final BookSourceBook book;
  final DownloadTaskState state;
  final int completed;
  final int total;
  final Book? downloadedBook;
  final Object? error;
  final Book? shelfBook;
  final SourceUpdateMode? updateMode;
  final SourceUpdateResult? sourceUpdateResult;
  final String? bookUid;

  double? get progress => total > 0 ? completed / total : null;

  BookDownloadTask copyWith({
    DownloadTaskState? state,
    int? completed,
    int? total,
    Book? downloadedBook,
    Object? error,
    SourceUpdateResult? sourceUpdateResult,
  }) => BookDownloadTask(
    id: id,
    source: source,
    book: book,
    state: state ?? this.state,
    completed: completed ?? this.completed,
    total: total ?? this.total,
    downloadedBook: downloadedBook ?? this.downloadedBook,
    error: error ?? this.error,
    shelfBook: shelfBook,
    updateMode: updateMode,
    sourceUpdateResult: sourceUpdateResult ?? this.sourceUpdateResult,
    bookUid: bookUid,
  );
}

/// Owns the bounded in-app book download queue while the application runs.
/// Android mirrors active tasks to a foreground service so the same work can
/// continue after the UI is backgrounded.
class DownloadTaskController extends ChangeNotifier {
  DownloadTaskController({this.maxConcurrentDownloads = 2})
    : assert(maxConcurrentDownloads > 0);

  final int maxConcurrentDownloads;
  final List<BookDownloadTask> _tasks = <BookDownloadTask>[];
  final Map<String, BookDownloadCancellation> _cancellations =
      <String, BookDownloadCancellation>{};
  final Map<String, BookSourceShelfService> _shelfServices =
      <String, BookSourceShelfService>{};
  final Set<String> _activeTaskIds = <String>{};
  final Set<String> _ownedServiceTaskIds = <String>{};

  List<BookDownloadTask> get tasks => List.unmodifiable(_tasks);

  bool get hasActiveTasks => _tasks.any(
    (task) =>
        task.state == DownloadTaskState.queued ||
        task.state == DownloadTaskState.downloading,
  );

  BookDownloadTask? taskById(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  String enqueueBookDownload({
    required RegisteredBookSource source,
    required BookSourceBook book,
    required BookSourceShelfService shelfService,
    String? bookUid,
  }) => _enqueue(
    source: source,
    book: book,
    shelfService: shelfService,
    bookUid: bookUid,
  );

  String enqueueSourceUpdate({
    required Book shelfBook,
    required SourceUpdateMode mode,
    required BookSourceShelfService shelfService,
    required String bookUid,
    bool closeServiceWhenDone = false,
  }) => _enqueue(
    source: shelfService.sourceFrom(shelfBook),
    book: shelfService.sourceBookFrom(shelfBook),
    shelfService: shelfService,
    shelfBook: shelfBook,
    updateMode: mode,
    bookUid: bookUid,
    closeServiceWhenDone: closeServiceWhenDone,
  );

  String _enqueue({
    required RegisteredBookSource source,
    required BookSourceBook book,
    required BookSourceShelfService shelfService,
    Book? shelfBook,
    SourceUpdateMode? updateMode,
    String? bookUid,
    bool closeServiceWhenDone = false,
  }) {
    final existing = _tasks.where(
      (task) =>
          task.source.id == source.id &&
          task.book.id == book.id &&
          (task.state == DownloadTaskState.queued ||
              task.state == DownloadTaskState.downloading),
    );
    if (existing.isNotEmpty) {
      if (closeServiceWhenDone &&
          !identical(_shelfServices[existing.first.id], shelfService)) {
        shelfService.close();
      }
      return existing.first.id;
    }

    final id =
        'book:${source.id}:${book.id}:${DateTime.now().microsecondsSinceEpoch}';
    _tasks.insert(
      0,
      BookDownloadTask(
        id: id,
        source: source,
        book: book,
        state: DownloadTaskState.queued,
        shelfBook: shelfBook,
        updateMode: updateMode,
        bookUid: bookUid,
      ),
    );
    _cancellations[id] = BookDownloadCancellation();
    _shelfServices[id] = shelfService;
    if (closeServiceWhenDone) _ownedServiceTaskIds.add(id);
    notifyListeners();
    _scheduleQueuedTasks();
    return id;
  }

  bool cancelTask(String id) {
    final index = _tasks.indexWhere((task) => task.id == id);
    if (index < 0) return false;
    final task = _tasks[index];
    if (task.state != DownloadTaskState.queued &&
        task.state != DownloadTaskState.downloading) {
      return false;
    }
    _cancellations[id]?.cancel();
    _replace(index, task.copyWith(state: DownloadTaskState.cancelled));
    if (task.state == DownloadTaskState.queued) {
      _cancellations.remove(id);
      final service = _shelfServices.remove(id);
      if (_ownedServiceTaskIds.remove(id)) service?.close();
    }
    return true;
  }

  void _scheduleQueuedTasks() {
    while (_activeTaskIds.length < maxConcurrentDownloads) {
      // Tasks are inserted at the front for newest-first display, so select
      // from the back to preserve FIFO execution order.
      final index = _tasks.lastIndexWhere(
        (task) => task.state == DownloadTaskState.queued,
      );
      if (index < 0) return;
      final task = _tasks[index];
      final shelfService = _shelfServices[task.id];
      if (shelfService == null) {
        _replace(
          index,
          task.copyWith(
            state: DownloadTaskState.failed,
            error: StateError('Download service is unavailable.'),
          ),
        );
        continue;
      }
      _activeTaskIds.add(task.id);
      _replace(index, task.copyWith(state: DownloadTaskState.downloading));
      unawaited(_runTask(task.id, shelfService));
    }
  }

  Future<void> _runTask(
    String taskId,
    BookSourceShelfService shelfService,
  ) async {
    final initialIndex = _tasks.indexWhere((task) => task.id == taskId);
    if (initialIndex < 0) {
      _activeTaskIds.remove(taskId);
      _scheduleQueuedTasks();
      return;
    }
    final task = _tasks[initialIndex];
    final cancellation =
        _cancellations[task.id] ??
        (_cancellations[task.id] = BookDownloadCancellation());
    final notificationTask = BackgroundDownloadTask(
      id: task.id,
      kind: BackgroundDownloadKind.book,
      title: task.book.title,
    );
    try {
      await _notify(() => BackgroundDownloadNotifier.begin(notificationTask));
      void onProgress(int completed, int total) {
        final currentIndex = _tasks.indexWhere(
          (candidate) => candidate.id == task.id,
        );
        if (currentIndex < 0 ||
            _tasks[currentIndex].state != DownloadTaskState.downloading) {
          return;
        }
        _replace(
          currentIndex,
          _tasks[currentIndex].copyWith(completed: completed, total: total),
        );
        unawaited(
          _notify(
            () => BackgroundDownloadNotifier.progress(
              notificationTask,
              completed: completed,
              total: total,
            ),
          ),
        );
      }

      SourceUpdateResult? sourceResult;
      final Book downloaded;
      if (task.updateMode != null && task.shelfBook != null) {
        sourceResult = await shelfService.updateDownloadedBook(
          shelfBook: task.shelfBook!,
          mode: task.updateMode!,
          bookUid: task.bookUid,
          cancellation: cancellation,
          onProgress: onProgress,
        );
        downloaded = sourceResult.book;
      } else {
        downloaded = await shelfService.downloadToLocal(
          source: task.source,
          book: task.book,
          bookUid: task.bookUid,
          cancellation: cancellation,
          onProgress: onProgress,
        );
      }
      cancellation.throwIfCancelled();
      final currentIndex = _tasks.indexWhere(
        (candidate) => candidate.id == task.id,
      );
      if (currentIndex >= 0) {
        _replace(
          currentIndex,
          _tasks[currentIndex].copyWith(
            state: DownloadTaskState.completed,
            completed: _tasks[currentIndex].total,
            downloadedBook: downloaded,
            sourceUpdateResult: sourceResult,
          ),
        );
      }
      await _notify(
        () => BackgroundDownloadNotifier.completeBook(
          BackgroundDownloadTask(
            id: task.id,
            kind: BackgroundDownloadKind.book,
            title: task.book.title,
            bookId: downloaded.id,
          ),
        ),
      );
    } on BookDownloadCancelledException {
      final currentIndex = _tasks.indexWhere(
        (candidate) => candidate.id == task.id,
      );
      if (currentIndex >= 0 &&
          _tasks[currentIndex].state != DownloadTaskState.cancelled) {
        _replace(
          currentIndex,
          _tasks[currentIndex].copyWith(state: DownloadTaskState.cancelled),
        );
      }
      await _notify(() => BackgroundDownloadNotifier.cancel(notificationTask));
    } catch (error) {
      final currentIndex = _tasks.indexWhere(
        (candidate) => candidate.id == task.id,
      );
      if (currentIndex >= 0 &&
          _tasks[currentIndex].state != DownloadTaskState.cancelled) {
        _replace(
          currentIndex,
          _tasks[currentIndex].copyWith(
            state: DownloadTaskState.failed,
            error: error,
          ),
        );
      }
      if (currentIndex >= 0 &&
          _tasks[currentIndex].state == DownloadTaskState.cancelled) {
        await _notify(
          () => BackgroundDownloadNotifier.cancel(notificationTask),
        );
      } else {
        await _notify(() => BackgroundDownloadNotifier.fail(notificationTask));
      }
    } finally {
      _activeTaskIds.remove(task.id);
      _cancellations.remove(task.id);
      _shelfServices.remove(task.id);
      if (_ownedServiceTaskIds.remove(task.id)) shelfService.close();
      _scheduleQueuedTasks();
    }
  }

  Future<void> _notify(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Notification permission and platform failures never stop a download.
    }
  }

  void _replace(int index, BookDownloadTask task) {
    _tasks[index] = task;
    notifyListeners();
  }
}
