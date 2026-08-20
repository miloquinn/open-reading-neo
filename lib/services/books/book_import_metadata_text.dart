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

    Uint8List bytes;

    // TXT 的书名、作者和编码只需要检查文件头。完整读取并预处理数万行
    // 文本会让导入卡在 UI isolate 上，且元数据结果并不会因此更准确。
    // 多读 4 字节，让编码检测知道 256 KiB 样本可能截在 UTF-8 字符中间。
    const int maxTxtBytesForMetadata = 256 * 1024 + 4;
    if (ext == 'txt' && fileSize > maxTxtBytesForMetadata) {
      progressCallback?.call(0.1, '读取文本头部...');
      bytes = await _readFilePrefix(file, maxTxtBytesForMetadata);
      progressCallback?.call(0.4, '分析文本信息...');
      return _extractEnhancedMetadataFromBytes(
        bytes,
        fileName,
        extension,
        progressCallback: progressCallback,
        totalByteLength: fileSize,
      );
    }

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
      totalByteLength: fileSize,
    );
  }

  Future<Uint8List> _readFilePrefix(File file, int byteCount) async {
    final chunks = await file.openRead(0, byteCount).toList();
    final length = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
    final result = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  Future<EnhancedBookMetadata> _extractEnhancedMetadataFromBytes(
    Uint8List bytes,
    String fileName,
    String extension, {
    Function(double, String)? progressCallback,
    int? totalByteLength,
  }) async {
    final ext = extension.toLowerCase();
    try {
      final metadata = switch (ext) {
        'epub' => _epubMetadataFromMap(
          await compute(extractEpubMetadataInIsolate, bytes),
          fileName,
        ),
        'pdf' => await _extractPdfMetadata(bytes, fileName),
        'txt' => await _extractTxtMetadata(
          bytes,
          fileName,
          totalByteLength: totalByteLength,
        ),
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
    String fileName, {
    int? totalByteLength,
  }) async {
    try {
      var resolvedEncoding = _enhancedTxtService.detectEncoding(bytes);
      final simpleMetadata = await compute(
        extractTxtMetadataInIsolate,
        MetadataExtractionParams(
          bytes: bytes,
          fileName: fileName,
          extension: 'txt',
          encodingOverride: resolvedEncoding,
          totalByteLength: totalByteLength ?? bytes.length,
        ),
      );

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
        additionalInfo: {
          'format': 'TXT',
          'fileSize': totalByteLength ?? bytes.length,
        },
      );
    } catch (e, stackTrace) {
      debugPrint('❌ TXT元数据提取失败，回退到基础提取: $e');
      debugPrint('Stack trace: $stackTrace');
      final fallback = _extractBasicMetadata(bytes, fileName);
      return EnhancedBookMetadata(
        title: fallback.title,
        author: fallback.author,
        estimatedPages: ((totalByteLength ?? bytes.length) / 10000)
            .ceil()
            .clamp(1, 9999),
        textEncoding: _enhancedTxtService.detectEncoding(bytes),
        additionalInfo: {
          'format': 'TXT',
          'fileSize': totalByteLength ?? bytes.length,
        },
      );
    }
  }
}
