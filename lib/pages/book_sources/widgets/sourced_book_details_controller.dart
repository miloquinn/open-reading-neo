import 'package:flutter/foundation.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';
import 'package:xxread/book_sources/services/book_source_gateway.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/library/download_task_controller.dart';

import '../models/sourced_book.dart';

enum SourcedBookDetailsStep {
  details,
  shelfOptions,
  openingReader,
  submitting,
  added,
  alreadyAdded,
  addFailed,
  downloading,
}

@immutable
class SourcedBookDetailsState {
  const SourcedBookDetailsState({
    required this.result,
    this.step = SourcedBookDetailsStep.details,
    this.addError,
    this.downloadTaskId,
    this.downloadTask,
  });

  final SourcedBook result;
  final SourcedBookDetailsStep step;
  final Object? addError;
  final String? downloadTaskId;
  final BookDownloadTask? downloadTask;

  SourcedBookDetailsState copyWith({
    SourcedBook? result,
    SourcedBookDetailsStep? step,
    Object? addError,
    bool clearAddError = false,
    String? downloadTaskId,
    BookDownloadTask? downloadTask,
  }) => SourcedBookDetailsState(
    result: result ?? this.result,
    step: step ?? this.step,
    addError: clearAddError ? null : addError ?? this.addError,
    downloadTaskId: downloadTaskId ?? this.downloadTaskId,
    downloadTask: downloadTask ?? this.downloadTask,
  );
}

abstract interface class SourcedBookShelfPort {
  Future<Book?> findShelfBook({
    required String sourceId,
    required String sourceBookId,
  });

  Future<Book> addOnline({
    required RegisteredBookSource source,
    required BookSourceBook book,
  });
}

class BookSourceShelfPortAdapter implements SourcedBookShelfPort {
  const BookSourceShelfPortAdapter(this.service);

  final BookSourceShelfService service;

  @override
  Future<Book?> findShelfBook({
    required String sourceId,
    required String sourceBookId,
  }) => service.findShelfBook(sourceId: sourceId, sourceBookId: sourceBookId);

  @override
  Future<Book> addOnline({
    required RegisteredBookSource source,
    required BookSourceBook book,
  }) => service.addOnline(source: source, book: book);
}

abstract interface class SourcedBookDownloadPort implements Listenable {
  String enqueue({
    required RegisteredBookSource source,
    required BookSourceBook book,
  });

  BookDownloadTask? taskById(String id);

  bool cancelTask(String id);
}

class DownloadTaskPortAdapter implements SourcedBookDownloadPort {
  const DownloadTaskPortAdapter(this.controller, this.shelfService);

  final DownloadTaskController controller;
  final BookSourceShelfService shelfService;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  bool cancelTask(String id) => controller.cancelTask(id);

  @override
  String enqueue({
    required RegisteredBookSource source,
    required BookSourceBook book,
  }) => controller.enqueueBookDownload(
    source: source,
    book: book,
    shelfService: shelfService,
  );

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  BookDownloadTask? taskById(String id) => controller.taskById(id);
}

class SourcedBookDetailsController extends ChangeNotifier {
  factory SourcedBookDetailsController({
    required SourcedBook initialResult,
    required BookSourceGateway gateway,
    required SourcedBookShelfPort shelf,
    required SourcedBookDownloadPort downloads,
  }) =>
      SourcedBookDetailsController._(initialResult, gateway, shelf, downloads);

  SourcedBookDetailsController._(
    SourcedBook initialResult,
    this._gateway,
    this._shelf,
    this._downloads,
  ) : _state = SourcedBookDetailsState(result: initialResult);

  final BookSourceGateway _gateway;
  final SourcedBookShelfPort _shelf;
  final SourcedBookDownloadPort _downloads;
  SourcedBookDetailsState _state;
  int _detailRevision = 0;
  int _submitRevision = 0;
  bool _submitting = false;
  bool _listeningToDownloads = false;
  bool _disposed = false;

  SourcedBookDetailsState get state => _state;

  Future<void> loadDetails() async {
    final revision = ++_detailRevision;
    final initial = _state.result;
    try {
      final book = await _gateway.getBook(
        initial.source,
        initial.book.id,
        sourceVariables: initial.book.sourceVariables,
      );
      if (!_isCurrentDetail(revision)) return;
      _update(_state.copyWith(result: initial.copyWith(book: book)));
    } catch (_) {
      // The discovery/search summary remains usable when detail loading fails.
    }
  }

  void showShelfOptions() => _setStep(SourcedBookDetailsStep.shelfOptions);

  void showDetails() => _setStep(SourcedBookDetailsStep.details);

  BookSourceBook? beginOpeningReader() {
    if (_disposed || _state.step != SourcedBookDetailsStep.details) return null;
    _setStep(SourcedBookDetailsStep.openingReader);
    return _state.result.book;
  }

  Future<bool> addOnline() async {
    if (_disposed || _submitting) return false;
    _submitting = true;
    final revision = ++_submitRevision;
    _update(
      _state.copyWith(
        step: SourcedBookDetailsStep.submitting,
        clearAddError: true,
      ),
    );
    final result = _state.result;
    try {
      final existing = await _shelf.findShelfBook(
        sourceId: result.source.id,
        sourceBookId: result.book.id,
      );
      if (!_isCurrentSubmit(revision)) return false;
      if (existing == null) {
        await _shelf.addOnline(source: result.source, book: result.book);
      }
      if (!_isCurrentSubmit(revision)) return false;
      _update(
        _state.copyWith(
          step: existing == null
              ? SourcedBookDetailsStep.added
              : SourcedBookDetailsStep.alreadyAdded,
        ),
      );
      return true;
    } catch (error) {
      if (!_isCurrentSubmit(revision)) return false;
      _update(
        _state.copyWith(
          step: SourcedBookDetailsStep.addFailed,
          addError: error,
        ),
      );
      return false;
    } finally {
      if (revision == _submitRevision) _submitting = false;
    }
  }

  Future<bool> retryAddOnline() => addOnline();

  void startDownload() {
    if (_disposed) return;
    final result = _state.result;
    _listenToDownloads();
    final taskId = _downloads.enqueue(source: result.source, book: result.book);
    _update(
      _state.copyWith(
        step: SourcedBookDetailsStep.downloading,
        downloadTaskId: taskId,
        downloadTask: _downloads.taskById(taskId),
      ),
    );
  }

  void cancelDownload() {
    final taskId = _state.downloadTaskId;
    if (_disposed || taskId == null) return;
    _downloads.cancelTask(taskId);
    _handleDownloadUpdate();
  }

  void _listenToDownloads() {
    if (_listeningToDownloads) return;
    _downloads.addListener(_handleDownloadUpdate);
    _listeningToDownloads = true;
  }

  void _handleDownloadUpdate() {
    if (_disposed) return;
    final taskId = _state.downloadTaskId;
    if (taskId == null) return;
    _update(_state.copyWith(downloadTask: _downloads.taskById(taskId)));
  }

  void _setStep(SourcedBookDetailsStep step) {
    if (_disposed) return;
    _update(_state.copyWith(step: step));
  }

  void _update(SourcedBookDetailsState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  bool _isCurrentDetail(int revision) =>
      !_disposed && revision == _detailRevision;

  bool _isCurrentSubmit(int revision) =>
      !_disposed && revision == _submitRevision;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detailRevision += 1;
    _submitRevision += 1;
    if (_listeningToDownloads) {
      _downloads.removeListener(_handleDownloadUpdate);
      _listeningToDownloads = false;
    }
    super.dispose();
  }
}
