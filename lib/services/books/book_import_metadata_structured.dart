part of 'book_import_service.dart';

extension _BookImportStructuredMetadata on BookImportService {
  /// Extract FictionBook 2 (FB2) metadata
  Future<EnhancedBookMetadata> _extractFb2Metadata(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      debugPrint('FB2 metadata extraction - using basic XML parsing');

      // 直接使用 XML 解析
      return await _extractFb2MetadataXml(bytes, fileName);
    } catch (e) {
      debugPrint('FB2 metadata extraction failed: $e');
      return _extractBasicMetadata(bytes, fileName);
    }
  }

  /// FB2 XML 基础解析回退方案。
  Future<EnhancedBookMetadata> _extractFb2MetadataXml(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      final xmlContent = utf8.decode(bytes);

      // Parse FB2 XML structure
      String title = fileName.replaceAll(RegExp(r'\.(fb2)$'), '');
      String author = 'Unknown';
      String? description;
      String? language;
      List<String>? tags;
      Uint8List? coverImage;

      // Extract title
      final titleMatch = RegExp(
        r'<book-title[^>]*>(.*?)</book-title>',
        dotAll: true,
      ).firstMatch(xmlContent);
      if (titleMatch != null) {
        title = _stripXmlTags(titleMatch.group(1) ?? '').trim();
      }

      // Extract author (enhanced)
      final authorMatch = RegExp(
        r'<author[^>]*>.*?<first-name[^>]*>(.*?)</first-name>.*?<last-name[^>]*>(.*?)</last-name>.*?</author>',
        dotAll: true,
      ).firstMatch(xmlContent);
      if (authorMatch != null) {
        final firstName = _stripXmlTags(authorMatch.group(1) ?? '').trim();
        final lastName = _stripXmlTags(authorMatch.group(2) ?? '').trim();
        author = '$firstName $lastName'.trim();
      } else {
        // 尝试简单作者匹配
        final simpleAuthorMatch = RegExp(
          r'<author[^>]*>(.*?)</author>',
          dotAll: true,
        ).firstMatch(xmlContent);
        if (simpleAuthorMatch != null) {
          author = _stripXmlTags(simpleAuthorMatch.group(1) ?? '').trim();
        }
      }

      // Extract description (enhanced)
      final descMatch = RegExp(
        r'<annotation[^>]*>(.*?)</annotation>',
        dotAll: true,
      ).firstMatch(xmlContent);
      if (descMatch != null) {
        description = _stripXmlTags(descMatch.group(1) ?? '').trim();
        // 限制描述长度
        if (description.length > 500) {
          description = '${description.substring(0, 497)}...';
        }
      }

      // Extract language
      final langMatch = RegExp(
        r'<lang[^>]*>(.*?)</lang>',
      ).firstMatch(xmlContent);
      if (langMatch != null) {
        language = langMatch.group(1)?.trim();
      }

      // Extract genres as tags
      final genreMatches = RegExp(
        r'<genre[^>]*>(.*?)</genre>',
      ).allMatches(xmlContent);
      if (genreMatches.isNotEmpty) {
        tags = genreMatches
            .map((match) => match.group(1)?.trim() ?? '')
            .where((tag) => tag.isNotEmpty)
            .toList();
      }

      // Try to extract cover image from FB2
      coverImage = await _extractFb2Cover(xmlContent);

      final textContent = _stripXmlTags(xmlContent);
      final estimatedPages = (textContent.length / 1500).ceil().clamp(1, 9999);

      return EnhancedBookMetadata(
        title: title,
        author: author,
        description: description,
        language: language,
        coverImage: coverImage,
        estimatedPages: estimatedPages,
        tags: tags,
        additionalInfo: {
          'format': 'FB2',
          'characterCount': textContent.length,
          'parsedByXml': true,
        },
      );
    } catch (e) {
      debugPrint('FB2 XML metadata extraction failed: $e');
      return _extractBasicMetadata(bytes, fileName);
    }
  }

  /// 从 FB2 文件提取封面图片
  Future<Uint8List?> _extractFb2Cover(String xmlContent) async {
    try {
      // FB2 格式中的封面通常在 <binary> 标签中
      final binaryPattern = RegExp(
        r'<binary[^>]*id\s*=\s*["\x27]([^"\x27]*cover[^"\x27]*)["\x27][^>]*>(.*?)</binary>',
        dotAll: true,
        caseSensitive: false,
      );
      final binaryMatch = binaryPattern.firstMatch(xmlContent);

      if (binaryMatch != null) {
        final base64Content = binaryMatch.group(2)?.trim() ?? '';
        if (base64Content.isNotEmpty) {
          try {
            // 清理base64字符串（移除换行和空格）
            final cleanBase64 = base64Content.replaceAll(RegExp(r'\s+'), '');
            return base64.decode(cleanBase64);
          } catch (e) {
            debugPrint('FB2 封面base64解码失败: $e');
          }
        }
      }

      // 尝试查找其他可能的图片
      final allBinaryMatches = RegExp(
        r"<binary[^>]*>(.*?)</binary>",
        dotAll: true,
      ).allMatches(xmlContent);

      for (final match in allBinaryMatches) {
        final base64Content = match.group(1)?.trim() ?? '';
        if (base64Content.isNotEmpty && base64Content.length > 100) {
          try {
            final cleanBase64 = base64Content.replaceAll(RegExp(r'\s+'), '');
            final imageBytes = base64.decode(cleanBase64);
            if (_isValidImageFormat(imageBytes)) {
              return imageBytes;
            }
          } catch (e) {
            continue; // 尝试下一个
          }
        }
      }

      return null;
    } catch (e) {
      debugPrint('FB2 封面提取失败: $e');
      return null;
    }
  }

  /// Extract MOBI/AZW3 metadata using basic parsing（使用isolate优化）
  Future<EnhancedBookMetadata> _extractMobiMetadata(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      debugPrint('📚 开始MOBI/AZW/AZW3元数据提取: $fileName');

      // 头部解析（PalmDB/EXTH/封面记录切片）本身很轻，但大文件在
      // isolate 里做可避免记录表扫描挤占 UI 帧。
      final kindle = bytes.length > 5 * 1024 * 1024
          ? await compute(parseKindleMetadata, bytes)
          : parseKindleMetadata(bytes);

      final fallbackTitle = fileName.replaceAll(
        RegExp(r'\.(mobi|azw|azw3)$', caseSensitive: false),
        '',
      );
      final title = kindle.title.isNotEmpty ? kindle.title : fallbackTitle;
      final author = kindle.authors.isNotEmpty
          ? kindle.authors.join(', ')
          : 'Unknown';

      // 优先内嵌封面；没有时本地生成默认封面。
      Uint8List? coverImage = kindle.coverImage;
      if (coverImage == null || coverImage.isEmpty) {
        try {
          coverImage = await CoverGenerator.generateTextCover(
            title: title,
            author: author,
            format: 'MOBI',
          );
        } catch (e) {
          debugPrint('❌ MOBI默认封面生成失败: $e');
        }
      }

      // PalmDOC textLength 是未压缩正文字节数，比文件大小更接近真实篇幅。
      final estimatedPages = kindle.textLength > 0
          ? (kindle.textLength / 1500).ceil().clamp(1, 99999)
          : (bytes.length / 3000).ceil().clamp(50, 1000);

      debugPrint(
        '✅ MOBI元数据提取完成: $title / $author'
        '${kindle.hasDrm ? '（DRM 加密，正文不可读）' : ''}',
      );

      return EnhancedBookMetadata(
        title: title,
        author: author,
        description: kindle.description,
        language: kindle.language,
        publisher: kindle.publisher,
        publishDate: kindle.publishedDate,
        isbn: kindle.isbn,
        coverImage: coverImage,
        estimatedPages: estimatedPages,
        tags: kindle.subjects.isNotEmpty ? kindle.subjects : null,
        additionalInfo: {
          'format': 'MOBI/AZW',
          'fileSize': bytes.length,
          'hasDrm': kindle.hasDrm,
        },
      );
    } catch (e) {
      debugPrint('MOBI/AZW3 metadata extraction failed: $e');
      return _extractBasicMobiMetadata(bytes, fileName);
    }
  }

  /// MOBI 元数据基础解析回退方案。
  EnhancedBookMetadata _extractBasicMobiMetadata(
    Uint8List bytes,
    String fileName,
  ) {
    final title = fileName.replaceAll(RegExp(r'\.(mobi|azw|azw3)$'), '');
    final estimatedPages = (bytes.length / 3000).ceil().clamp(50, 1000);

    return EnhancedBookMetadata(
      title: title,
      author: 'Unknown',
      estimatedPages: estimatedPages,
      additionalInfo: {
        'format': fileName.split('.').last.toUpperCase(),
        'fileSize': bytes.length,
        'note': 'Basic metadata extraction fallback',
      },
    );
  }

  /// Extract Comic Book (CBZ/CBR/CBT/CB7) metadata
  Future<EnhancedBookMetadata> _extractComicMetadata(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      // 漫画容器统一按文件头识别：ZIP/TAR（含改名的 CBR/CB7）可解包。
      final extension = fileName.split('.').last.toLowerCase();
      final title = fileName.replaceAll(RegExp(r'\.(cbz|cbr|cbt|cb7)$'), '');

      // For comic books, we can extract some basic info
      String author = 'Unknown';

      // Try to extract info from filename patterns
      final seriesMatch = RegExp(r'^(.+?)\s*#?\d+').firstMatch(title);
      if (seriesMatch != null) {
        author = 'Series: ${seriesMatch.group(1)}';
      }

      // 可解包的容器取真实页数 + 第一页作封面；真 RAR/7z 或字节被
      // 截断时解包会抛错，回退到估算值和生成封面。
      int estimatedPages = extension == 'cbz' ? 25 : 30;
      Uint8List? coverImage;
      try {
        final pages = await compute(indexComicPages, <String, dynamic>{
          'bytes': bytes,
          'ext': extension,
        });
        if (pages.isNotEmpty) {
          estimatedPages = pages.length;
          coverImage = await compute(extractComicPage, <String, dynamic>{
            'bytes': bytes,
            'ext': extension,
            'name': pages.first,
          });
        }
      } catch (e) {
        debugPrint('漫画页索引/封面提取失败，使用回退元数据: $e');
      }

      return EnhancedBookMetadata(
        title: title,
        author: author,
        description: 'Comic book in ${extension.toUpperCase()} format',
        coverImage: coverImage,
        estimatedPages: estimatedPages,
        additionalInfo: {
          'format': extension.toUpperCase(),
          'mediaType': 'comic',
          'isArchive': true,
          'note': 'Comic book archive - contains image files',
        },
      );
    } catch (e) {
      debugPrint('Comic metadata extraction failed: $e');
      return _extractBasicMetadata(bytes, fileName);
    }
  }

  /// Extract RTF metadata
  Future<EnhancedBookMetadata> _extractRtfMetadata(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      final content = utf8.decode(bytes);

      // RTF files contain control codes, extract plain text
      String title = fileName.replaceAll(RegExp(r'\.(rtf)$'), '');
      String author = 'Unknown';

      // Extract title from RTF info if available
      final titleMatch = RegExp(r'\\title\s+([^}]+)').firstMatch(content);
      if (titleMatch != null) {
        title = titleMatch.group(1)?.trim() ?? title;
      }

      // Extract author from RTF info
      final authorMatch = RegExp(r'\\author\s+([^}]+)').firstMatch(content);
      if (authorMatch != null) {
        author = authorMatch.group(1)?.trim() ?? author;
      }

      // Strip RTF control codes to get plain text
      final plainText = content
          .replaceAll(RegExp(r'\\[a-z]+\d*\s*'), ' ')
          .replaceAll(RegExp(r'[{}]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      final estimatedPages = (plainText.length / 1500).ceil().clamp(1, 9999);

      return EnhancedBookMetadata(
        title: title,
        author: author,
        estimatedPages: estimatedPages,
        additionalInfo: {'format': 'RTF', 'characterCount': plainText.length},
      );
    } catch (e) {
      debugPrint('RTF metadata extraction failed: $e');
      return _extractBasicMetadata(bytes, fileName);
    }
  }

  /// Basic metadata extraction fallback
  EnhancedBookMetadata _extractBasicMetadata(Uint8List bytes, String fileName) {
    final fileSize = bytes.length;
    final estimatedPages = (fileSize / 10000).ceil().clamp(1, 9999);
    final extension = fileName.split('.').last.toUpperCase();

    return EnhancedBookMetadata(
      title: fileName.replaceAll(RegExp(r'\.[^.]+$'), ''),
      author: 'Unknown',
      estimatedPages: estimatedPages,
      additionalInfo: {'format': extension, 'fileSize': fileSize},
    );
  }

  /// 所有本地导入格式共用的封面兜底。
  ///
  /// 格式解析器只负责尽量提供真实封面；若没有真实封面，则统一根据书名和
  /// 作者生成，避免不同格式各自维护一套默认封面分支。
  Future<Uint8List?> _resolveCoverImage(
    EnhancedBookMetadata metadata,
    String format,
  ) async {
    if (metadata.coverImage != null) return metadata.coverImage;
    try {
      return await CoverGenerator.generateTextCover(
        title: metadata.title,
        author: metadata.author,
        format: format,
      );
    } catch (error) {
      debugPrint('生成默认封面失败: $error');
      return null;
    }
  }

  /// Save cover image to disk
  Future<String?> _saveCoverImage(
    Uint8List imageBytes,
    String bookFileName,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final autoExtractEnabled =
          prefs.getBool('enableAutoExtractCover') ?? true;
      if (!autoExtractEnabled) {
        debugPrint('Auto cover extraction disabled, skip saving cover image.');
        return null;
      }

      final documentsDir = await _documentsDirectory();
      final coversDir = Directory(join(documentsDir.path, 'covers'));
      if (!await coversDir.exists()) {
        await coversDir.create(recursive: true);
      }

      final bookName = bookFileName.replaceAll(RegExp(r'\.[^.]+$'), '');
      // 文件名加入完整文件名（含扩展名）的哈希后缀，
      // 避免"同名不同格式"的书封面互相覆盖
      final nameHash = md5
          .convert(utf8.encode(bookFileName))
          .toString()
          .substring(0, 8);
      final coverPath = join(
        coversDir.path,
        '${bookName}_${nameHash}_cover.jpg',
      );
      final coverFile = File(coverPath);

      await coverFile.writeAsBytes(imageBytes);
      debugPrint('Cover image saved to: $coverPath');

      return coverPath;
    } catch (e) {
      debugPrint('Failed to save cover image: $e');
      return null;
    }
  }

  String _stripXmlTags(String xml) {
    return xml
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'&[a-zA-Z0-9#]+;'), ' ') // Remove XML entities
        .trim();
  }

  /// 验证图片格式
  bool _isValidImageFormat(Uint8List bytes) {
    if (bytes.length < 10) return false;

    // 检查文件头
    final header = bytes.take(10).toList();

    // JPEG: FF D8 FF
    if (header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF) {
      return true;
    }

    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (header[0] == 0x89 &&
        header[1] == 0x50 &&
        header[2] == 0x4E &&
        header[3] == 0x47) {
      return true;
    }

    // GIF: 47 49 46 38
    if (header[0] == 0x47 &&
        header[1] == 0x49 &&
        header[2] == 0x46 &&
        header[3] == 0x38) {
      return true;
    }

    // WebP: 52 49 46 46 ... 57 45 42 50
    if (header[0] == 0x52 &&
        header[1] == 0x49 &&
        header[2] == 0x46 &&
        header[3] == 0x46 &&
        bytes.length > 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }

    return false;
  }

  /// 增强的PDF封面提取
  Future<Uint8List?> _extractPdfCover(Uint8List bytes) async {
    PdfDocument? pdfDocument;
    PdfPage? page;
    try {
      pdfDocument = await PdfDocument.openData(bytes);

      // 获取第一页作为封面
      if (pdfDocument.pagesCount > 0) {
        page = await pdfDocument.getPage(1);
        final pageImage = await page.render(
          width: 300, // 封面宽度
          height: 400, // 封面高度
        );

        if (pageImage?.bytes != null && pageImage!.bytes.isNotEmpty) {
          return pageImage.bytes;
        }
      }

      return null;
    } catch (e) {
      debugPrint('Error extracting PDF cover: $e');
      return null;
    } finally {
      // render 抛异常时也要释放原生 PDF 句柄
      try {
        await page?.close();
      } catch (cleanupError) {
        debugPrint('Failed to close PDF cover page: $cleanupError');
      }
      try {
        await pdfDocument?.close();
      } catch (cleanupError) {
        debugPrint('Failed to close PDF document: $cleanupError');
      }
    }
  }
}
