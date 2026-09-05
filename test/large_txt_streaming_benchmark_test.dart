import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/txt_edit_service.dart';
import 'package:xxread/services/sync/txt_chunk_manifest.dart';

const int _fixtureMiB = int.fromEnvironment(
  'OPEN_READING_LARGE_TXT_MIB',
  defaultValue: 0,
);
const String _fixtureShape = String.fromEnvironment(
  'OPEN_READING_LARGE_TXT_SHAPE',
  defaultValue: 'chapters',
);

void main() {
  test(
    'large TXT load and splice keep memory bounded and surrounding bytes intact',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'open-reading-large-txt-',
      );
      final processBaselineRss = ProcessInfo.currentRss;
      var processPeakRss = processBaselineRss;
      final processRssSampler = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) {
          final current = ProcessInfo.currentRss;
          if (current > processPeakRss) processPeakRss = current;
        },
      );
      try {
        final fixture = File('${root.path}/fixture.txt');
        final history = Directory('${root.path}/history');
        final layout = await _writeFixture(
          fixture,
          bytes: _fixtureMiB * 1024 * 1024,
          noHeadingLongLine: _fixtureShape == 'long-line',
        );
        final originalSize = await fixture.length();
        expect(originalSize, _fixtureMiB * 1024 * 1024);

        final service = TxtEditService(
          historyRootProvider: () async => history,
        );
        final book = Book(
          id: 1,
          title: 'Large fixture',
          filePath: fixture.path,
          format: 'txt',
          totalPages: 1,
        );
        final chunkStore = TxtChunkStore(Directory('${root.path}/chunk-cache'));
        final remoteChunks = Directory('${root.path}/fake-dav-chunks');
        final initialManifest = await _measure(
          () => chunkStore.capture(fixture, textEncoding: 'utf8'),
        );
        final initialTransport = await _measure(
          () => _transferMissingChunks(
            initialManifest.value,
            source: chunkStore,
            destination: remoteChunks,
          ),
        );

        final load = await _measure(() async {
          return service.loadChapter(
            book: book,
            chapterId: 'txt-0',
            prefaceTitle: 'Preface',
          );
        });
        final chapter = load.value;
        expect(chapter.text, contains('TARGET'));
        expect(chapter.text.length, lessThanOrEqualTo(1024 * 1024));
        expect(initialManifest.value.contentSha256, chapter.baseContentHash);

        final oldChapterBytes = utf8.encode(chapter.text).length;
        final oldEnd = layout.bodyStart + oldChapterBytes;
        final prefixBefore = await _hashRange(fixture, 0, layout.bodyStart);
        final suffixBefore = await _hashRange(fixture, oldEnd, originalSize);
        const insertedReplacement = 'EDITED+INSERT';
        final editedText = chapter.text.replaceFirst(
          'TARGET',
          insertedReplacement,
        );

        final save = await _measure(() async {
          return service.saveChapter(
            book: book,
            chapterId: chapter.id,
            prefaceTitle: 'Preface',
            editedText: editedText,
            expectedBaseContentHash: chapter.baseContentHash,
            allowUtf8Conversion: false,
          );
        });

        final editedSize = await fixture.length();
        final newEnd = layout.bodyStart + utf8.encode(editedText).length;
        expect(await _hashRange(fixture, 0, layout.bodyStart), prefixBefore);
        expect(await _hashRange(fixture, newEnd, editedSize), suffixBefore);
        expect(
          editedSize,
          originalSize + utf8.encode(editedText).length - oldChapterBytes,
        );
        expect(load.additionalPeakRss, lessThan(192 * 1024 * 1024));
        expect(save.additionalPeakRss, lessThan(192 * 1024 * 1024));
        final editedManifest = await _measure(
          () => chunkStore.capture(fixture, textEncoding: 'utf8'),
        );
        expect(editedManifest.value.contentSha256, save.value.contentHash);
        final previousChunks = initialManifest.value.chunks
            .map((chunk) => chunk.sha256)
            .toSet();
        final initialMissingReferenceBytes = initialManifest.value
            .missingByteCount(const <String>{});
        final incrementalMissingReferenceBytes = editedManifest.value
            .missingByteCount(previousChunks);
        final incrementalTransport = await _measure(
          () => _transferMissingChunks(
            editedManifest.value,
            source: chunkStore,
            destination: remoteChunks,
          ),
        );
        expect(initialMissingReferenceBytes, originalSize);
        expect(incrementalMissingReferenceBytes, lessThan(8 * 1024 * 1024));
        expect(
          initialTransport.value,
          greaterThanOrEqualTo(originalSize * 0.95),
        );
        expect(incrementalTransport.value, lessThan(8 * 1024 * 1024));
        expect(initialManifest.additionalPeakRss, lessThan(192 * 1024 * 1024));
        expect(editedManifest.additionalPeakRss, lessThan(192 * 1024 * 1024));
        processRssSampler.cancel();

        final metrics = <String, Object?>{
          'fixture_mib': _fixtureMiB,
          'shape': _fixtureShape,
          'file_bytes': originalSize,
          'chapter_bytes': oldChapterBytes,
          'edit_byte_delta':
              utf8.encode(insertedReplacement).length -
              ascii.encode('TARGET').length,
          'process_baseline_rss': processBaselineRss,
          'process_peak_rss': processPeakRss,
          'process_additional_peak_rss': processPeakRss - processBaselineRss,
          'load_elapsed_ms': load.elapsed.inMilliseconds,
          'load_baseline_rss': load.baselineRss,
          'load_peak_rss': load.peakRss,
          'load_additional_peak_rss': load.additionalPeakRss,
          'save_elapsed_ms': save.elapsed.inMilliseconds,
          'save_baseline_rss': save.baselineRss,
          'save_peak_rss': save.peakRss,
          'save_additional_peak_rss': save.additionalPeakRss,
          'initial_manifest_elapsed_ms': initialManifest.elapsed.inMilliseconds,
          'initial_manifest_baseline_rss': initialManifest.baselineRss,
          'initial_manifest_peak_rss': initialManifest.peakRss,
          'initial_manifest_additional_peak_rss':
              initialManifest.additionalPeakRss,
          'edited_manifest_elapsed_ms': editedManifest.elapsed.inMilliseconds,
          'edited_manifest_baseline_rss': editedManifest.baselineRss,
          'edited_manifest_peak_rss': editedManifest.peakRss,
          'edited_manifest_additional_peak_rss':
              editedManifest.additionalPeakRss,
          'initial_missing_chunk_reference_bytes': initialMissingReferenceBytes,
          'incremental_missing_chunk_reference_bytes':
              incrementalMissingReferenceBytes,
          'initial_actual_transport_bytes': initialTransport.value,
          'initial_transport_elapsed_ms':
              initialTransport.elapsed.inMilliseconds,
          'initial_transport_baseline_rss': initialTransport.baselineRss,
          'initial_transport_peak_rss': initialTransport.peakRss,
          'initial_transport_additional_peak_rss':
              initialTransport.additionalPeakRss,
          'incremental_actual_transport_bytes': incrementalTransport.value,
          'incremental_transport_elapsed_ms':
              incrementalTransport.elapsed.inMilliseconds,
          'incremental_transport_baseline_rss':
              incrementalTransport.baselineRss,
          'incremental_transport_peak_rss': incrementalTransport.peakRss,
          'incremental_transport_additional_peak_rss':
              incrementalTransport.additionalPeakRss,
          'reused_chunk_count': editedManifest.value.chunks
              .where((chunk) => previousChunks.contains(chunk.sha256))
              .length,
          'edited_chunk_count': editedManifest.value.chunks.length,
          'content_sha256': save.value.contentHash,
          'surrounding_bytes_unchanged': true,
        };
        // The tool runner extracts this stable marker from flutter test output.
        // ignore: avoid_print
        print('LARGE_TXT_METRICS ${jsonEncode(metrics)}');
      } finally {
        processRssSampler.cancel();
        await root.delete(recursive: true);
      }
    },
    skip: _fixtureMiB <= 0
        ? 'Run through tool/benchmark_large_txt_streaming.dart.'
        : false,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

Future<_FixtureLayout> _writeFixture(
  File file, {
  required int bytes,
  required bool noHeadingLongLine,
}) async {
  if (bytes < 1024 * 1024) throw ArgumentError.value(bytes, 'bytes');
  final sink = file.openWrite();
  var written = 0;
  final header = noHeadingLongLine ? const <int>[] : utf8.encode('第一章\n');
  if (header.isNotEmpty) {
    sink.add(header);
    written += header.length;
  }
  final bodyStart = written;
  final target = ascii.encode('TARGET bounded chapter body ');
  sink.add(target);
  written += target.length;

  final chunk = Uint8List(1024 * 1024);
  if (!noHeadingLongLine) {
    const firstBodyBytes = 64 * 1024;
    await _writeVaried(sink, chunk, firstBodyBytes - target.length);
    written += firstBodyBytes - target.length;
    final divider = utf8.encode('\n第二章\n');
    sink.add(divider);
    written += divider.length;
  }
  await _writeVaried(sink, chunk, bytes - written);
  await sink.flush();
  await sink.close();
  return _FixtureLayout(bodyStart: bodyStart);
}

Future<void> _writeVaried(IOSink sink, Uint8List chunk, int byteCount) async {
  var remaining = byteCount;
  var block = 0;
  var state = 0x13579bdf;
  for (var index = 0; index < chunk.length; index++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    chunk[index] = 0x61 + (state % 26);
  }
  while (remaining > 0) {
    final count = remaining < chunk.length ? remaining : chunk.length;
    for (var region = 0; region < count; region += 64) {
      var marker =
          ((block + 1) * 0x1f123bb5 ^ (region + 1) * 0x45d9f3b) & 0x7fffffff;
      for (var byte = 0; byte < 6 && region + byte < count; byte++) {
        chunk[region + byte] = 0x61 + (marker % 26);
        marker ~/= 26;
      }
    }
    sink.add(
      count == chunk.length ? chunk : Uint8List.sublistView(chunk, 0, count),
    );
    // Drain the view before mutating this reusable buffer for the next block.
    await sink.flush();
    remaining -= count;
    block++;
  }
}

Future<String> _hashRange(File file, int start, int end) async {
  if (end <= start) return sha256.convert(const <int>[]).toString();
  return '${await sha256.bind(file.openRead(start, end)).first}';
}

Future<int> _transferMissingChunks(
  TxtChunkManifest manifest, {
  required TxtChunkStore source,
  required Directory destination,
}) async {
  await destination.create(recursive: true);
  var transferred = 0;
  final visited = <String>{};
  for (final chunk in manifest.chunks) {
    if (!visited.add(chunk.sha256)) continue;
    final remote = File('${destination.path}/${chunk.sha256}.chunk');
    if (await remote.exists()) continue;
    final local = source.fileForHash(chunk.sha256);
    final temporary = File('${remote.path}.part');
    final output = temporary.openWrite();
    await output.addStream(local.openRead());
    await output.flush();
    await output.close();
    await temporary.rename(remote.path);
    transferred += await remote.length();
  }
  return transferred;
}

Future<_Measurement<T>> _measure<T>(Future<T> Function() action) async {
  final baseline = ProcessInfo.currentRss;
  var peak = baseline;
  void sample() {
    final current = ProcessInfo.currentRss;
    if (current > peak) peak = current;
  }

  final timer = Timer.periodic(
    const Duration(milliseconds: 10),
    (_) => sample(),
  );
  final watch = Stopwatch()..start();
  try {
    final value = await action();
    sample();
    watch.stop();
    return _Measurement(
      value: value,
      baselineRss: baseline,
      peakRss: peak,
      elapsed: watch.elapsed,
    );
  } finally {
    timer.cancel();
  }
}

class _FixtureLayout {
  const _FixtureLayout({required this.bodyStart});

  final int bodyStart;
}

class _Measurement<T> {
  const _Measurement({
    required this.value,
    required this.baselineRss,
    required this.peakRss,
    required this.elapsed,
  });

  final T value;
  final int baselineRss;
  final int peakRss;
  final Duration elapsed;

  int get additionalPeakRss => peakRss - baselineRss;
}
