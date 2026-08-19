import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('book-source production files stay within responsibility budgets', () {
    final oversized = _productionFiles()
        .map((file) => (file: file, lines: file.readAsLinesSync().length))
        .where((entry) => entry.lines >= 800)
        .map((entry) => '${entry.file.path}: ${entry.lines}')
        .toList(growable: false);

    expect(
      oversized,
      isEmpty,
      reason:
          'Split files at cohesive responsibility boundaries:\n'
          '${oversized.join('\n')}',
    );
  });

  test('production modules do not import compatibility barrels', () {
    final violations = <String>[];
    for (final file in _productionFiles()) {
      for (final spec in _importSpecs(file.readAsStringSync())) {
        if (_isCompatibilityShimImport(file, spec)) {
          violations.add('${file.path} -> $spec');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Import leaf modules directly:\n${violations.join('\n')}',
    );
  });

  test('cache and network policy live outside services/', () {
    const relocated = {
      'book_source_chapter_cache.dart',
      'book_source_response_cache.dart',
      'book_source_response_cache_io.dart',
      'book_source_response_cache_stub.dart',
      'source_cover_cache.dart',
      'book_source_network_policy.dart',
    };
    final leftover = Directory('lib/book_sources/services')
        .listSync()
        .whereType<File>()
        .where((file) => relocated.contains(file.uri.pathSegments.last))
        .map((file) => file.path)
        .toList(growable: false);
    expect(
      leftover,
      isEmpty,
      reason:
          'Keep cache files in book_sources/caching/ and network policy in '
          'book_sources/networking/:\n${leftover.join('\n')}',
    );

    final staleImport = RegExp(
      r'''import\s+['"][^'"]*/services/(?:book_source_chapter_cache|book_source_response_cache(?:_io|_stub)?|source_cover_cache|book_source_network_policy)\.dart['"]''',
    );
    final staleImports = <String>[];
    for (final file in _scannedDartFiles()) {
      if (staleImport.hasMatch(file.readAsStringSync())) {
        staleImports.add(file.path);
      }
    }
    expect(
      staleImports,
      isEmpty,
      reason:
          'Import caching/ and networking/ leaves, not old services/ paths:\n'
          '${staleImports.join('\n')}',
    );
  });

  test('book-source controllers do not depend on widget implementations', () {
    final controllerDirectory = Directory('lib/pages/book_sources/controllers');
    final violations = controllerDirectory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => file.readAsStringSync().contains('/widgets/'))
        .map((file) => file.path)
        .toList(growable: false);

    expect(
      violations,
      isEmpty,
      reason:
          'Move shared state models outside widgets:\n'
          '${violations.join('\n')}',
    );
  });
}

Iterable<File> _productionFiles() sync* {
  for (final root in const [
    'lib/book_sources',
    'lib/pages/book_sources',
    'lib/pages/reader/book_source',
  ]) {
    yield* _dartFiles(root);
  }
}

Iterable<File> _scannedDartFiles() sync* {
  yield* _dartFiles('lib');
  yield* _dartFiles('test');
}

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

final _importSpec = RegExp(r'''import\s+['"]([^'"]+)['"]''', multiLine: true);

Iterable<String> _importSpecs(String source) =>
    _importSpec.allMatches(source).map((match) => match.group(1)!);

bool _isCompatibilityShimImport(File file, String spec) {
  final normalized = spec.replaceAll(r'\', '/');
  if (normalized.endsWith('/source_request.dart') ||
      normalized == 'source_request.dart' ||
      normalized.endsWith('/sourced_book_widgets.dart') ||
      normalized == 'sourced_book_widgets.dart') {
    return true;
  }

  if (RegExp(
    r'(^|/)source_engine/source_rule_[^/]+\.dart$',
  ).hasMatch(normalized)) {
    return true;
  }
  if (RegExp(
    r'(^|/)source_engine/source_script_[^/]+\.dart$',
  ).hasMatch(normalized)) {
    return true;
  }
  if (RegExp(r'(^|/)\.\./source_rule_[^/]+\.dart$').hasMatch(normalized)) {
    return true;
  }
  if (RegExp(r'(^|/)\.\./source_script_[^/]+\.dart$').hasMatch(normalized)) {
    return true;
  }

  final path = file.path.replaceAll(r'\', '/');
  final inRules = path.contains('/source_engine/rules/');
  final inScripting = path.contains('/source_engine/scripting/');
  if (!inRules && RegExp(r'^source_rule_[^/]+\.dart$').hasMatch(normalized)) {
    return true;
  }
  if (!inScripting &&
      RegExp(r'^source_script_[^/]+\.dart$').hasMatch(normalized)) {
    return true;
  }
  return false;
}
