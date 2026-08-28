import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('core does not depend on presentation modules', () {
    final violations = <String>[];
    for (final file
        in Directory('lib/core')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))) {
      for (final dependency in _dependencies(file.readAsStringSync())) {
        if (_isPresentationDependency(dependency)) {
          violations.add('${file.path} -> $dependency');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Core must stay independent of pages and widgets:\n'
          '${violations.join('\n')}',
    );
  });
}

final _dependencyPattern = RegExp(
  r'''(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

Iterable<String> _dependencies(String source) =>
    _dependencyPattern.allMatches(source).map((match) => match.group(1)!);

bool _isPresentationDependency(String dependency) {
  final normalized = dependency.replaceAll(r'\', '/');
  return normalized.contains('package:xxread/pages/') ||
      normalized.contains('package:xxread/widgets/') ||
      RegExp(r'(^|/)\.\./(?:\.\./)*(?:pages|widgets)/').hasMatch(normalized);
}
