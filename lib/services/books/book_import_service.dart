// 文件说明：书籍导入总入口，统筹各格式元数据提取与入库。
// 技术要点：格式列表见 book_format_support.dart；File Picker、EPUBX、PDFX 等。
// 能力矩阵与后续目标：docs/book-format-support.md

import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdfx/pdfx.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/enhanced_txt_import_service.dart';
import 'package:xxread/services/books/epub_native_parser.dart';
import 'package:xxread/services/books/text_preprocessor_helper.dart';
import 'package:xxread/services/books/cover_generator_service.dart';
import 'package:xxread/services/books/book_import_limits.dart';
import 'package:xxread/services/books/book_import_isolate_service.dart';
import 'package:xxread/services/books/book_import_models.dart';
import 'package:xxread/services/books/book_import_metadata.dart';
import 'package:xxread/services/books/comic_book_parser.dart';
import 'package:xxread/services/books/kindle_book_parser.dart';
import 'package:xxread/services/books/web_book_file_store.dart';
import 'package:xxread/services/library/library_event_bus_service.dart';
import 'package:xxread/services/ai/global_ai_reading_service.dart';

export 'package:xxread/services/books/book_import_metadata.dart';

part 'book_import_metadata_text.dart';
part 'book_import_metadata_structured.dart';

class BookImportService implements BookFileImporter {
  BookImportService({
    BookImportStore? store,
    Future<Directory> Function()? documentsDirectory,
    ImportMetadataExtractor? metadataExtractor,
    Future<void> Function(Book book)? scheduleAnalysis,
    WebBookFileStore? webBookFileStore,
  }) : _store = store ?? BookDao(),
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _metadataExtractorOverride = metadataExtractor,
       _webBookFileStore = webBookFileStore ?? WebBookFileStore(),
       _scheduleAnalysis =
           scheduleAnalysis ??
           ((book) => GlobalAIReadingService().scheduleImportedBookAnalysis(
             book: book,
           ));

  final BookImportStore _store;
  final Future<Directory> Function() _documentsDirectory;
  final ImportMetadataExtractor? _metadataExtractorOverride;
  final WebBookFileStore _webBookFileStore;
  final Future<void> Function(Book book) _scheduleAnalysis;
  final _enhancedTxtService = EnhancedTxtImportService();
  final _preprocessor = TextPreprocessor();

  /// 流式复制文件，支持大文件和进度回调
  ///
  /// 参数 [source] 源文件
  /// 参数 [target] 目标文件
  /// 参数 [progressCallback] 进度回调函数，接收0.0-1.0的进度值
  Future<String> _copyFileWithProgress(
    File source,
    File target, {
    Function(double)? progressCallback,
  }) async {
    final fileSize = await source.length();
    final sourceStream = source.openRead();
    final targetSink = target.openWrite();

    int bytesCopied = 0;
    int lastReportedBytes = 0;
    const reportInterval = 1024 * 1024;
    final digestOutput = _SingleDigestSink();
    final digestSink = md5.startChunkedConversion(digestOutput);

    try {
      await for (var chunk in sourceStream) {
        targetSink.add(chunk);
        digestSink.add(chunk);
        bytesCopied += chunk.length;

        // 每复制约1MB或完成时更新进度（chunk 边界几乎不会恰好对齐
        // 1MB 整数倍，所以按累计增量判断而不是取模）
        if (bytesCopied - lastReportedBytes >= reportInterval ||
            bytesCopied >= fileSize) {
          lastReportedBytes = bytesCopied;
          final progress = bytesCopied / fileSize;
          progressCallback?.call(progress);
        }
      }

      digestSink.close();
      await targetSink.flush();
      await targetSink.close();

      debugPrint('文件复制完成: ${fileSize / 1024 / 1024} MB');
      return digestOutput.value.toString();
    } catch (e) {
      try {
        digestSink.close();
      } catch (closeError) {
        debugPrint('Failed to close import hash sink: $closeError');
      }
      try {
        await targetSink.close();
      } catch (closeError) {
        debugPrint('Failed to close partial import sink: $closeError');
      }
      await _deleteIfExistsBestEffort(target, context: 'partial import file');
      debugPrint('文件复制失败: $e');
      rethrow;
    }
  }

  /// 计算文件的 MD5 哈希。导入队列不能在哈希未知时继续写库。
  Future<String> _calculateRequiredHash(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        throw const BookImportFailure(code: 'source_missing');
      }

      final fileSize = await file.length();
      if (fileSize < 5 * 1024 * 1024) {
        final bytes = await file.readAsBytes();
        return md5.convert(bytes).toString();
      }

      debugPrint('使用isolate处理大文件哈希计算: ${fileSize / 1024 / 1024} MB');
      final result = await compute(
        calculateFileHashInIsolate,
        HashCalculationParams(filePath: filePath),
      );
      debugPrint('哈希计算完成: ${result.hash}');
      return result.hash;
    } on BookImportFailure {
      rethrow;
    } catch (error) {
      throw BookImportFailure(code: 'hash_failed', cause: error);
    }
  }

  Future<Directory> _managedBooksDirectory() async {
    final documentsDir = await _documentsDirectory();
    final booksDir = Directory(join(documentsDir.path, 'books'));
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    return booksDir;
  }

  Future<File> _allocateTarget(Directory booksDir, String displayName) async {
    final safeName = basename(displayName);
    final fileExtension = extension(safeName);
    final baseName = basenameWithoutExtension(safeName);

    for (var counter = 0; counter < 1000; counter++) {
      final suffix = counter == 0 ? '' : '_$counter';
      final candidateName = fileExtension.isEmpty
          ? '$baseName$suffix'
          : '$baseName$suffix$fileExtension';
      final candidate = File(join(booksDir.path, candidateName));
      if (!await candidate.exists() &&
          !await File('${candidate.path}.partial').exists()) {
        return candidate;
      }
    }

    throw const BookImportFailure(code: 'target_name_exhausted');
  }

  Future<_PreparedImportFile> _prepareFile(
    BookImportSource source,
    String sourceHash,
    BookImportProgress? onProgress,
  ) async {
    final sourcePath = source.localPath;
    if (sourcePath == null) {
      throw const BookImportFailure(code: 'source_not_materialized');
    }

    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw const BookImportFailure(code: 'source_missing');
    }

    if (source.ownership == BookImportOwnership.managedInPlace) {
      return _PreparedImportFile(
        file: sourceFile,
        ownsFile: false,
        contentHash: sourceHash,
      );
    }

    final booksDir = await _managedBooksDirectory();
    final finalFile = await _allocateTarget(booksDir, source.displayName);
    final partial = File('${finalFile.path}.partial');
    try {
      final copiedHash = await _copyFileWithProgress(
        sourceFile,
        partial,
        progressCallback: (value) =>
            onProgress?.call(BookImportPhase.copying, value, 'copying'),
      );
      if (copiedHash != sourceHash) {
        throw const BookImportFailure(code: 'copy_verification_failed');
      }
      await partial.rename(finalFile.path);
      return _PreparedImportFile(
        file: finalFile,
        ownsFile: true,
        contentHash: copiedHash,
      );
    } catch (error, stackTrace) {
      await _deleteIfExistsBestEffort(partial, context: 'partial import file');
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<BookImportResult> importFile(
    BookImportSource source, {
    BookImportProgress? onProgress,
  }) async {
    if (kIsWeb) {
      return _importWebFile(source, onProgress: onProgress);
    }

    _PreparedImportFile? prepared;
    String? createdCoverPath;
    var databaseCommitted = false;

    try {
      onProgress?.call(BookImportPhase.checking, 0, 'checking');
      final localPath = source.localPath;
      if (localPath == null) {
        throw const BookImportFailure(code: 'source_not_materialized');
      }

      final sourceFile = File(localPath);
      if (!await sourceFile.exists()) {
        throw const BookImportFailure(code: 'source_missing');
      }
      final size = await sourceFile.length();
      if (size > maximumBookImportBytes) {
        throw const BookImportFailure(code: 'file_too_large');
      }

      final sourceHash = await _calculateRequiredHash(localPath);
      final duplicate = await _store.getBookByHash(sourceHash);
      if (duplicate != null && await File(duplicate.filePath).exists()) {
        return BookImportResult(
          source: source,
          outcome: BookImportOutcome.duplicateSkipped,
          book: duplicate,
        );
      }

      prepared = await _prepareFile(source, sourceHash, onProgress);
      if (duplicate != null) {
        final repaired = await _store.updateBookStorageLocation(
          book: duplicate,
          filePath: prepared.file.path,
          sourceKind: source.kind.storageValue,
          sourceLocator: source.locator,
          sourceModifiedTime: source.modifiedTime,
        );
        databaseCommitted = true;
        LibraryEventBus().notifyLibraryChanged();
        return BookImportResult(
          source: source,
          outcome: BookImportOutcome.existingRepaired,
          book: repaired,
        );
      }

      onProgress?.call(BookImportPhase.analyzing, 0, 'analyzing');
      void progressAdapter(double progress, String _) {
        onProgress?.call(BookImportPhase.analyzing, progress, 'analyzing');
      }

      final metadata = _metadataExtractorOverride != null
          ? await _metadataExtractorOverride(
              prepared.file.path,
              source.displayName,
              source.extension,
              progressAdapter,
            )
          : await _extractEnhancedMetadataFromFile(
              prepared.file.path,
              source.displayName,
              source.extension,
              progressCallback: progressAdapter,
            );

      final resolvedCoverImage = await _resolveCoverImage(
        metadata,
        source.extension,
      );
      if (resolvedCoverImage != null) {
        createdCoverPath = await _saveCoverImage(
          resolvedCoverImage,
          source.displayName,
        );
      }

      final candidate = Book(
        title: metadata.title,
        author: metadata.author,
        filePath: prepared.file.path,
        format: source.extension.toUpperCase(),
        totalPages: metadata.estimatedPages,
        coverImagePath: createdCoverPath,
        contentHash: prepared.contentHash,
        textEncoding: metadata.textEncoding,
        sourceKind: source.kind.storageValue,
        sourceLocator: source.locator,
        sourceModifiedTime: source.modifiedTime,
      );

      onProgress?.call(BookImportPhase.saving, 0, 'saving');
      final decision = await _store.insertIfAbsentByHash(candidate);
      if (!decision.inserted) {
        return BookImportResult(
          source: source,
          outcome: BookImportOutcome.duplicateSkipped,
          book: decision.book,
        );
      }

      databaseCommitted = true;
      LibraryEventBus().notifyLibraryChanged();
      unawaited(_scheduleAnalysis(decision.book));
      return BookImportResult(
        source: source,
        outcome: BookImportOutcome.imported,
        book: decision.book,
      );
    } on BookImportFailure {
      rethrow;
    } catch (error) {
      throw BookImportFailure(code: 'import_failed', cause: error);
    } finally {
      if (!databaseCommitted && prepared?.ownsFile == true) {
        await _deleteIfExistsBestEffort(
          prepared!.file,
          context: 'rolled-back imported book',
        );
      }
      if (!databaseCommitted && createdCoverPath != null) {
        await _deleteIfExistsBestEffort(
          File(createdCoverPath),
          context: 'rolled-back book cover',
        );
      }
    }
  }

  Future<void> _deleteIfExistsBestEffort(
    File file, {
    required String context,
  }) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (cleanupError) {
      debugPrint('Failed to remove $context: $cleanupError');
    }
  }

  Future<BookImportResult> _importWebFile(
    BookImportSource source, {
    BookImportProgress? onProgress,
  }) async {
    final bytes = source.bytes;
    final virtualPath = source.localPath;
    if (bytes == null ||
        virtualPath == null ||
        !WebBookFileStore.isWebBookPath(virtualPath)) {
      throw const BookImportFailure(code: 'source_not_materialized');
    }
    if (bytes.length > maximumBookImportBytes) {
      throw const BookImportFailure(code: 'file_too_large');
    }

    final contentHash = WebBookFileStore.hashFromPath(virtualPath);
    var storedBeforeImport = false;
    try {
      onProgress?.call(BookImportPhase.checking, 0, 'checking');
      final duplicate = await _store.getBookByHash(contentHash);
      if (duplicate != null) {
        if (WebBookFileStore.isWebBookPath(duplicate.filePath) &&
            await _webBookFileStore.exists(duplicate.filePath)) {
          return BookImportResult(
            source: source,
            outcome: BookImportOutcome.duplicateSkipped,
            book: duplicate,
          );
        }
        await _webBookFileStore.put(virtualPath, bytes);
        final repaired = await _store.updateBookStorageLocation(
          book: duplicate,
          filePath: virtualPath,
          sourceKind: source.kind.storageValue,
          sourceLocator: source.locator,
          sourceModifiedTime: source.modifiedTime,
        );
        LibraryEventBus().notifyLibraryChanged();
        return BookImportResult(
          source: source,
          outcome: BookImportOutcome.existingRepaired,
          book: repaired,
        );
      }

      onProgress?.call(BookImportPhase.analyzing, 0, 'analyzing');
      final metadata = await _extractEnhancedMetadataFromBytes(
        bytes,
        source.displayName,
        source.extension,
        progressCallback: (progress, _) =>
            onProgress?.call(BookImportPhase.analyzing, progress, 'analyzing'),
      );
      final candidate = Book(
        title: metadata.title,
        author: metadata.author,
        filePath: virtualPath,
        format: source.extension.toUpperCase(),
        totalPages: metadata.estimatedPages,
        contentHash: contentHash,
        textEncoding: metadata.textEncoding,
        sourceKind: source.kind.storageValue,
        sourceLocator: source.locator,
        sourceModifiedTime: source.modifiedTime,
      );

      onProgress?.call(BookImportPhase.saving, 0, 'saving');
      storedBeforeImport = await _webBookFileStore.exists(virtualPath);
      await _webBookFileStore.put(virtualPath, bytes);
      final decision = await _store.insertIfAbsentByHash(candidate);
      LibraryEventBus().notifyLibraryChanged();
      return BookImportResult(
        source: source,
        outcome: decision.inserted
            ? BookImportOutcome.imported
            : BookImportOutcome.duplicateSkipped,
        book: decision.book,
      );
    } on BookImportFailure {
      rethrow;
    } catch (error) {
      if (!storedBeforeImport) {
        try {
          await _webBookFileStore.delete(virtualPath);
        } catch (cleanupError) {
          debugPrint('Failed to roll back web import: $cleanupError');
        }
      }
      throw BookImportFailure(code: 'import_failed', cause: error);
    }
  }

  /// 从文件路径提取元数据（优化大文件处理）
  ///
  /// 参数 [filePath] 文件路径
  /// 参数 [fileName] 文件名
  /// 参数 [extension] 文件扩展名
  /// 参数 [progressCallback] 进度回调，接收0.0-1.0的进度值和消息
  /// 返回提取的元数据
}

class _PreparedImportFile {
  const _PreparedImportFile({
    required this.file,
    required this.ownsFile,
    required this.contentHash,
  });

  final File file;
  final bool ownsFile;
  final String contentHash;
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
