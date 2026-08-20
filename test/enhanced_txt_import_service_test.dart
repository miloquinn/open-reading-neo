import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/books/book_import_isolate_service.dart';
import 'package:xxread/services/books/enhanced_txt_import_service.dart';

void main() {
  group('EnhancedTxtImportService encoding detection', () {
    test('accepts UTF-8 when the detection sample cuts a character', () {
      const sampleSize = 256 * 1024;
      final bytes = Uint8List(sampleSize + 5);

      for (var i = 0; i < sampleSize - 1; i += 3) {
        bytes[i] = 0xE4;
        bytes[i + 1] = 0xB8;
        bytes[i + 2] = 0x89; // U+4E09
      }
      bytes[sampleSize - 1] = 0xE6;
      bytes[sampleSize] = 0xB1;
      bytes[sampleSize + 1] = 0x9F; // U+6C5F
      bytes[sampleSize + 2] = 0xE6;
      bytes[sampleSize + 3] = 0x84;
      bytes[sampleSize + 4] = 0x9F; // U+611F

      final service = EnhancedTxtImportService();
      final result = service.decodeWithResult(bytes);

      expect(service.detectEncoding(bytes), 'utf8');
      expect(result.encoding, 'utf8');
      expect(result.content.endsWith('江感'), isTrue);
    });

    test('recovers from a legacy GBK value persisted for UTF-8 text', () {
      final bytes = Uint8List.fromList(utf8.encode('# 三江感言\n正文'));

      final result = EnhancedTxtImportService().decodeWithResult(
        bytes,
        encodingOverride: 'gbk',
        verifyEncodingOverride: true,
      );

      expect(result.encoding, 'utf8');
      expect(result.content, '# 三江感言\n正文');
    });
  });

  group('TXT import metadata', () {
    test('uses the filename when content has no explicit title', () async {
      final result = await extractTxtMetadataInIsolate(
        MetadataExtractionParams(
          bytes: Uint8List.fromList(utf8.encode('1.\n正文第一段\n正文第二段')),
          fileName: '她不会死.txt',
          extension: 'txt',
          totalByteLength: 3 * 1024 * 1024,
        ),
      );

      expect(result.title, '她不会死');
      expect(result.author, 'Unknown');
      expect(result.estimatedPages, (3 * 1024 * 1024 / 1500).ceil());
    });

    test('keeps explicitly labelled title and author', () async {
      final result = await extractTxtMetadataInIsolate(
        MetadataExtractionParams(
          bytes: Uint8List.fromList(utf8.encode('书名：明确书名\n作者：明确作者\n第一章 正文')),
          fileName: '文件名.txt',
          extension: 'txt',
        ),
      );

      expect(result.title, '明确书名');
      expect(result.author, '明确作者');
    });
  });
}
