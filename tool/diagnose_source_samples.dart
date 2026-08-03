import 'dart:async';
import 'dart:io';

import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

enum _ExecutionKind { selector, script, xpath, backgroundWeb }

final class _Candidate {
  const _Candidate(this.source, this.kind, this.fileName);

  final ReadingSourceConfig source;
  final _ExecutionKind kind;
  final String fileName;
}

Future<void> main(List<String> arguments) async {
  final paths = arguments.where((value) => !value.startsWith('--')).toList();
  final perKind = _integerOption(arguments, '--per-kind=', fallback: 3);
  final staticOnly = arguments.contains('--static-only');
  final stageSeconds = _integerOption(
    arguments,
    '--stage-seconds=',
    fallback: 15,
  );
  if (paths.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/diagnose_source_samples.dart '
      '[--per-kind=3] [--stage-seconds=15] <source.json> ...',
    );
    exitCode = 64;
    return;
  }

  final candidates = <_Candidate>[];
  final seen = <String>{};
  final runnableUrls = <String>{};
  var parsedTotal = 0;
  var errorTotal = 0;
  var duplicateTotal = 0;
  const scanner = SourceCompatibilityScanner();
  for (final path in paths) {
    final parsed = parseReadingSources(File(path).readAsStringSync());
    parsedTotal += parsed.sources.length;
    errorTotal += parsed.errors.length;
    duplicateTotal += parsed.duplicates;
    final levels = <SourceCompatibilityLevel, int>{};
    final issues = <SourceCompatibilityIssue, int>{};
    for (final source in parsed.sources) {
      final report = scanner.scan(source);
      levels[report.level] = (levels[report.level] ?? 0) + 1;
      for (final issue in report.issues) {
        issues[issue] = (issues[issue] ?? 0) + 1;
      }
      if (report.canRun) runnableUrls.add(source.url);
      if (!seen.add(source.url) || !report.canRun) {
        continue;
      }
      candidates.add(_Candidate(source, _executionKind(source), path));
    }
    stdout.writeln(
      'IMPORT ${File(path).uri.pathSegments.last}: '
      'sources=${parsed.sources.length} errors=${parsed.errors.length} '
      'duplicates=${parsed.duplicates} '
      'supported=${levels[SourceCompatibilityLevel.supported] ?? 0} '
      'partial=${levels[SourceCompatibilityLevel.partial] ?? 0} '
      'unsupported=${levels[SourceCompatibilityLevel.unsupported] ?? 0}',
    );
    if (issues.isNotEmpty) {
      final entries = issues.entries.toList()
        ..sort((left, right) => right.value.compareTo(left.value));
      stdout.writeln(
        'ISSUES ${File(path).uri.pathSegments.last}: '
        '${entries.map((entry) => '${entry.key.name}=${entry.value}').join(' ')}',
      );
    }
  }
  stdout.writeln(
    'TOTAL sources=$parsedTotal errors=$errorTotal duplicates=$duplicateTotal '
    'unique=${seen.length} runnableUnique=${runnableUrls.length}',
  );
  if (staticOnly) return;
  candidates.sort(
    (left, right) =>
        right.source.lastUpdateTime.compareTo(left.source.lastUpdateTime),
  );

  final selected = <_Candidate>[];
  for (final kind in _ExecutionKind.values) {
    final kindCandidates = candidates
        .where((candidate) => candidate.kind == kind)
        .toList();
    final usedHosts = <String>{};
    for (final path in paths) {
      for (final candidate in kindCandidates.where(
        (candidate) => candidate.fileName == path,
      )) {
        final host = candidate.source.baseUri.host.toLowerCase();
        if (!usedHosts.add(host)) continue;
        selected.add(candidate);
        break;
      }
      if (usedHosts.length >= perKind) break;
    }
    if (usedHosts.length >= perKind) continue;
    for (final candidate in kindCandidates) {
      final host = candidate.source.baseUri.host.toLowerCase();
      if (!usedHosts.add(host)) continue;
      selected.add(candidate);
      if (usedHosts.length >= perKind) break;
    }
  }

  final counts = <String, int>{};
  for (final candidate in selected) {
    final source = candidate.source;
    final registered = source.toRegisteredSource(enabled: true);
    final label = '${candidate.kind.name}/${source.name}';
    final query = _queryFor(source);
    stdout.writeln(
      'START $label file=${File(candidate.fileName).uri.pathSegments.last} '
      'query=$query',
    );
    final runtime = SourceRuntime();
    try {
      try {
        final search = await _withBudget(
          runtime.search(registered, query),
          stageSeconds,
          'search',
        );
        if (search.items.isEmpty) {
          _record(counts, 'search-empty');
          stdout.writeln('FAIL $label stage=search-empty');
          continue;
        }
        final match = search.items.first;
        try {
          final book = await _withBudget(
            runtime.getBook(registered, match.id),
            stageSeconds,
            'detail',
          );
          try {
            final chapters = await _withBudget(
              runtime.getChapters(registered, book.id),
              stageSeconds,
              'catalog',
            );
            if (chapters.isEmpty) {
              _record(counts, 'catalog-empty');
              stdout.writeln('FAIL $label stage=catalog-empty');
              continue;
            }
            try {
              final content = await _withBudget(
                runtime.getChapterContent(
                  registered,
                  bookId: book.id,
                  chapterId: chapters.first.id,
                ),
                stageSeconds,
                'content',
              );
              if (content.content.trim().isEmpty) {
                _record(counts, 'content-empty');
                stdout.writeln('FAIL $label stage=content-empty');
                continue;
              }
              _record(counts, 'pass');
              stdout.writeln(
                'PASS $label chapters=${chapters.length} '
                'content=${content.content.length}',
              );
            } catch (error) {
              _failure(counts, label, 'content', error, source.url);
            }
          } catch (error) {
            _failure(counts, label, 'catalog', error, source.url);
          }
        } catch (error) {
          _failure(counts, label, 'detail', error, source.url);
        }
      } catch (error) {
        _failure(counts, label, 'search', error, source.url);
      }
    } finally {
      runtime.close();
    }
  }

  stdout.writeln(
    'SUMMARY selected=${selected.length} '
    '${counts.entries.map((entry) => '${entry.key}=${entry.value}').join(' ')}',
  );
}

Future<T> _withBudget<T>(Future<T> operation, int seconds, String stage) {
  return operation.timeout(
    Duration(seconds: seconds),
    onTimeout: () => throw TimeoutException('$stage exceeded ${seconds}s'),
  );
}

_ExecutionKind _executionKind(ReadingSourceConfig source) {
  final text = source.raw.values.join('\n').toLowerCase();
  if (text.contains('webview') || text.contains('webjs')) {
    return _ExecutionKind.backgroundWeb;
  }
  if (text.contains('<js>') ||
      text.contains('@js:') ||
      text.contains('java.') ||
      text.contains('source.')) {
    return _ExecutionKind.script;
  }
  if (RegExp(
    r'(^|[@&|])xpath:|(^|[@&|])//[a-z*]',
    multiLine: true,
  ).hasMatch(text)) {
    return _ExecutionKind.xpath;
  }
  return _ExecutionKind.selector;
}

String _queryFor(ReadingSourceConfig source) {
  final checkKeyword = '${source.rule('ruleSearch')['checkKeyWord'] ?? ''}'
      .trim();
  if (checkKeyword.isNotEmpty && checkKeyword.length <= 32) {
    return checkKeyword;
  }
  final label = '${source.name}\n${source.group}'.toLowerCase();
  if (label.contains('日语') || label.contains('日文')) return '転生';
  if (label.contains('英文') || label.contains('english')) {
    return 'Harry Potter';
  }
  return '斗破苍穹';
}

int _integerOption(
  List<String> arguments,
  String prefix, {
  required int fallback,
}) {
  for (final argument in arguments) {
    if (!argument.startsWith(prefix)) continue;
    return int.tryParse(argument.substring(prefix.length)) ?? fallback;
  }
  return fallback;
}

void _failure(
  Map<String, int> counts,
  String label,
  String stage,
  Object error,
  String url,
) {
  _record(counts, stage);
  final cleanError = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
  stdout.writeln('FAIL $label stage=$stage source=$url error=$cleanError');
}

void _record(Map<String, int> counts, String key) {
  counts[key] = (counts[key] ?? 0) + 1;
}
