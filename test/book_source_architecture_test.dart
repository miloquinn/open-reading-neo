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
      final source = file.readAsStringSync();
      if (_imports(source, 'source_request.dart') ||
          _imports(source, 'sourced_book_widgets.dart')) {
        violations.add(file.path);
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Import leaf modules directly:\n${violations.join('\n')}',
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
    yield* Directory(root)
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
  }
}

bool _imports(String source, String fileName) =>
    RegExp("import\\s+['\"][^'\"]*$fileName['\"]").hasMatch(source);
