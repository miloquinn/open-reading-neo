import 'dart:convert';

import 'package:xxread/book_sources/dedupe/book_source_dedupe_engine.dart';
import 'package:xxread/book_sources/dedupe/book_source_dedupe_models.dart';

void main() {
  for (final size in [1000, 10000]) {
    for (final scenario in _Scenario.values) {
      _measure(size, scenario);
    }
  }
}

void _measure(int size, _Scenario scenario) {
  for (var warmup = 0; warmup < 2; warmup++) {
    final candidates = _buildCandidates(size, scenario);
    const BookSourceDedupeEngine().analyze(candidates);
  }

  final buildSamples = <int>[];
  final analyzeSamples = <int>[];
  var groups = 0;
  for (var iteration = 0; iteration < 7; iteration++) {
    final buildWatch = Stopwatch()..start();
    final candidates = _buildCandidates(size, scenario);
    buildWatch.stop();

    final analyzeWatch = Stopwatch()..start();
    final result = const BookSourceDedupeEngine().analyze(candidates);
    analyzeWatch.stop();

    buildSamples.add(buildWatch.elapsedMicroseconds);
    analyzeSamples.add(analyzeWatch.elapsedMicroseconds);
    groups = result.groups.length;
  }

  // ignore: avoid_print
  print(
    '${scenario.name.padRight(15)} n=${size.toString().padLeft(5)} '
    'candidate=${_median(buildSamples).toStringAsFixed(1).padLeft(7)}ms '
    'analyze=${_median(analyzeSamples).toStringAsFixed(1).padLeft(7)}ms '
    'groups=$groups',
  );
}

List<BookSourceDedupeCandidate> _buildCandidates(
  int size,
  _Scenario scenario,
) => List.generate(size, (index) {
  final identityIndex = switch (scenario) {
    _Scenario.unique || _Scenario.queryHeavy => index,
    _Scenario.pairs => index ~/ 2,
    _Scenario.oneGroup => 0,
  };
  final query = scenario == _Scenario.queryHeavy
      ? '?z=9&b=2&utm_source=list&a=1&tag=x&c=3&ref=home&d=4&e=5&f=6'
      : '';
  return BookSourceDedupeCandidate(
    index: index,
    rawConfig: {
      'bookSourceName': 'Source $index',
      'bookSourceUrl': 'https://source-$identityIndex.example/books$query',
      'searchUrl': '/search?q={{key}}',
      'ruleSearch': jsonEncode({
        'bookList': '.book',
        'name': '.name@text',
        'author': '.author@text',
      }),
      'ruleBookInfo': {'name': 'h1@text', 'author': '.author@text'},
      'ruleToc': {'chapterList': '.chapter', 'chapterName': 'a@text'},
      'ruleContent': {'content': '#content@html'},
      'header': {'User-Agent': 'benchmark'},
      'enabled': true,
      'lastUpdateTime': index,
    },
    compatibilityRank: 2,
    runnableCapabilities: 4,
  );
});

double _median(List<int> values) {
  values.sort();
  return values[values.length ~/ 2] / 1000;
}

enum _Scenario { unique, pairs, oneGroup, queryHeavy }
