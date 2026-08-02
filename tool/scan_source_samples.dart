import 'dart:io';

import 'package:xxread/book_sources/source_engine/source_config.dart';

void main(List<String> paths) {
  for (final path in paths) {
    final parsed = parseReadingSources(File(path).readAsStringSync());
    final counts = <SourceCompatibilityLevel, int>{};
    for (final source in parsed.sources) {
      final level = const SourceCompatibilityScanner().scan(source).level;
      counts[level] = (counts[level] ?? 0) + 1;
    }
    stdout.writeln(
      '${path.split('/').last}: parsed=${parsed.sources.length} '
      'errors=${parsed.errors.length} '
      'supported=${counts[SourceCompatibilityLevel.supported] ?? 0} '
      'partial=${counts[SourceCompatibilityLevel.partial] ?? 0} '
      'unsupported=${counts[SourceCompatibilityLevel.unsupported] ?? 0}',
    );
  }
}
