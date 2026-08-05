part of 'native_reader_page.dart';

List<_NativeChapter> _parseHtmlDocument(String source, String fallbackTitle) {
  final document = html_parser.parse(source);
  final headings = document.body?.querySelectorAll('h1,h2,h3,h4,h5,h6') ?? [];
  if (headings.isEmpty) {
    final text = _extractHtmlParagraphText(document.body?.nodes ?? const []);
    return <_NativeChapter>[
      _NativeChapter(
        id: 'html-0',
        chapterTitle:
            document.querySelector('title')?.text.trim().isNotEmpty == true
            ? document.querySelector('title')!.text.trim()
            : fallbackTitle,
        plainText: text,
        blocks: <_NativeBlock>[_NativeBlock.text(text)],
      ),
    ];
  }
  final chapters = <_NativeChapter>[];
  for (var i = 0; i < headings.length; i++) {
    final heading = headings[i];
    final buffer = StringBuffer('${heading.text.trim()}\n\n');
    var node = heading.nextElementSibling;
    while (node != null &&
        !RegExp(r'^h[1-6]$').hasMatch(node.localName ?? '')) {
      final text = _extractHtmlParagraphText(<html_dom.Node>[node]);
      if (text.isNotEmpty) buffer.writeln('$text\n');
      node = node.nextElementSibling;
    }
    final text = buffer.toString();
    chapters.add(
      _NativeChapter(
        id: heading.id.isNotEmpty ? heading.id : 'html-$i',
        chapterTitle: heading.text.trim(),
        depth:
            int.tryParse(
              (heading.localName ?? 'h1').substring(1),
            )?.clamp(1, 6) ??
            1,
        plainText: text,
        blocks: <_NativeBlock>[_NativeBlock.text(text)],
      ),
    );
  }
  return chapters;
}

List<_NativeChapter> _parseMarkdownDocument(
  String source,
  String fallbackTitle,
  String prefaceTitle,
) {
  final plain = source
      .replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), r'$1')
      .replaceAll(RegExp(r'\[([^\]]+)\]\([^)]*\)'), r'$1')
      .replaceAll(RegExp(r'(^|\s)[*_~`]{1,3}|[*_~`]{1,3}(?=\s|$)'), r'$1');
  return _parseTxtChapters(plain, fallbackTitle, prefaceTitle);
}

List<_NativeChapter> _parseFb2Document(String source, String fallbackTitle) {
  final sections = RegExp(
    r'<section\b[^>]*>(.*?)</section>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(source).toList();
  if (sections.isEmpty) {
    final document = html_parser.parse(source);
    final text = _extractHtmlParagraphText(document.body?.nodes ?? const []);
    return <_NativeChapter>[
      _NativeChapter(
        id: 'fb2-0',
        chapterTitle: fallbackTitle,
        plainText: text,
        blocks: <_NativeBlock>[_NativeBlock.text(text)],
      ),
    ];
  }
  return List<_NativeChapter>.generate(sections.length, (index) {
    final xml = sections[index].group(1) ?? '';
    final titleMatch = RegExp(
      r'<title\b[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(xml);
    final title = titleMatch == null
        ? '$fallbackTitle ${index + 1}'
        : html_parser.parse(titleMatch.group(1)).body?.text.trim() ?? '';
    final bodyXml = titleMatch == null
        ? xml
        : xml.replaceFirst(titleMatch.group(0)!, '');
    final text = _extractHtmlParagraphText(
      html_parser.parseFragment(bodyXml).nodes,
    );
    return _NativeChapter(
      id: 'fb2-$index',
      chapterTitle: title,
      plainText: text,
      blocks: <_NativeBlock>[_NativeBlock.text(text)],
    );
  });
}

const _htmlParagraphTags = <String>{
  'address',
  'article',
  'blockquote',
  'dd',
  'div',
  'dl',
  'dt',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'li',
  'p',
  'section',
  'stanza',
  'subtitle',
  'v',
};

String _extractHtmlParagraphText(Iterable<html_dom.Node> nodes) {
  final output = StringBuffer();

  void walk(Iterable<html_dom.Node> children, {bool preformatted = false}) {
    for (final node in children) {
      if (node is html_dom.Text) {
        output.write(
          preformatted ? node.data : node.data.replaceAll(RegExp(r'\s+'), ' '),
        );
        continue;
      }
      if (node is! html_dom.Element) continue;
      final tag = (node.localName ?? '').toLowerCase();
      if (tag == 'br' || tag == 'empty-line') {
        output.write('\n');
        continue;
      }
      final isParagraph = _htmlParagraphTags.contains(tag);
      if (isParagraph) output.write('\n\n');
      walk(node.nodes, preformatted: preformatted || tag == 'pre');
      if (isParagraph) output.write('\n\n');
    }
  }

  walk(nodes);
  return output
      .toString()
      .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _extractRtfText(Uint8List bytes) {
  final source = latin1.decode(bytes, allowInvalid: true);
  return source
      .replaceAllMapped(
        RegExp(r"\\'([0-9a-fA-F]{2})"),
        (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
      )
      .replaceAll(RegExp(r'\\par[d]?\b'), '\n')
      .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '')
      .replaceAll(RegExp(r'[{}]'), '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String _extractDocxText(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final document = archive.files.cast<ArchiveFile?>().firstWhere(
    (file) => file?.name == 'word/document.xml',
    orElse: () => null,
  );
  if (document == null) {
    throw const FormatException('DOCX document.xml missing');
  }
  final xml = utf8.decode(document.content as List<int>, allowMalformed: true);
  return xml
      .replaceAll(RegExp(r'</w:p>'), '\n')
      .replaceAll(RegExp(r'</w:tab>'), '\t')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

List<_NativeChapter> _parseTxtChapters(
  String text,
  String fallbackTitle,
  String prefaceTitle,
) {
  return parseTxtChapterSections(
        text,
        fallbackTitle: fallbackTitle,
        prefaceTitle: prefaceTitle,
      )
      .map((section) {
        final body = section.bodyIn(text);
        return _NativeChapter(
          id: section.id,
          chapterTitle: section.title,
          plainText: body,
          blocks: <_NativeBlock>[_NativeBlock.text(body)],
          isNeedSplitTitle: section.isNeedSplitTitle,
        );
      })
      .toList(growable: false);
}
