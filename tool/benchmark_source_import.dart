// Synthetic import benchmark; run explicitly, never as a timing assertion in CI.
// flutter test --no-pub tool/benchmark_source_import.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';

void main() {
  for (final sample in [
    (1000, 4096, false),
    (2000, 24576, true),
    (10000, 1024, true),
  ]) {
    test(
      'synthetic import ${sample.$1} / ${sample.$2} bytes / encoded rules ${sample.$3}',
      () async {
        final payload = List.generate(sample.$1, (i) {
          final padding = List.filled(
            sample.$2 ~/ 32,
            'var title = "example title"; // x\n',
          ).join();
          Object rule(Map<String, Object?> value) =>
              sample.$3 ? jsonEncode(value) : value;
          return {
            'bookSourceName': 'Benchmark $i',
            'bookSourceUrl':
                'https://source-${i % (sample.$1 * 4 ~/ 5)}.example',
            'searchUrl': '/search?q={{key}}',
            'jsLib': padding,
            'ruleSearch': rule({
              'bookList': '.book',
              'name': '.name',
              'bookUrl': 'a@href',
            }),
            'ruleBookInfo': rule({'name': 'h1@text'}),
            'ruleToc': rule({
              'chapterList': '.chapter',
              'chapterName': 'a@text',
              'chapterUrl': 'a@href',
            }),
            'ruleContent': rule({'content': '#content@text'}),
          };
        });
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
        final timings = <String, Object>{
          'sources': sample.$1,
          'bytes': bytes.length,
          'encodedRules': sample.$3,
        };
        T measure<T>(String label, T Function() run) {
          final timer = Stopwatch()..start();
          final result = run();
          timings[label] = timer.elapsedMicroseconds / 1000;
          return result;
        }

        final decoded = measure(
          'decodeMs',
          () => jsonDecode(utf8.decode(bytes)),
        );
        final parsed = measure(
          'parseConfigsMs',
          () => parseReadingSourcePayload(decoded),
        );
        final reports = measure(
          'scanMs',
          () => [
            for (final source in parsed.candidates)
              const SourceCompatibilityScanner().scan(source),
          ],
        );
        measure(
          'capabilityMaterializeMs',
          () => [
            for (var i = 0; i < parsed.candidates.length; i++)
              parsed.candidates[i].toRegisteredSource(
                compatibilityReport: reports[i],
              ),
          ],
        );
        final preview = measure(
          'previewIncludingScanMs',
          () => SourceImportPreview(
            sources: parsed.candidates,
            errors: parsed.errors,
          ),
        );
        measure(
          'previewSummaryMs',
          () => [
            preview.runnableTextSources,
            preview.runnableImageSources,
            preview.unsupported,
          ],
        );
        final analyzer = BookSourceImportAnalyzer();
        final total = Stopwatch()..start();
        final asyncResult = await analyzer.analyzeBytesAsync(bytes);
        timings['backgroundFullMs'] = total.elapsedMicroseconds / 1000;
        analyzer.close();
        expect(
          asyncResult.additionalPreview!.sources.length,
          preview.sources.length,
        );
        stdout.writeln('SOURCE_IMPORT_METRICS ${jsonEncode(timings)}');
      },
    );
  }
}
