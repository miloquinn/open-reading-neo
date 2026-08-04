import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/core/online_font_service.dart';

class _ChunkedHttpClientAdapter implements HttpClientAdapter {
  _ChunkedHttpClientAdapter(this.bytes, {this.statusCode = HttpStatus.ok});

  final Uint8List bytes;
  final int statusCode;
  static const int _chunkSize = 1024;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final chunks = <Uint8List>[];
    for (var offset = 0; offset < bytes.length; offset += _chunkSize) {
      final end = (offset + _chunkSize).clamp(0, bytes.length);
      chunks.add(Uint8List.sublistView(bytes, offset, end));
    }
    return ResponseBody(
      Stream<Uint8List>.fromIterable(chunks),
      statusCode,
      headers: <String, List<String>>{
        Headers.contentLengthHeader: <String>['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'downloads, hashes and registers a font without changing results',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'online-font-service-test-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final fontBytes = Uint8List(128 * 1024)
        ..setAll(0, const <int>[0, 1, 0, 0]);
      final dio = Dio()
        ..httpClientAdapter = _ChunkedHttpClientAdapter(fontBytes);
      Uint8List? registeredBytes;
      final service = OnlineFontService(
        supportDirectory: () async => sandbox,
        dio: dio,
        registrar: (family, bytes, style) async {
          registeredBytes = bytes;
        },
      );
      await service.initialize();

      final record = await service.download(
        fontId: 'test_font',
        family: 'TestFont',
        files: <OnlineFontFile>[
          OnlineFontFile(
            url: 'https://cdn.jsdelivr.net/test-font.ttf',
            fileName: 'test_font.ttf',
            size: fontBytes.length,
          ),
        ],
      );

      expect(registeredBytes, fontBytes);
      expect(record.files.single.sha256, sha256.convert(fontBytes).toString());
      expect(record.files.single.size, fontBytes.length);
      expect(service.isDownloaded('test_font'), isTrue);
    },
  );

  test(
    'downloads and inflates one verified font from an official ZIP range',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'online-font-zip-service-test-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final fontBytes = Uint8List(96 * 1024)
        ..setAll(0, const <int>[0, 1, 0, 0]);
      final compressed = Uint8List.fromList(
        ZLibCodec(raw: true).encode(fontBytes),
      );
      final dio = Dio()
        ..httpClientAdapter = _ChunkedHttpClientAdapter(
          compressed,
          statusCode: HttpStatus.partialContent,
        );
      Uint8List? registeredBytes;
      final service = OnlineFontService(
        supportDirectory: () async => sandbox,
        dio: dio,
        registrar: (family, bytes, style) async {
          registeredBytes = bytes;
        },
      );
      await service.initialize();

      final record = await service.download(
        fontId: 'official_zip_font',
        family: 'OfficialZipFont',
        files: <OnlineFontFile>[
          OnlineFontFile(
            url: 'https://developer.huawei.com/fonts.zip',
            fileName: 'official_zip_font.ttf',
            size: fontBytes.length,
            expectedSha256: sha256.convert(fontBytes).toString(),
            zipEntry: OnlineFontZipEntry(
              path: 'fonts/official_zip_font.ttf',
              compressedOffset: 1234,
              compressedSize: compressed.length,
            ),
          ),
        ],
      );

      expect(registeredBytes, fontBytes);
      expect(record.files.single.sha256, sha256.convert(fontBytes).toString());
      expect(record.files.single.size, fontBytes.length);
    },
  );

  test(
    'extracts the verified font when a proxy ignores Range and returns 200',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'online-font-full-zip-service-test-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final fontBytes = Uint8List(96 * 1024)
        ..setAll(0, const <int>[0, 1, 0, 0]);
      final compressed = Uint8List.fromList(
        ZLibCodec(raw: true).encode(fontBytes),
      );
      const compressedOffset = 1234;
      final archiveBytes = Uint8List(compressedOffset + compressed.length + 512)
        ..setRange(
          compressedOffset,
          compressedOffset + compressed.length,
          compressed,
        );
      final dio = Dio()
        ..httpClientAdapter = _ChunkedHttpClientAdapter(archiveBytes);
      Uint8List? registeredBytes;
      final service = OnlineFontService(
        supportDirectory: () async => sandbox,
        dio: dio,
        registrar: (family, bytes, style) async {
          registeredBytes = bytes;
        },
      );
      await service.initialize();

      final record = await service.download(
        fontId: 'official_full_zip_font',
        family: 'OfficialFullZipFont',
        files: <OnlineFontFile>[
          OnlineFontFile(
            url: 'https://developer.huawei.com/fonts.zip',
            fileName: 'official_full_zip_font.ttf',
            size: fontBytes.length,
            expectedSha256: sha256.convert(fontBytes).toString(),
            zipEntry: OnlineFontZipEntry(
              path: 'fonts/official_full_zip_font.ttf',
              compressedOffset: compressedOffset,
              compressedSize: compressed.length,
            ),
          ),
        ],
      );

      expect(registeredBytes, fontBytes);
      expect(record.files.single.sha256, sha256.convert(fontBytes).toString());
      expect(record.files.single.size, fontBytes.length);
    },
  );

  test(
    'rejects an upstream font whose pinned SHA-256 no longer matches',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'online-font-hash-service-test-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final fontBytes = Uint8List(4096)..setAll(0, const <int>[0, 1, 0, 0]);
      final dio = Dio()
        ..httpClientAdapter = _ChunkedHttpClientAdapter(fontBytes);
      final service = OnlineFontService(
        supportDirectory: () async => sandbox,
        dio: dio,
        registrar: (family, bytes, style) async {},
      );
      await service.initialize();

      await expectLater(
        service.download(
          fontId: 'changed_upstream_font',
          family: 'ChangedUpstreamFont',
          files: <OnlineFontFile>[
            OnlineFontFile(
              url: 'https://cdn.jsdelivr.net/changed-font.ttf',
              fileName: 'changed_font.ttf',
              size: fontBytes.length,
              expectedSha256:
                  '0000000000000000000000000000000000000000000000000000000000000000',
            ),
          ],
        ),
        throwsA(
          isA<OnlineFontException>().having(
            (error) => error.code,
            'code',
            OnlineFontErrorCode.fileSignatureInvalid,
          ),
        ),
      );
      expect(service.isDownloaded('changed_upstream_font'), isFalse);
    },
  );
}
