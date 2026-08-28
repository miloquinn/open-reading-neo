import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replacement rules use explicit application-owned wiring', () {
    const servicePath = 'lib/services/reader/replace_rule_service.dart';
    final productionFiles = _dartFiles(
      Directory('lib'),
    ).toList(growable: false);
    final singletonReads = <String>[];

    for (final file in productionFiles) {
      final source = file.readAsStringSync();
      if (source.contains('ReplaceRuleService.instance')) {
        singletonReads.add(file.path);
      }
    }

    final serviceSource = File(servicePath).readAsStringSync();
    expect(
      singletonReads,
      isEmpty,
      reason:
          'Replacement-rule consumers must reuse the app-owned service, not '
          'discover a process-global singleton:\n${singletonReads.join('\n')}',
    );
    expect(
      serviceSource,
      isNot(matches(RegExp(r'static\s+final\s+ReplaceRuleService\b'))),
      reason: 'ReplaceRuleService must not own a static singleton instance.',
    );
    expect(
      serviceSource,
      isNot(matches(RegExp(r'ReplaceRuleService\._\s*\('))),
      reason: 'ReplaceRuleService must be constructible by the app root.',
    );

    final constructionFiles = _dartFiles(Directory('lib'))
        .where(
          (file) =>
              file.path != servicePath &&
              RegExp(
                r'\bReplaceRuleService\s*\(',
              ).hasMatch(file.readAsStringSync()),
        )
        .map((file) => file.path)
        .toList(growable: false);
    expect(
      constructionFiles,
      ['lib/main.dart'],
      reason:
          'The app composition root must be the only production owner of a '
          'ReplaceRuleService instance.',
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      matches(
        RegExp(
          r'ChangeNotifierProvider\s*\(\s*create:\s*\(_\)\s*=>\s*'
          r'ReplaceRuleService\(\)\.\.load\(\)',
        ),
      ),
      reason:
          'The root provider must own and initialize the service when it is '
          'created.',
    );
  });
}

Iterable<File> _dartFiles(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));
