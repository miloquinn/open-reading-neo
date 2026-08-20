import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/core/reader/txt_chapter_parser.dart';

void main() {
  test('problematic multi-megabyte numbered TXT stays in bounded sections', () {
    final source = List.generate(
      70000,
      (index) => '${index + 1}. 这是一段用于验证大文本按范围加载的正文内容。\n',
    ).join();
    expect(utf8.encode(source).length, greaterThan(2 * 1024 * 1024));

    final parsed = parseTxtChapterSections(
      source,
      fallbackTitle: '她不会死',
      prefaceTitle: '前言',
    );
    final sections = splitOversizedTxtSections(source, parsed);

    expect(parsed, hasLength(1));
    expect(sections.length, greaterThan(30));
    expect(sections.first.title, '她不会死');
    expect(
      sections.every(
        (section) => section.bodyEnd - section.bodyStart <= 32 * 1024,
      ),
      isTrue,
    );
    expect(sections.map((section) => section.bodyIn(source)).join(), source);
  });

  test('splits every oversized recognized TXT chapter', () {
    final firstBody = List.filled(20, '第一章很长的正文。').join('\n');
    final secondBody = List.filled(18, '第二章也很长。').join('\n');
    final source = '第1章 开始\n$firstBody\n第2章 继续\n$secondBody';
    final parsed = parseTxtChapterSections(
      source,
      fallbackTitle: '测试书',
      prefaceTitle: '前言',
    );
    final sections = splitOversizedTxtSections(
      source,
      parsed,
      maxCharsPerSection: 64,
    );

    expect(sections.length, greaterThan(2));
    expect(sections.first.id, 'txt-0');
    expect(sections.first.isNeedSplitTitle, isTrue);
    expect(sections.any((section) => section.id == 'txt-0-part-1'), isTrue);
    expect(sections.any((section) => section.id == 'txt-1-part-1'), isTrue);
    expect(
      sections
          .take(sections.length - 1)
          .every((section) => section.bodyEnd - section.bodyStart <= 64),
      isTrue,
    );
    expect(
      sections.map((section) => section.bodyIn(source)).join(),
      '$firstBody$secondBody',
    );
  });
}
