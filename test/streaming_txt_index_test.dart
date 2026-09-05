import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/indexed_text_reader.dart';
import 'package:xxread/core/reader/streaming_txt_index.dart';
import 'package:xxread/core/reader/txt_chapter_parser.dart';

void main() {
  late Directory temporary;
  late File source;
  late File cache;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('streaming-txt-index-');
    source = File('${temporary.path}/book.txt');
    cache = File('${temporary.path}/book.utf8');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  Map<String, dynamic> build({String? encoding}) =>
      buildStreamingTxtIndexWorker(<String, dynamic>{
        'sourcePath': source.path,
        'dataPath': cache.path,
        'encoding': encoding,
        'title': '书名',
        'prefaceTitle': '序言',
      });

  test(
    'streaming index preserves legacy chapter ids and bounded text',
    () async {
      final longBody = List<String>.filled(40000, '甲').join();
      final text = '前言文字\r\n第一章 开始\r\n$longBody\r\n第二章 后续\r\n尾声';
      source.writeAsStringSync(text, encoding: utf8);

      final result = build(encoding: 'utf8');
      final actual = result['chapters']! as List;
      final expected = splitOversizedTxtSections(
        text,
        parseTxtChapterSections(text, fallbackTitle: '书名', prefaceTitle: '序言'),
      );

      expect(
        actual.map((raw) => (raw as Map)['id']),
        expected.map((e) => e.id),
      );
      expect(
        actual.map((raw) => (raw as Map)['title']),
        expected.map((e) => e.title),
      );
      for (var index = 0; index < actual.length; index++) {
        final raw = Map<String, dynamic>.from(actual[index] as Map);
        expect(
          await readIndexedUtf8Range(
            path: cache.path,
            startOffset: raw['start']! as int,
            endOffset: raw['end']! as int,
          ),
          expected[index].bodyIn(text),
        );
      }
      expect(result['predominantNewline'], '\r\n');
    },
  );

  for (final encoding in const ['utf16le', 'utf16be']) {
    test(
      'streams explicit no-BOM $encoding without whole-file decoding',
      () async {
        final text = '第一章\n${List<String>.filled(70000, '正文🙂').join()}';
        final bytes = <int>[];
        for (final unit in text.codeUnits) {
          if (encoding == 'utf16le') {
            bytes
              ..add(unit & 0xff)
              ..add(unit >> 8);
          } else {
            bytes
              ..add(unit >> 8)
              ..add(unit & 0xff);
          }
        }
        source.writeAsBytesSync(bytes);

        final result = build(encoding: encoding);

        expect(result['textEncoding'], encoding);
        expect(result['requiresUtf8Conversion'], isTrue);
        expect(result['chapters'], isNotEmpty);
        expect(utf8.decode(cache.readAsBytesSync()), text);
      },
    );
  }

  test('splits a long line without retaining a line-sized buffer', () async {
    source.writeAsStringSync(List<String>.filled(1024 * 1024, 'x').join());

    final result = build(encoding: 'utf8');
    final chapters = result['chapters']! as List;

    expect(chapters, hasLength(32));
    expect((chapters.first as Map)['id'], 'txt-0');
    expect((chapters.last as Map)['id'], 'txt-0-part-31');
  });
}
