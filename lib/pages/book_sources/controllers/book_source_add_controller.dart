import 'package:flutter/foundation.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_import_analyzer.dart';
import '../../../book_sources/services/book_source_registry.dart';
import '../../../book_sources/source_engine/source_import_service.dart';

@immutable
class BookSourceAddState {
  const BookSourceAddState({
    this.analysis,
    this.loading = false,
    this.error,
    this.generation = 0,
  });

  final BookSourceImportAnalysis? analysis;
  final bool loading;
  final Object? error;
  final int generation;

  BookSourceAddState copyWith({
    Object? analysis = _unchanged,
    bool? loading,
    Object? error = _unchanged,
    int? generation,
  }) {
    return BookSourceAddState(
      analysis: identical(analysis, _unchanged)
          ? this.analysis
          : analysis as BookSourceImportAnalysis?,
      loading: loading ?? this.loading,
      error: identical(error, _unchanged) ? this.error : error,
      generation: generation ?? this.generation,
    );
  }
}

@immutable
class BookSourceAddCommitResult {
  const BookSourceAddCommitResult({
    required this.sources,
    required this.analysis,
    required this.importedCount,
    this.conflictedCount = 0,
  });

  final List<RegisteredBookSource> sources;
  final BookSourceImportAnalysis analysis;
  final int importedCount;

  /// Sources skipped because their id was already registered from a
  /// different origin — a likely id collision, not the same source. Everyone
  /// else in the batch still imports normally.
  final int conflictedCount;
}

const _unchanged = Object();

class BookSourceAddController extends ChangeNotifier {
  BookSourceAddController({
    BookSourceRegistry? registry,
    BookSourceImportAnalyzer? analyzer,
    SourceImportService? importService,
    SourceImportService Function()? importServiceFactory,
  }) : assert(importService == null || importServiceFactory == null),
       _registry = registry ?? BookSourceRegistry(),
       _providedAnalyzer = analyzer,
       _importService = importService,
       _importServiceFactory = importServiceFactory ?? SourceImportService.new,
       _ownsImportService = analyzer == null && importService == null;

  final BookSourceRegistry _registry;
  final BookSourceImportAnalyzer? _providedAnalyzer;
  SourceImportService? _importService;
  final SourceImportService Function() _importServiceFactory;
  final bool _ownsImportService;
  BookSourceImportAnalyzer? _createdAnalyzer;

  BookSourceAddState _state = const BookSourceAddState();
  bool _disposed = false;
  int _generation = 0;

  BookSourceAddState get state => _state;

  BookSourceImportAnalyzer get _analyzer {
    final provided = _providedAnalyzer;
    if (provided != null) return provided;
    return _createdAnalyzer ??= BookSourceImportAnalyzer(
      additionalImporter: _importService ??= _importServiceFactory(),
    );
  }

  Future<void> analyzeUrl(String input) =>
      _analyze(() => _analyzer.analyzeUrl(input));

  Future<void> analyzeBytes(Uint8List bytes) =>
      _analyze(() => _analyzer.analyzeBytesAsync(bytes));

  void clear() {
    final generation = ++_generation;
    _emit(BookSourceAddState(generation: generation));
  }

  void setError(Object error) {
    final generation = ++_generation;
    _emit(BookSourceAddState(error: error, generation: generation));
  }

  Future<BookSourceAddCommitResult?> commit() async {
    final analysis = _state.analysis;
    if (analysis == null || _state.loading) return null;
    final generation = ++_generation;
    _emit(_state.copyWith(loading: true, error: null, generation: generation));
    try {
      late final List<RegisteredBookSource> sources;
      late final int importedCount;
      var conflictedCount = 0;
      if (analysis.kind == BookSourceImportKind.orsp) {
        sources = await _registry.upsert(analysis.sources.single);
        importedCount = 1;
      } else {
        final imported = await analysis.additionalPreview!
            .toRegisteredSourcesAsync();
        final result = await _registry.upsertAll(imported);
        sources = result.sources;
        conflictedCount = result.conflicted.length;
        importedCount = imported.length - conflictedCount;
      }
      if (!_isCurrent(generation)) return null;
      _emit(
        _state.copyWith(loading: false, error: null, generation: generation),
      );
      return BookSourceAddCommitResult(
        sources: List.unmodifiable(sources),
        analysis: analysis,
        importedCount: importedCount,
        conflictedCount: conflictedCount,
      );
    } on Object catch (error) {
      if (!_isCurrent(generation)) return null;
      _emit(
        _state.copyWith(loading: false, error: error, generation: generation),
      );
      return null;
    }
  }

  Future<void> _analyze(
    Future<BookSourceImportAnalysis> Function() operation,
  ) async {
    final generation = ++_generation;
    _emit(BookSourceAddState(loading: true, generation: generation));
    try {
      final analysis = await operation();
      if (!_isCurrent(generation)) return;
      _emit(BookSourceAddState(analysis: analysis, generation: generation));
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      _emit(BookSourceAddState(error: error, generation: generation));
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _emit(BookSourceAddState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (_ownsImportService) _importService?.close();
    super.dispose();
  }
}
