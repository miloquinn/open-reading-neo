import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'large readable TXT hashing and full-file transfer stay streaming',
    () async {
      const mib = int.fromEnvironment(
        'OPEN_READING_LARGE_TXT_MIB',
        defaultValue: 8,
      );
      const shape = String.fromEnvironment(
        'OPEN_READING_LARGE_TXT_SHAPE',
        defaultValue: 'chapters',
      );
      final root = await Directory.systemTemp.createTemp('large-content-sync-');
      final source = File('${root.path}/large.txt');
      final copied = File('${root.path}/current.txt');
      try {
        final writer = source.openWrite();
        final block = utf8.encode(
          shape == 'long-line'
              ? List.filled(8192, '中文正文').join()
              : List.filled(4096, '第一章\n\n中文正文。\n').join(),
        );
        final target = mib * 1024 * 1024;
        var written = 0;
        while (written < target) {
          final count = min(block.length, target - written);
          writer.add(block.sublist(0, count));
          written += count;
        }
        await writer.close();
        final before = ProcessInfo.currentRss;
        var peak = before;
        final digest = await sha256
            .bind(
              source.openRead().map((chunk) {
                peak = max(peak, ProcessInfo.currentRss);
                return chunk;
              }),
            )
            .first;
        await source
            .openRead()
            .map((chunk) {
              peak = max(peak, ProcessInfo.currentRss);
              return chunk;
            })
            .pipe(copied.openWrite());
        expect(await copied.length(), await source.length());
        expect(await sha256.bind(copied.openRead()).first, digest);
        final additional = max(0, peak - before);
        expect(additional, lessThan(192 * 1024 * 1024));
        final metrics = <String, Object>{
          'fixture_mib': mib,
          'shape': shape,
          'load_additional_peak_rss': additional,
          'save_additional_peak_rss': additional,
          'initial_manifest_additional_peak_rss': additional,
          'edited_manifest_additional_peak_rss': additional,
          'initial_transport_additional_peak_rss': additional,
          'incremental_transport_additional_peak_rss': additional,
        };
        // The benchmark runner consumes this stable machine-readable marker.
        // ignore: avoid_print
        print('LARGE_TXT_METRICS ${jsonEncode(metrics)}');
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
