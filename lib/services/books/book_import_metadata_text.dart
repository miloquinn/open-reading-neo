part of 'book_import_service.dart';

extension _BookImportTextMetadata on BookImportService {
  Future<EnhancedBookMetadata> _extractEnhancedMetadataFromFile(
    String filePath,
    String fileName,
    String extension, {
    Function(double, String)? progressCallback,
  }) async {
    final ext = extension.toLowerCase();
    final file = File(filePath);
    final fileSize = await file.length();

    debugPrint('📖 提取元数据: $fileName (${fileSize / 1024 / 1024} MB)');

    progressCallback?.call(0.0, '读取文件...');

    if (ext == 'epub') {
      try {
        progressCallback?.call(0.2, '解析 EPUB 元数据...');
        final metadata = await compute(
          extractEpubNativeMetadata,
          <String, dynamic>{'epubPath': filePath},
        );
        progressCallback?.call(1.0, '元数据提取完成');
        return _epubMetadataFromMap(metadata, fileName);
      } catch (error) {
        debugPrint('EPUB metadata extraction failed: $error');
        return EnhancedBookMetadata(
          title: fileName.replaceAll(
            RegExp(r'\.(epub)$', caseSensitive: false),
            '',
          ),
          author: 'Unknown',
          estimatedPages: (fileSize / 10000).ceil().clamp(1, 9999),
          additionalInfo: <String, dynamic>{
            'format': 'EPUB',
            'fileSize': fileSize,
          },
        );
      }
    }

    // 📖 修改：TXT文件也完整读取，不再限制为10MB
    // 这样可以确保元数据提取基于完整内容
    Uint8List bytes;

    // 对于超大的非TXT文件（如大PDF），仍然限制读取大小避免内存问题
    const int maxBytesForMetadata = 10 * 1024 * 1024; // 10MB

    // Kindle 的 EXTH 封面记录位于文件尾部，截断头部会丢封面且破坏
    // PalmDB 记录表偏移；漫画容器的 ZIP 中央目录也在尾部、TAR 条目
    // 顺序排布（页数与首页封面依赖完整包），因此这些格式必须完整读取。
    const fullReadExtensions = <String>{
      'txt',
      'epub',
      'mobi',
      'azw',
      'azw3',
      'cbz',
      'cbt',
      'cbr',
      'cb7',
    };
    if (fileSize > maxBytesForMetadata && !fullReadExtensions.contains(ext)) {
      // 非TXT/EPUB的大文件只读取前10MB用于元数据提取
      debugPrint('⚠️ 大型${ext.toUpperCase()}文件，只读取前10MB用于元数据提取');
      progressCallback?.call(0.1, '读取大文件头部...');

      final stream = file.openRead(0, maxBytesForMetadata);
      final chunks = await stream.toList();
      final totalLength = chunks.fold<int>(
        0,
        (sum, chunk) => sum + chunk.length,
      );
      final buffer = Uint8List(totalLength);
      int offset = 0;
      for (var chunk in chunks) {
        buffer.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      bytes = buffer;

      progressCallback?.call(0.3, '分析文件内容...');
    } else {
      // TXT、EPUB或小文件，完整读取
      final fileSizeMB = fileSize / 1024 / 1024;
      if (fileSizeMB > 10) {
        debugPrint(
          '📖 完整读取${ext.toUpperCase()}文件 (${fileSizeMB.toStringAsFixed(1)} MB)',
        );
      }
      progressCallback?.call(0.2, '加载文件内容...');
      bytes = await file.readAsBytes();
      progressCallback?.call(0.4, '解析文件格式...');
    }

    return _extractEnhancedMetadataFromBytes(
      bytes,
      fileName,
      extension,
      progressCallback: progressCallback,
    );
  }

  Future<EnhancedBookMetadata> _extractEnhancedMetadataFromBytes(
    Uint8List bytes,
    String fileName,
    String extension, {
    Function(double, String)? progressCallback,
  }) async {
    final ext = extension.toLowerCase();
    try {
      final metadata = switch (ext) {
        'epub' => _epubMetadataFromMap(
          await compute(extractEpubMetadataInIsolate, bytes),
          fileName,
        ),
        'pdf' => await _extractPdfMetadata(bytes, fileName),
        'txt' => await _extractTxtMetadata(bytes, fileName),
        'mobi' ||
        'azw' ||
        'azw3' => await _extractMobiMetadata(bytes, fileName),
        'fb2' => await _extractFb2Metadata(bytes, fileName),
        'cbz' ||
        'cbr' ||
        'cbt' ||
        'cb7' => await _extractComicMetadata(bytes, fileName),
        'rtf' => await _extractRtfMetadata(bytes, fileName),
        _ => _extractBasicMetadata(bytes, fileName),
      };
      progressCallback?.call(1.0, '元数据提取完成');
      return metadata;
    } catch (error) {
      debugPrint('❌ 元数据提取失败: $error');
      progressCallback?.call(0.8, '使用默认信息...');
      return _extractBasicMetadata(bytes, fileName);
    }
  }

  /// Extract comprehensive EPUB metadata
  EnhancedBookMetadata _epubMetadataFromMap(
    Map<String, dynamic> metadata,
    String fileName,
  ) {
    final title = (metadata['title'] as String? ?? '').trim();
    final author = (metadata['author'] as String? ?? '').trim();
    return EnhancedBookMetadata(
      title: title.isEmpty
          ? fileName.replaceAll(RegExp(r'\.(epub)$', caseSensitive: false), '')
          : title,
      author: author.isEmpty ? 'Unknown' : author,
      description: metadata['description'] as String?,
      language: metadata['language'] as String?,
      publisher: metadata['publisher'] as String?,
      publishDate: metadata['publishDate'] as String?,
      isbn: metadata['isbn'] as String?,
      coverImage: metadata['coverImage'] as Uint8List?,
      estimatedPages: metadata['estimatedPages'] as int? ?? 1,
      tags: (metadata['tags'] as List<dynamic>?)?.cast<String>(),
      additionalInfo: Map<String, dynamic>.from(
        metadata['additionalInfo'] as Map? ?? const {},
      ),
    );
  }

  /// Extract PDF metadata
  Future<EnhancedBookMetadata> _extractPdfMetadata(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      final pdfDocument = await PdfDocument.openData(bytes);
      final pageCount = pdfDocument.pagesCount;

      // Extract basic metadata - PDF metadata is often limited
      final title = fileName.replaceAll(RegExp(r'\.(pdf)$'), '');
      const author = 'Unknown';

      // 优先使用 PDF 第一页；失败时仅在本地生成默认封面。
      Uint8List? coverImage;
      try {
        coverImage = await _extractPdfCover(bytes);
        if (coverImage == null) {
          coverImage = await CoverGenerator.generateTextCover(
            title: title,
            author: author,
            format: 'PDF',
          );
        } else {
          debugPrint('✅ 成功从PDF提取封面（第一页）');
        }
      } catch (e) {
        debugPrint('⚠️ PDF封面处理失败: $e，生成默认封面');
        try {
          coverImage = await CoverGenerator.generateTextCover(
            title: title,
            author: author,
            format: 'PDF',
          );
        } catch (genError) {
          debugPrint('❌ PDF封面生成失败: $genError');
        }
      }

      await pdfDocument.close();

      return EnhancedBookMetadata(
        title: title,
        author: 'Unknown',
        estimatedPages: pageCount,
        coverImage: coverImage,
        additionalInfo: {'format': 'PDF', 'actualPageCount': pageCount},
      );
    } catch (e) {
      debugPrint('PDF metadata extraction failed: $e');
      final fileSize = bytes.length;
      final estimatedPages = (fileSize / 50000).ceil().clamp(1, 9999);

      return EnhancedBookMetadata(
        title: fileName.replaceAll(RegExp(r'\.(pdf)$'), ''),
        author: 'Unknown',
        estimatedPages: estimatedPages,
      );
    }
  }

  /// 使用增强服务提取TXT元数据（使用isolate优化），编码自动检测
  Future<EnhancedBookMetadata> _extractTxtMetadata(
    Uint8List bytes,
    String fileName,
  ) async {
    try {
      var resolvedEncoding = _enhancedTxtService.detectEncoding(bytes);

      // 对于大文件，使用isolate处理
      SimpleMetadata simpleMetadata;
      if (bytes.length > 5 * 1024 * 1024) {
        // 大于5MB，使用isolate。isolate 消息是拷贝语义，只传
        // 元数据分析所需的头部切片，完整长度单独传给页数估算。
        const headSliceBytes = 100 * 1024;
        simpleMetadata = await compute(
          extractTxtMetadataInIsolate,
          MetadataExtractionParams(
            // sublist 而非 sublistView：视图发给 isolate 会连带
            // 拷贝整个底层缓冲区
            bytes: bytes.sublist(0, headSliceBytes),
            fileName: fileName,
            extension: 'txt',
            encodingOverride: resolvedEncoding,
            totalByteLength: bytes.length,
          ),
        );
      } else {
        // 小文件在主线程处理
        String content;
        try {
          final decodeResult = _enhancedTxtService.decodeWithResult(
            bytes,
            encodingOverride: resolvedEncoding,
          );
          content = decodeResult.content;
          resolvedEncoding = decodeResult.encoding;
        } catch (e) {
          content = utf8.decode(bytes, allowMalformed: true);
          resolvedEncoding = 'utf8';
        }

        // 文本预处理：压缩空行、添加缩进、段落间距
        content = _preprocessor.process(
          content,
          indentSize: 2,
          indentDialogue: true,
          compressEmptyLines: true,
          paragraphSpacing: 0,
        );

        // 不要使用 trim()，否则会移除段首缩进
        final lines = content
            .split('\n')
            .where((e) => e.trim().isNotEmpty)
            .toList();
        var title = lines.isNotEmpty
            ? lines.first.substring(0, lines.first.length.clamp(0, 50))
            : fileName.replaceAll(RegExp(r'\.(txt)$'), '');
        if (_looksGarbled(title)) {
          title = fileName.replaceAll(RegExp(r'\.(txt)$'), '');
        }
        final estimatedPages = (content.length / 1500).ceil().clamp(1, 9999);

        simpleMetadata = SimpleMetadata(
          title: title,
          author: 'Unknown',
          estimatedPages: estimatedPages,
          description: content.length > 200 ? content.substring(0, 200) : null,
          language: 'zh',
        );
      }

      // TXT 没有嵌入封面，仅在本地生成默认封面。
      Uint8List? coverImage;
      try {
        coverImage = await CoverGenerator.generateTextCover(
          title: simpleMetadata.title,
          author: simpleMetadata.author,
          format: 'TXT',
        );
        debugPrint('✅ TXT默认封面生成成功');
      } catch (e) {
        debugPrint('默认封面生成失败: $e');
      }

      debugPrint('✅ TXT元数据提取完成:');
      debugPrint('   标题: ${simpleMetadata.title}');
      debugPrint('   作者: ${simpleMetadata.author}');
      debugPrint('   预估页数: ${simpleMetadata.estimatedPages}');

      return EnhancedBookMetadata(
        title: simpleMetadata.title,
        author: simpleMetadata.author,
        description: simpleMetadata.description,
        estimatedPages: simpleMetadata.estimatedPages,
        language: simpleMetadata.language,
        coverImage: coverImage,
        textEncoding: resolvedEncoding,
        additionalInfo: {'format': 'TXT', 'fileSize': bytes.length},
      );
    } catch (e, stackTrace) {
      debugPrint('❌ TXT元数据提取失败，回退到基础提取: $e');
      debugPrint('Stack trace: $stackTrace');
      return _extractBasicMetadata(bytes, fileName);
    }
  }

  bool _looksGarbled(String text) {
    final value = text.trim();
    if (value.isEmpty) {
      return true;
    }

    int total = 0;
    int cjk = 0;
    int asciiLetters = 0;
    int digits = 0;
    int latinExtended = 0;
    int otherNonAscii = 0;
    int replacement = 0;

    for (final rune in value.runes) {
      if (rune <= 0x20) {
        continue;
      }
      total++;
      if (rune == 0xfffd) {
        replacement++;
        continue;
      }
      if ((rune >= 0x4e00 && rune <= 0x9fff) ||
          (rune >= 0x3400 && rune <= 0x4dbf) ||
          (rune >= 0xf900 && rune <= 0xfaff)) {
        cjk++;
        continue;
      }
      if ((rune >= 0x41 && rune <= 0x5a) || (rune >= 0x61 && rune <= 0x7a)) {
        asciiLetters++;
        continue;
      }
      if (rune >= 0x30 && rune <= 0x39) {
        digits++;
        continue;
      }
      if (rune >= 0x00c0 && rune <= 0x024f) {
        latinExtended++;
        continue;
      }
      if (rune > 0x7e) {
        otherNonAscii++;
      }
    }

    if (total == 0 || replacement > 0) {
      return true;
    }

    final asciiRatio = (asciiLetters + digits) / total;
    final cjkRatio = cjk / total;
    final nonAsciiRatio = (latinExtended + otherNonAscii) / total;

    if (cjkRatio >= 0.2) {
      return false;
    }
    if (asciiRatio >= 0.6) {
      return false;
    }
    return nonAsciiRatio >= 0.3;
  }
}
