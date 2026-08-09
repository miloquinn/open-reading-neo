import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';
import 'package:xxread/pages/book_sources/controllers/book_source_add_controller.dart';

void main() {
  test('suppresses stale URL and byte analyses by generation', () async {
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(analyzer: analyzer);
    final first = controller.analyzeUrl('https://old.example');
    final second = controller.analyzeBytes(Uint8List.fromList([1]));
    analyzer.bytes.complete(BookSourceImportAnalysis.orsp(_source('new')));
    await second;
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('old')));
    await first;

    expect(controller.state.analysis?.sources.single.id, 'new');
    expect(controller.state.loading, isFalse);
    controller.dispose();
  });

  test('clear and dispose suppress late analysis completion', () async {
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(analyzer: analyzer);
    final pending = controller.analyzeUrl('https://late.example');
    controller.clear();
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('late')));
    await pending;
    expect(controller.state.analysis, isNull);

    final disposedAnalyzer = _Analyzer();
    final disposed = BookSourceAddController(analyzer: disposedAnalyzer);
    final disposedPending = disposed.analyzeUrl('https://disposed.example');
    disposed.dispose();
    disposedAnalyzer.url.complete(
      BookSourceImportAnalysis.orsp(_source('disposed')),
    );
    await disposedPending;
    controller.dispose();
  });

  test('commits analyzed sources and reports imported count', () async {
    final registry = _Registry();
    final analyzer = _Analyzer();
    final controller = BookSourceAddController(
      registry: registry,
      analyzer: analyzer,
    );
    final analysis = controller.analyzeUrl('https://source.example');
    analyzer.url.complete(BookSourceImportAnalysis.orsp(_source('source')));
    await analysis;

    final result = await controller.commit();
    expect(result?.sources.single.id, 'source');
    expect(result?.importedCount, 1);
    expect(registry.upserted.single.id, 'source');
    controller.dispose();
  });

  test('closes only factory-owned import services', () {
    final owned = _ImportService();
    final controller = BookSourceAddController(
      importServiceFactory: () => owned,
    );
    controller.analyzeUrl('https://source.example');
    controller.dispose();
    expect(owned.closed, isTrue);

    final borrowed = _ImportService();
    final borrowedController = BookSourceAddController(importService: borrowed);
    borrowedController.analyzeUrl('https://source.example');
    borrowedController.dispose();
    expect(borrowed.closed, isFalse);
  });
}

RegisteredBookSource _source(String id) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/api/'),
  protocolVersion: '1.5',
  languages: const ['en'],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
);

class _Analyzer extends BookSourceImportAnalyzer {
  final Completer<BookSourceImportAnalysis> url = Completer();
  final Completer<BookSourceImportAnalysis> bytes = Completer();

  @override
  Future<BookSourceImportAnalysis> analyzeUrl(String input) => url.future;

  @override
  Future<BookSourceImportAnalysis> analyzeBytesAsync(
    Uint8List bytes, {
    Uri? documentUri,
  }) => this.bytes.future;
}

class _Registry extends BookSourceRegistry {
  List<RegisteredBookSource> upserted = const [];

  @override
  Future<List<RegisteredBookSource>> upsert(RegisteredBookSource source) async {
    upserted = [source];
    return upserted;
  }
}

class _ImportService extends SourceImportService {
  bool closed = false;

  @override
  Future<Uint8List> downloadBytes(String input) =>
      Completer<Uint8List>().future;

  @override
  void close({bool force = true}) {
    closed = true;
    super.close(force: force);
  }
}
