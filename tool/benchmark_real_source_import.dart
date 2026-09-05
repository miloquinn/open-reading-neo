// Opt-in benchmark against user-owned source JSON files. This is intentionally
// outside the regular test suite and never copies the corpus into the repo.
//
// Run with:
// flutter test --no-pub tool/benchmark_real_source_import.dart \
//   --dart-define=OPEN_READING_REAL_SOURCE_BENCHMARK=true \
//   --reporter=expanded
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_engine.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_models.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/services/book_source_registry.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';

const _enabled = bool.fromEnvironment(
  'OPEN_READING_REAL_SOURCE_BENCHMARK',
  defaultValue: false,
);
const _corpusRoot = String.fromEnvironment(
  'OPEN_READING_REAL_SOURCE_ROOT',
  defaultValue: '/Users/xiaoyuan/work/书资源',
);
const _corpusFile = String.fromEnvironment('OPEN_READING_REAL_SOURCE_FILE');
const _compareLegacyMaterialization = bool.fromEnvironment(
  'OPEN_READING_COMPARE_LEGACY_MATERIALIZATION',
  defaultValue: false,
);
const _outputPath = String.fromEnvironment(
  'OPEN_READING_REAL_SOURCE_OUTPUT',
  defaultValue: '.omx/real-source-import/latest.json',
);

void main() {
  test(
    'real source import corpus benchmark',
    () async {
      final files =
          (_corpusFile.isEmpty
                  ? Directory(_corpusRoot)
                        .listSync(recursive: true, followLinks: false)
                        .whereType<File>()
                  : <File>[File(_corpusFile)])
              .where((file) => file.path.toLowerCase().endsWith('.json'))
              .where(
                (file) =>
                    !file.path.split(Platform.pathSeparator).contains('替换规则'),
              )
              .toList(growable: false)
            ..sort((left, right) => left.path.compareTo(right.path));
      expect(
        files,
        isNotEmpty,
        reason: 'No source JSON files found in $_corpusRoot',
      );

      final metrics = <Map<String, Object?>>[];
      for (final file in files) {
        final read = await _measureAsync(file.readAsBytes);
        final bytes = read.value;

        final decode = _measure(() => decodeSourceImportBytes(bytes));
        final parse = _measure(() => parseReadingSourcePayload(decode.value));
        final parsed = parse.value;

        final compatibility = _measure(
          () => [
            for (final source in parsed.candidates)
              const SourceCompatibilityScanner().scan(source),
          ],
        );
        final reports = compatibility.value;

        final candidateBuild = _measure(
          () => [
            for (final entry in parsed.candidates.indexed)
              BookSourceDedupeCandidate(
                index: entry.$1,
                rawConfig: entry.$2.raw,
                compatibilityRank: switch (reports[entry.$1].level) {
                  SourceCompatibilityLevel.supported => 2,
                  SourceCompatibilityLevel.partial => 1,
                  SourceCompatibilityLevel.unsupported => 0,
                },
                runnableCapabilities: entry.$2
                    .toRegisteredSource(compatibilityReport: reports[entry.$1])
                    .capabilities
                    .length,
              ),
          ],
        );
        final dedupe = _measure(
          () => const BookSourceDedupeEngine().analyze(candidateBuild.value),
        );
        final preview = _measure(
          () => SourceImportPreview(
            sources: parsed.candidates,
            errors: parsed.errors,
            sourceUrls: parsed.sourceUrls,
          ),
        );

        final analyzer = BookSourceImportAnalyzer();
        late final _Timed<BookSourceImportAnalysis> full;
        try {
          full = await _measureAsync(() => analyzer.analyzeBytesAsync(bytes));
        } finally {
          analyzer.close();
        }
        final analyzedPreview = full.value.additionalPreview;
        expect(analyzedPreview, isNotNull, reason: file.path);
        final importedPreview = analyzedPreview!;
        final uiConsumption = _measure(
          () => <String, int>{
            'runnableText': importedPreview.runnableTextSources,
            'runnableImage': importedPreview.runnableImageSources,
            'unsupported': importedPreview.unsupported,
          },
        );
        final materialized = await _measureAsync(
          importedPreview.toRegisteredSourcesAsync,
        );
        final legacyMaterialized = _compareLegacyMaterialization
            ? await _measureAsync(
                () => _legacyMapMaterialization(importedPreview),
              )
            : null;

        // This opt-in benchmark is executed by flutter_test even though it
        // lives under tool/, so test-only global reset hooks are appropriate.
        // ignore: invalid_use_of_visible_for_testing_member
        await BookSourceRegistry.resetForTesting();
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        final storage = _MemoryRegistryStorage();
        final registry = BookSourceRegistry(storage: storage);
        final upsert = await _measureAsync(
          () => registry.upsertAll(materialized.value),
        );
        final reloaded = await _measureAsync(
          () => BookSourceRegistry(storage: storage).load(),
        );
        expect(reloaded.value, hasLength(upsert.value.sources.length));
        expect(
          {for (final source in reloaded.value) source.id: source.toJson()},
          {
            for (final source in upsert.value.sources)
              source.id: source.toJson(),
          },
          reason: 'Registry reload differed for ${file.path}',
        );

        final result = <String, Object?>{
          'path': file.path,
          'bytes': bytes.length,
          'decodedShape': switch (decode.value) {
            final List value => 'array:${value.length}',
            final Map value => 'object:${value.length}',
            final value => value.runtimeType.toString(),
          },
          'parsedCandidates': parsed.candidates.length,
          'parseErrors': parsed.errors.length,
          'exactDuplicates': parsed.duplicates,
          'previewSelected': preview.value.sources.length,
          'dedupeGroups': dedupe.value.groups.length,
          ...uiConsumption.value,
          'materializedSources': materialized.value.length,
          'registrySources': upsert.value.sources.length,
          'registryConflicts': upsert.value.conflicted.length,
          'registryStorageBytes': utf8.encode(storage.raw ?? '').length,
          'fileReadMs': read.ms,
          'decodeMs': decode.ms,
          'parseConfigsMs': parse.ms,
          'compatibilityScanMs': compatibility.ms,
          'dedupeCandidateBuildMs': candidateBuild.ms,
          'dedupeAnalyzeMs': dedupe.ms,
          'previewFullSyncMs': preview.ms,
          'analyzerAsyncTotalMs': full.ms,
          'uiSummaryConsumptionMs': uiConsumption.ms,
          'materializeSelectedMs': materialized.ms,
          if (legacyMaterialized != null)
            'legacyMapMaterializeSelectedMs': legacyMaterialized.ms,
          'registryUpsertAllMs': upsert.ms,
          'registryReloadMs': reloaded.ms,
        };
        metrics.add(result);
        stdout.writeln('REAL_SOURCE_IMPORT_METRICS ${jsonEncode(result)}');
      }

      final output = File(_outputPath);
      output.parent.createSync(recursive: true);
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'corpusRoot': _corpusRoot,
          'replacementRuleDirectoriesExcluded': true,
          'networkRequestsPerformed': false,
          'files': metrics,
        }),
      );
    },
    skip: _enabled
        ? false
        : 'Set OPEN_READING_REAL_SOURCE_BENCHMARK=true to use local corpus.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

_Timed<T> _measure<T>(T Function() operation) {
  final watch = Stopwatch()..start();
  final value = operation();
  watch.stop();
  return _Timed(value, watch.elapsedMicroseconds / 1000);
}

Future<_Timed<T>> _measureAsync<T>(Future<T> Function() operation) async {
  final watch = Stopwatch()..start();
  final value = await operation();
  watch.stop();
  return _Timed(value, watch.elapsedMicroseconds / 1000);
}

class _Timed<T> {
  const _Timed(this.value, this.ms);

  final T value;
  final double ms;
}

class _MemoryRegistryStorage implements BookSourceRegistryStorage {
  String? raw;

  @override
  Future<String?> read() async => raw;

  @override
  Future<bool> write(String value) async {
    raw = value;
    return true;
  }
}

Future<List<RegisteredBookSource>> _legacyMapMaterialization(
  SourceImportPreview preview,
) {
  final entries = preview.selectedIndices
      .where((index) => index >= 0 && index < preview.candidates.length)
      .map((index) => (index, preview.candidates[index]))
      .toList(growable: false);
  final request = <String, Object?>{
    'sources': entries.map((entry) => entry.$2.raw).toList(growable: false),
    'reports': entries
        .map((entry) {
          final report = preview.reportFor(entry.$2);
          return <String, Object?>{
            'level': report.level.name,
            'issues': report.issues
                .map((issue) => issue.name)
                .toList(growable: false),
          };
        })
        .toList(growable: false),
  };
  return compute(_legacyMaterializeToMaps, request).then(
    (maps) => maps.map(RegisteredBookSource.fromJson).toList(growable: false),
  );
}

List<Map<String, dynamic>> _legacyMaterializeToMaps(
  Map<String, Object?> request,
) {
  final rawSources = request['sources']! as List;
  final reports = request['reports']! as List;
  return rawSources.indexed
      .map((entry) {
        final source = ReadingSourceConfig.fromJson(
          (entry.$2 as Map).map((key, value) => MapEntry('$key', value)),
        );
        final reportData = reports[entry.$1] as Map;
        final report = SourceCompatibilityReport(
          level: SourceCompatibilityLevel.values.byName(
            '${reportData['level']}',
          ),
          issues: (reportData['issues'] as List)
              .map((issue) => SourceCompatibilityIssue.values.byName('$issue'))
              .toSet(),
        );
        return source.toRegisteredSource(compatibilityReport: report).toJson();
      })
      .toList(growable: false);
}
