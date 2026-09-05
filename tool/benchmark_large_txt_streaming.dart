import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final cases = <({int mib, String shape})>[
    (mib: 200, shape: 'chapters'),
    (mib: 500, shape: 'chapters'),
    (mib: 200, shape: 'long-line'),
  ];
  final results = <Map<String, dynamic>>[];
  for (final benchmark in cases) {
    stdout.writeln(
      'Running ${benchmark.mib} MiB ${benchmark.shape} in an isolated process...',
    );
    final process = await Process.start('flutter', [
      'test',
      '--no-pub',
      'test/large_txt_streaming_benchmark_test.dart',
      '--reporter=expanded',
      '--dart-define=OPEN_READING_LARGE_TXT_MIB=${benchmark.mib}',
      '--dart-define=OPEN_READING_LARGE_TXT_SHAPE=${benchmark.shape}',
    ], runInShell: true);
    final output = StringBuffer();
    final stdoutDone = process.stdout.transform(utf8.decoder).listen((text) {
      stdout.write(text);
      output.write(text);
    }).asFuture<void>();
    final stderrDone = process.stderr.transform(utf8.decoder).listen((text) {
      stderr.write(text);
      output.write(text);
    }).asFuture<void>();
    final processExitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (processExitCode != 0) exit(processExitCode);
    final marker = RegExp(
      r'LARGE_TXT_METRICS (\{.*\})',
    ).allMatches(output.toString());
    if (marker.isEmpty) {
      stderr.writeln('Benchmark process did not emit metrics.');
      exit(1);
    }
    results.add(
      (jsonDecode(marker.last.group(1)!) as Map).cast<String, dynamic>(),
    );
  }

  final structured = results
      .where((result) => result['shape'] == 'chapters')
      .toList(growable: false);
  final rss200 = _worstAdditionalRss(
    structured.singleWhere((result) => result['fixture_mib'] == 200),
  );
  final rss500 = _worstAdditionalRss(
    structured.singleWhere((result) => result['fixture_mib'] == 500),
  );
  final growth = rss500 - rss200;
  if (growth > 64 * 1024 * 1024) {
    stderr.writeln(
      'Additional peak RSS grew by ${(growth / 1024 / 1024).toStringAsFixed(1)} MiB; '
      'the allowed 200-to-500 MiB growth is 64 MiB.',
    );
    exit(1);
  }
  stdout.writeln(
    'LARGE_TXT_SUMMARY ${jsonEncode({'cases': results, 'structured_200_to_500_additional_rss_growth': growth, 'max_allowed_growth': 64 * 1024 * 1024, 'max_allowed_additional_peak_per_phase': 192 * 1024 * 1024})}',
  );
}

int _worstAdditionalRss(Map<String, dynamic> result) {
  final values = <int>[
    result['load_additional_peak_rss'] as int,
    result['save_additional_peak_rss'] as int,
    result['initial_manifest_additional_peak_rss'] as int,
    result['edited_manifest_additional_peak_rss'] as int,
    result['initial_transport_additional_peak_rss'] as int,
    result['incremental_transport_additional_peak_rss'] as int,
  ];
  return values.reduce((a, b) => a > b ? a : b);
}
