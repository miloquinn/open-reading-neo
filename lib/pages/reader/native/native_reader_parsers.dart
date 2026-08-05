part of 'native_reader_page.dart';

Future<Map<String, dynamic>> _parseEpubChapters(Uint8List bytes) async {
  final epub = await EpubReader.readBook(bytes);
  final result = <Map<String, dynamic>>[];
  final imagesByName = <String, String>{};

  final imageEntries = epub.Content?.Images?.entries;
  if (imageEntries != null) {
    for (final entry in imageEntries) {
      final content = entry.value.Content;
      if (content == null || content.isEmpty) continue;
      final name = path.basename(Uri.decodeFull(entry.key)).toLowerCase();
      imagesByName[name] = base64Encode(content);
    }
  }

  final cssSources = <String>[];
  final cssEntries = epub.Content?.Css?.values;
  if (cssEntries != null) {
    for (final cssFile in cssEntries) {
      cssSources.add(cssFile.Content ?? '');
    }
  }
  final cssRules = _cssRulesFromSources(cssSources);

  // epub.Chapters only covers files that have a navPoint in toc.ncx. Some
  // EPUBs (e.g. color-plate pages exported without TOC entries) put extra
  // XHTML files in the spine that never show up there, so building chapters
  // from epub.Chapters alone silently drops those pages/images entirely.
  // Walk the spine — the actual reading order — instead, and only borrow
  // titles/depth from the NCX tree for files that happen to match one.
  final titleByFile = <String, String>{};
  final depthByFile = <String, int>{};
  void indexNavChapters(List<EpubChapter>? chapters, [int depth = 0]) {
    if (chapters == null) return;
    for (final chapter in chapters) {
      final file = chapter.ContentFileName;
      if (file != null) {
        titleByFile[file] = chapter.Title ?? '';
        depthByFile[file] = depth;
      }
      indexNavChapters(chapter.SubChapters, depth + 1);
    }
  }

  indexNavChapters(epub.Chapters);

  final manifestHrefById = <String, String>{};
  for (final item in epub.Schema?.Package?.Manifest?.Items ?? const []) {
    final id = item.Id;
    final href = item.Href;
    if (id != null && href != null) manifestHrefById[id] = href;
  }

  final htmlContent = epub.Content?.Html;
  final spineFiles = <String>[];
  for (final itemRef in epub.Schema?.Package?.Spine?.Items ?? const []) {
    final href = manifestHrefById[itemRef.IdRef];
    if (href == null) continue;
    if (htmlContent == null || !htmlContent.containsKey(href)) continue;
    spineFiles.add(href);
  }

  for (final href in spineFiles) {
    final decodedHref = Uri.decodeFull(href);
    final chapter = _chapterMapFromHtmlDocument(
      id: decodedHref,
      title: titleByFile[decodedHref] ?? '',
      depth: depthByFile[decodedHref] ?? 0,
      document: html_parser.parse(htmlContent![href]?.Content ?? ''),
      imagesByName: imagesByName,
      cssRules: cssRules,
    );
    if (chapter != null) result.add(chapter);
  }
  return <String, dynamic>{'chapters': result, 'images': imagesByName};
}

/// 把扁平 CSS 文本解析为「选择器 → 声明」查找表（与阅读器的
/// 样式块提取相配的近似解析，不处理嵌套/媒体查询）。
Map<String, String> _cssRulesFromSources(Iterable<String> sources) {
  final cssRules = <String, String>{};
  for (final css in sources) {
    for (final match in RegExp(r'([^{}]+)\{([^{}]+)\}').allMatches(css)) {
      final declarations = match.group(2)?.trim() ?? '';
      for (final selector in (match.group(1) ?? '').split(',')) {
        cssRules[selector.trim().toLowerCase()] = declarations;
      }
    }
  }
  return cssRules;
}

/// 把单个 XHTML 文档转换为章节 map（plainText + 样式/图片 blocks）。
///
/// EPUB 与 Kindle（MOBI/KF8）共用：两者正文都是 HTML，差异只在
/// 图片命名与 CSS 来源，由调用方先行归一化（imagesByName 的值为
/// base64 字符串，图片引用需已重写为可按 basename 命中的文件名）。
Map<String, dynamic>? _chapterMapFromHtmlDocument({
  required String id,
  required String title,
  required int depth,
  required html_dom.Document document,
  required Map<String, String> imagesByName,
  required Map<String, String> cssRules,
}) {
  final blocks = <Map<String, String>>[];
  final plainText = StringBuffer();
  final elements =
      document.body?.querySelectorAll(
        'h1,h2,h3,h4,h5,h6,p,div,section,article,li,dd,dt,blockquote,pre,stanza,v,subtitle,a,img,svg image',
      ) ??
      const <html_dom.Element>[];
  for (final element in elements) {
    final isImage =
        element.localName == 'img' ||
        (element.localName == 'image' && element.namespaceUri != null);
    if (isImage) {
      final src = _epubImageSrc(element);
      if (src == null || src.startsWith('data:')) continue;
      final name = path
          .basename(Uri.decodeFull(src.split('?').first.split('#').first))
          .toLowerCase();
      // 只存图片名，不把 base64 内容内联进每一个块：同一张图（例如页头
      // logo）可能被数千个章节复用，内联会把它的编码内容复制数千份，
      // 拖慢解析并在重建 _NativeBlock 时于主线程重复 base64 解码。真正的
      // 内容由 [_richChaptersFromParsed] 按图片名解码一次、共享给所有引用。
      if (imagesByName.containsKey(name)) {
        blocks.add(<String, String>{
          'type': 'image',
          'content': name,
          'startOffset': '${plainText.length}',
          'endOffset': '${plainText.length}',
        });
      }
      continue;
    }
    if (element.localName == 'a' && _hasEpubTextBlockAncestor(element)) {
      continue;
    }
    // 只取块的"自有文本"（排除嵌套块子树）：querySelectorAll 会同时
    // 命中 blockquote 与其内部的 p，用整棵子树的 text 会导致正文重复。
    //
    // 源 XHTML 常把一个段落的文本折行排版，文本节点里会带着裸换行；
    // 这些换行只是排版折行，不是真正的段落分隔（段落间已由下方的
    // `\n\n` 显式分隔）。除 <pre> 外一律把内部空白（含换行）折叠成
    // 空格，否则会被 normalizeParagraphBreaks 误判成新段落，导致
    // 首行缩进出现在折行处而非每段真正的开头。
    final isPreformatted = element.localName == 'pre';
    final rawText = _epubElementOwnText(element);
    final text = _normalizeEpubElementText(
      rawText,
      preformatted: isPreformatted,
    );
    if (text.isNotEmpty) {
      if (plainText.isNotEmpty) plainText.write('\n\n');
      final startOffset = plainText.length;
      plainText.write(text);
      final tag = (element.localName ?? '').toLowerCase();
      final classes = element.classes
          .map((className) => cssRules['.${className.toLowerCase()}'])
          .whereType<String>();
      final styleSource = <String>[
        cssRules[tag] ?? '',
        ...classes,
        element.attributes['style'] ?? '',
      ].join(';').toLowerCase();
      final headingLevel = tag.startsWith('h')
          ? int.tryParse(tag.substring(1))?.clamp(1, 6)
          : null;
      const headingScales = <int, double>{
        1: 1.75,
        2: 1.5,
        3: 1.3,
        4: 1.18,
        5: 1.1,
        6: 1.05,
      };
      final color = RegExp(
        r'color\s*:\s*([^;]+)',
      ).firstMatch(styleSource)?.group(1)?.trim();
      final block = <String, String>{
        'type': 'text',
        'content': text,
        'startOffset': '$startOffset',
        'endOffset': '${plainText.length}',
        'fontScale': '${headingScales[headingLevel] ?? 1}',
        'bold':
            '${headingLevel != null || tag == 'strong' || tag == 'b' || styleSource.contains('font-weight:bold') || styleSource.contains('font-weight: bold')}',
        'italic':
            '${tag == 'em' || tag == 'i' || styleSource.contains('font-style:italic') || styleSource.contains('font-style: italic')}',
      };
      if (color != null) block['color'] = color;
      blocks.add(block);
    }
  }
  if (blocks.isEmpty) {
    final fallback = _extractHtmlParagraphText(
      document.body?.nodes ?? const [],
    );
    if (fallback.isNotEmpty) {
      plainText.write(fallback);
      blocks.add(<String, String>{
        'type': 'text',
        'content': fallback,
        'startOffset': '0',
        'endOffset': '${fallback.length}',
      });
    }
  }
  if (plainText.isEmpty && blocks.isEmpty) return null;
  return <String, dynamic>{
    'id': id,
    'title': title,
    'depth': depth,
    'plainText': plainText.toString(),
    'blocks': blocks,
  };
}

/// Kindle（MOBI/AZW/AZW3）→ 章节 map 列表，在 compute isolate 中执行。
///
/// KF8 的 skeleton 分段天然就是章节；MOBI7 只有一整段 HTML，按
/// `<mbp:pagebreak>` 切分。图片引用（`recindex` / `kindle:embed`，均为
/// 1-based 块索引）先重写成 KindleUnpack 文件名，再走共用的 HTML
/// 章节转换。DRM 书籍抛 [KindleDrmException]。
Future<Map<String, dynamic>> _parseKindleChapters(Uint8List bytes) async {
  final content = parseKindleContent(bytes);
  final imagesByName = <String, String>{
    for (final entry in content.imagesByName.entries)
      entry.key.toLowerCase(): base64Encode(entry.value),
  };
  final cssRules = _cssRulesFromSources(content.cssParts);

  final sections = <String>[];
  if (content.htmlParts.length == 1) {
    sections.addAll(
      content.htmlParts.single
          .split(RegExp(r'<mbp:pagebreak[^>]*>', caseSensitive: false))
          .where((part) => part.trim().isNotEmpty),
    );
  } else {
    sections.addAll(content.htmlParts);
  }

  final result = <Map<String, dynamic>>[];
  for (var i = 0; i < sections.length; i++) {
    final html = rewriteKindleImageRefs(
      sections[i],
      content.imageNameByBlockIndex,
    );
    final document = html_parser.parse(html);
    // Kindle 没有可靠的 TOC 标签传导到分段这里，用分段内第一个标题
    // 作为章节名；没有标题的分段留空，与无 NCX 条目的 EPUB 行为一致。
    final heading = document.body
        ?.querySelector('h1,h2,h3,h4,h5,h6')
        ?.text
        .trim();
    final chapter = _chapterMapFromHtmlDocument(
      id: 'kindle-$i',
      title: heading ?? '',
      depth: 0,
      document: document,
      imagesByName: imagesByName,
      cssRules: cssRules,
    );
    if (chapter != null) result.add(chapter);
  }
  return <String, dynamic>{'chapters': result, 'images': imagesByName};
}

bool _hasEpubTextBlockAncestor(html_dom.Element element) {
  html_dom.Element? ancestor = element.parent;
  while (ancestor != null) {
    if (_epubTextBlockTags.contains(ancestor.localName)) return true;
    ancestor = ancestor.parent;
  }
  return false;
}

const Set<String> _epubTextBlockTags = <String>{
  'address',
  'article',
  'div',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'p',
  'li',
  'dd',
  'dt',
  'blockquote',
  'pre',
  'section',
  'stanza',
  'subtitle',
  'v',
};

String _normalizeEpubElementText(String rawText, {required bool preformatted}) {
  if (preformatted) {
    return rawText
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n\s*\n+'), '\n\n')
        .trim();
  }
  return rawText
      .split(RegExp(r'[\u000b\u000c\u0085\u2028\u2029]'))
      .map((segment) => segment.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((segment) => segment.isNotEmpty)
      .join('\n\n');
}

/// 收集元素的自有文本：遇到嵌套的文本块子元素时跳过其子树，
/// 该子树的文本由它自己作为独立块处理。
String _epubElementOwnText(html_dom.Element element) {
  final buffer = StringBuffer();
  void visit(html_dom.Node node) {
    for (final child in node.nodes) {
      if (child is html_dom.Element) {
        if (child.localName == 'br') {
          buffer.write('\u2029');
          continue;
        }
        if (_epubTextBlockTags.contains(child.localName)) continue;
        visit(child);
      } else if (child is html_dom.Text) {
        buffer.write(child.data);
      }
    }
  }

  visit(element);
  return buffer.toString();
}

List<Map<String, dynamic>> _parseTxtFileInBackground(
  Map<String, dynamic> arguments,
) {
  final bytes = File(arguments['path'] as String).readAsBytesSync();
  final decoded = EnhancedTxtImportService().decodeWithOverride(
    bytes,
    encodingOverride: arguments['encoding'] as String?,
    verifyEncodingOverride: true,
  );
  final chapters = _parseTxtChapters(
    decoded,
    arguments['title'] as String,
    arguments['prefaceTitle'] as String,
  );
  return chapters
      .map(
        (chapter) => <String, dynamic>{
          'id': chapter.id,
          'title': chapter.title,
          'depth': chapter.depth,
          'plainText': chapter.plainText,
          'isNeedSplitTitle': chapter.isNeedSplitTitle,
        },
      )
      .toList(growable: false);
}

Map<String, dynamic> _indexTxtFileInBackground(Map<String, dynamic> arguments) {
  final bytes = File(arguments['path'] as String).readAsBytesSync();
  final decoded = EnhancedTxtImportService().decodeWithOverride(
    bytes,
    encodingOverride: arguments['encoding'] as String?,
    verifyEncodingOverride: true,
  );
  final sections = splitOversizedTxtSections(
    decoded,
    parseTxtChapterSections(
      decoded,
      fallbackTitle: arguments['title'] as String,
      prefaceTitle: arguments['prefaceTitle'] as String,
    ),
  );
  final chapters = <Map<String, dynamic>>[];
  final indexPath = arguments['indexPath'] as String;
  final dataPath = arguments['dataPath'] as String;
  final dataFile = File(dataPath);
  dataFile.parent.createSync(recursive: true);
  final temporaryData = File('$dataPath.tmp');
  final output = temporaryData.openSync(mode: FileMode.write);

  void writeChapter({
    required String id,
    required String title,
    required int startChar,
    required int endChar,
    required bool isNeedSplitTitle,
  }) {
    final startByte = output.positionSync();
    output.writeFromSync(utf8.encode(decoded.substring(startChar, endChar)));
    chapters.add(<String, dynamic>{
      'id': id,
      'title': title,
      'depth': 0,
      'isNeedSplitTitle': isNeedSplitTitle,
      'start': startByte,
      'end': output.positionSync(),
    });
  }

  try {
    for (final section in sections) {
      writeChapter(
        id: section.id,
        title: section.title,
        startChar: section.bodyStart,
        endChar: section.bodyEnd,
        isNeedSplitTitle: section.isNeedSplitTitle,
      );
    }
  } finally {
    output.closeSync();
  }

  if (dataFile.existsSync()) dataFile.deleteSync();
  temporaryData.renameSync(dataPath);

  final result = <String, dynamic>{
    'version': _txtChapterCacheVersion,
    'dataPath': dataPath,
    'chapters': chapters,
  };
  final indexFile = File(indexPath);
  final temporaryIndex = File('$indexPath.tmp');
  temporaryIndex.writeAsStringSync(jsonEncode(result), flush: true);
  if (indexFile.existsSync()) indexFile.deleteSync();
  temporaryIndex.renameSync(indexPath);
  return result;
}

Map<String, dynamic>? _readLargeTxtIndexCache(String indexPath) {
  try {
    final indexFile = File(indexPath);
    if (!indexFile.existsSync()) return null;
    final decoded = jsonDecode(indexFile.readAsStringSync());
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != _txtChapterCacheVersion) {
      return null;
    }
    final dataPath = decoded['dataPath'] as String?;
    final chapters = decoded['chapters'];
    if (dataPath == null || !File(dataPath).existsSync() || chapters is! List) {
      return null;
    }
    return decoded;
  } catch (_) {
    return null;
  }
}

void _deleteOversizedParsedChapterCaches(String cacheDirectoryPath) {
  final directory = Directory(cacheDirectoryPath);
  if (!directory.existsSync()) return;
  for (final entry in directory.listSync().whereType<File>()) {
    if (entry.path.endsWith('.json') &&
        entry.lengthSync() > _largeTxtFileThreshold) {
      entry.deleteSync();
    }
  }
}

List<Map<String, dynamic>>? _readParsedChapterCache(String cachePath) {
  try {
    final file = File(cachePath);
    if (!file.existsSync()) return null;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic> ||
        decoded['version'] != _txtChapterCacheVersion) {
      file.deleteSync();
      return null;
    }
    final chapters = decoded['chapters'];
    if (chapters is! List) return null;
    return chapters
        .map((chapter) => Map<String, dynamic>.from(chapter as Map))
        .toList(growable: false);
  } catch (_) {
    try {
      File(cachePath).deleteSync();
    } catch (_) {}
    return null;
  }
}

void _writeParsedChapterCache(Map<String, dynamic> arguments) {
  final cachePath = arguments['path'] as String;
  final file = File(cachePath);
  file.parent.createSync(recursive: true);
  final temporary = File('$cachePath.tmp');
  temporary.writeAsStringSync(
    jsonEncode(<String, dynamic>{
      'version': _txtChapterCacheVersion,
      'chapters': arguments['chapters'],
    }),
    flush: true,
  );
  if (file.existsSync()) file.deleteSync();
  temporary.renameSync(cachePath);

  final cachedFiles =
      file.parent
          .listSync()
          .whereType<File>()
          .where((entry) => entry.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  for (final stale in cachedFiles.skip(3)) {
    stale.deleteSync();
  }
}

/// 携带面向用户文案的书籍加载异常；错误页直接展示 [message]。
class _ReaderBookLoadException implements Exception {
  const _ReaderBookLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// EPUB/Kindle 等富文本管线的解析结果（`{'chapters': [...], 'images': {name:
/// base64}}`，见 [_parseEpubChapters]/[_parseKindleChapters]）→
/// [_NativeChapter]（保留样式与图片块）。
///
/// 每张图片的 base64 只在这里按名字解码一次并在所有引用它的章节间共享——
/// 图片内容不会像章节文本那样逐块内联，避免一张被数千个章节复用的页头图
/// 被重复解码数千次。
List<_NativeChapter> _richChaptersFromParsed(Map<String, dynamic> parsed) {
  final imagesByName = Map<String, String>.from(
    parsed['images'] as Map? ?? const {},
  );
  final decodedImages = <String, Uint8List>{};
  Uint8List? resolveImage(String name) {
    final cached = decodedImages[name];
    if (cached != null) return cached;
    final encoded = imagesByName[name];
    if (encoded == null) return null;
    final decoded = base64Decode(encoded);
    decodedImages[name] = decoded;
    return decoded;
  }

  final chapters = parsed['chapters'] as List<dynamic>? ?? const [];
  return chapters
      .map((chapter) => Map<String, dynamic>.from(chapter as Map))
      .map(
        (chapter) => _NativeChapter(
          id: chapter['id'] as String? ?? '',
          chapterTitle: chapter['title'] as String? ?? '',
          depth: chapter['depth'] as int? ?? 0,
          plainText: chapter['plainText'] as String? ?? '',
          blocks: (chapter['blocks'] as List<dynamic>)
              .map(
                (block) => _NativeBlock.fromMap(
                  Map<String, String>.from(block as Map),
                  resolveImage: resolveImage,
                ),
              )
              .toList(growable: false),
        ),
      )
      .toList(growable: false);
}

_NativeChapter _nativeChapterFromMap(
  Map<String, dynamic> chapter, {
  String bookTitle = '',
}) {
  final text = chapter['plainText'] as String? ?? '';
  return _NativeChapter(
    id: chapter['id'] as String? ?? '',
    chapterTitle: chapter['title'] as String? ?? '',
    depth: chapter['depth'] as int? ?? 0,
    isNeedSplitTitle: chapter['isNeedSplitTitle'] as bool? ?? false,
    plainText: text,
    blocks: <_NativeBlock>[_NativeBlock.text(text)],
    replaceBookTitle: bookTitle,
  );
}

List<_NativeChapter> _nativeChaptersFromFileIndex(
  Map<String, dynamic> index, {
  String bookTitle = '',
}) {
  final dataPath = index['dataPath'] as String? ?? '';
  final chapters = index['chapters'] as List<dynamic>? ?? const [];
  return chapters
      .map((chapter) {
        final values = Map<String, dynamic>.from(chapter as Map);
        return _NativeChapter.lazyFileText(
          id: values['id'] as String? ?? '',
          chapterTitle: values['title'] as String? ?? '',
          depth: values['depth'] as int? ?? 0,
          isNeedSplitTitle: values['isNeedSplitTitle'] as bool? ?? false,
          dataPath: dataPath,
          startOffset: values['start'] as int? ?? 0,
          endOffset: values['end'] as int? ?? 0,
          replaceBookTitle: bookTitle,
        );
      })
      .toList(growable: false);
}
