import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/networking/book_source_network_policy.dart';
import 'package:xxread/book_sources/services/book_source_import_analyzer.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_import_service.dart';

const _mib = 1024 * 1024;

Uint8List _largeValidSourceBytes() {
  final prefix = utf8.encode(
    '[{"bookSourceName":"Large source",'
    '"bookSourceUrl":"https://large.example",'
    '"searchUrl":"/search?q={{key}}",'
    '"ruleSearch":{"bookList":".book"},'
    '"ruleToc":{"chapterList":".chapter"},'
    '"ruleContent":{"content":"#content"},'
    '"bookSourceComment":"',
  );
  final suffix = utf8.encode('"}]');
  final bytes = Uint8List(prefix.length + 70 * _mib + suffix.length);
  bytes.setRange(0, prefix.length, prefix);
  bytes.fillRange(prefix.length, prefix.length + 70 * _mib, 0x61);
  bytes.setRange(prefix.length + 70 * _mib, bytes.length, suffix);
  return bytes;
}

Uint8List _sourceListBytes(int count) {
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        List.generate(
          count,
          (index) => {
            'bookSourceName': 'Source $index',
            'bookSourceUrl': 'https://source-$index.example',
          },
          growable: false,
        ),
      ),
    ),
  );
}

String _parseLargeSourceSynchronously(Uint8List bytes) {
  final service = SourceImportService();
  try {
    return service.parseBytes(bytes).sources.single.name;
  } finally {
    service.close();
  }
}

void main() {
  late Uint8List largeSourceBytes;

  setUpAll(() {
    largeSourceBytes = _largeValidSourceBytes();
  });

  tearDownAll(() {
    largeSourceBytes = Uint8List(0);
  });

  test(
    'parseBytes accepts valid source JSON larger than 64 MiB',
    () {
      expect(_parseLargeSourceSynchronously(largeSourceBytes), 'Large source');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'analyzeBytesAsync accepts valid source JSON larger than 64 MiB',
    () async {
      final analyzer = BookSourceImportAnalyzer();
      try {
        final analysis = await analyzer.analyzeBytesAsync(largeSourceBytes);
        expect(analysis.additionalPreview?.sources.single.name, 'Large source');
      } finally {
        analyzer.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('accepts more than 10000 sources when no limit is requested', () {
    final service = SourceImportService();
    try {
      final preview = service.parseBytes(_sourceListBytes(10001));

      expect(preview.candidates, hasLength(10001));
    } finally {
      service.close();
    }
  });

  test('rejects a source list that exceeds an explicit parser limit', () {
    final input = utf8.decode(_sourceListBytes(11));

    expect(
      () => parseReadingSources(input, maxSources: 10),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('max 10'),
        ),
      ),
    );
  });

  test(
    'downloads a readable response with an oversized content length',
    () async {
      final expected = Uint8List.fromList(utf8.encode('[{"ok":true}]'));
      final dio = Dio()
        ..httpClientAdapter = _ContentLengthAdapter(
          expected,
          declaredLength: 128 * _mib,
        );
      final service = SourceImportService(
        dio: dio,
        systemDio: dio,
        networkPolicy: BookSourceNetworkPolicy(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
      );
      try {
        final downloaded = await service.downloadBytes(
          'https://sources.example/list.json',
        );

        expect(downloaded, orderedEquals(expected));
      } finally {
        service.close();
      }
    },
  );
}

class _ContentLengthAdapter implements HttpClientAdapter {
  _ContentLengthAdapter(this.bytes, {required this.declaredLength});

  final Uint8List bytes;
  final int declaredLength;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      bytes,
      HttpStatus.ok,
      headers: {
        Headers.contentLengthHeader: ['$declaredLength'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
