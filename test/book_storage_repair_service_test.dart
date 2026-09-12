// 文件说明：书籍存储路径修复服务测试，覆盖 iOS 沙盒路径变化后的正文和封面恢复。
// 技术要点：注入临时 Documents 目录与记录型 DAO，验证旧路径兜底、持久化和可重试性。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/book_storage_repair_service.dart';

class _RecordingBookDao extends BookDao {
  List<Book> books = [];
  final List<(int, String)> fileUpdates = [];
  final List<(int, String?)> coverUpdates = [];
  final Set<int> failingFileUpdateIds = {};
  int getAllBooksCalls = 0;

  @override
  Future<List<Book>> getAllBooks() async {
    getAllBooksCalls++;
    return books;
  }

  @override
  Future<void> updateBookFilePath(int bookId, String newFilePath) async {
    if (failingFileUpdateIds.contains(bookId)) {
      throw StateError('simulated update failure for $bookId');
    }
    fileUpdates.add((bookId, newFilePath));
  }

  @override
  Future<void> updateBookCoverPath(int bookId, String? coverImagePath) async {
    coverUpdates.add((bookId, coverImagePath));
  }

  void clearUpdates() {
    fileUpdates.clear();
    coverUpdates.clear();
  }
}

void main() {
  late Directory documentsDir;
  late _RecordingBookDao dao;

  setUp(() async {
    documentsDir = await Directory.systemTemp.createTemp(
      'book_storage_repair_service_test',
    );
    dao = _RecordingBookDao();
  });

  tearDown(() async {
    if (await documentsDir.exists()) {
      await documentsDir.delete(recursive: true);
    }
  });

  BookStorageRepairService buildService() {
    return BookStorageRepairService(
      bookDao: dao,
      documentsDirectory: () async => documentsDir,
    );
  }

  String currentBookPath(String fileName) =>
      p.join(documentsDir.path, 'books', fileName);

  String currentCoverPath(String fileName) =>
      p.join(documentsDir.path, 'covers', fileName);

  String oldIosPath(String directory, String fileName) => p.join(
    '/private/var/mobile/Containers/Data/Application',
    'OLD-SANDBOX-ID',
    'Documents',
    directory,
    fileName,
  );

  Future<void> createFile(
    String filePath, [
    List<int> bytes = const [1],
  ]) async {
    final file = File(filePath);
    await file.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  Book richBook({
    int? id = 7,
    required String filePath,
    String? coverImagePath,
  }) {
    return Book(
      id: id,
      title: '沙丘',
      author: 'Frank Herbert',
      filePath: filePath,
      format: 'epub',
      currentPage: 42,
      totalPages: 512,
      readingProgress: 0.3125,
      importDate: DateTime.utc(2025, 2, 3, 4, 5, 6),
      cachedContent: 'cached-content',
      cachedPages: 'cached-pages',
      fileModifiedTime: 123456,
      contentHash: 'content-hash',
      tableOfContents: 'toc-json',
      coverImagePath: coverImagePath,
      textEncoding: 'utf-8',
      lastCanonicalLocator: 'canonical-json',
      lastRenderedLocator: 'rendered-json',
      layoutSignature: 'layout-signature',
      storageType: 'local',
      sourceId: 'source-id',
      sourceBookId: 'source-book-id',
      sourceJson: 'source-json',
      sourceBookJson: 'source-book-json',
      sourceKind: 'remote',
      sourceLocator: 'source-locator',
      sourceModifiedTime: 654321,
    );
  }

  void expectMetadataAndProgressPreserved(Book actual, Book original) {
    final actualMap = Map<String, dynamic>.from(actual.toMap())
      ..remove('filePath')
      ..remove('cover_image_path');
    final originalMap = Map<String, dynamic>.from(original.toMap())
      ..remove('filePath')
      ..remove('cover_image_path');
    expect(actualMap, originalMap);
  }

  test('旧 iOS 沙盒路径按原文件名恢复，并保留自定义封面和阅读数据', () async {
    const bookName = 'dune.epub';
    const customCoverName = 'custom_7_1720000000000.jpg';
    final repairedBookPath = currentBookPath(bookName);
    final repairedCoverPath = currentCoverPath(customCoverName);
    await createFile(repairedBookPath, [1, 2, 3]);
    await createFile(repairedCoverPath, [4, 5, 6]);
    final original = richBook(
      filePath: oldIosPath('books', bookName),
      coverImagePath: oldIosPath('covers', customCoverName),
    );

    final repaired = await buildService().repairSingleBookIfNeeded(original);

    expect(repaired.filePath, repairedBookPath);
    expect(repaired.coverImagePath, repairedCoverPath);
    expect(dao.fileUpdates, [(7, repairedBookPath)]);
    expect(dao.coverUpdates, [(7, repairedCoverPath)]);
    expectMetadataAndProgressPreserved(repaired, original);
  });

  test('单书修复返回可用路径，再次修复结果不重复写库', () async {
    final repairedBookPath = currentBookPath('batch.epub');
    final repairedCoverPath = currentCoverPath('batch.jpg');
    await createFile(repairedBookPath);
    await createFile(repairedCoverPath);
    final original = richBook(
      filePath: oldIosPath('books', 'batch.epub'),
      coverImagePath: oldIosPath('covers', 'batch.jpg'),
    );
    final service = buildService();

    final firstResult = await service.repairSingleBookIfNeeded(original);

    expect(firstResult.filePath, repairedBookPath);
    expect(firstResult.coverImagePath, repairedCoverPath);
    expect(dao.fileUpdates, hasLength(1));
    expect(dao.coverUpdates, hasLength(1));
    expectMetadataAndProgressPreserved(firstResult, original);

    dao.clearUpdates();
    final secondResult = await service.repairSingleBookIfNeeded(firstResult);

    expect(secondResult.filePath, repairedBookPath);
    expect(secondResult.coverImagePath, repairedCoverPath);
    expect(dao.fileUpdates, isEmpty);
    expect(dao.coverUpdates, isEmpty);
  });

  test('封面暂时缺失时保留旧路径且不写 null，文件恢复后可重试', () async {
    final validBookPath = currentBookPath('retry.epub');
    await createFile(validBookPath);
    final staleCoverPath = oldIosPath('covers', 'retry.jpg');
    final original = richBook(
      filePath: validBookPath,
      coverImagePath: staleCoverPath,
    );
    final service = buildService();

    final firstResult = await service.repairSingleBookIfNeeded(original);

    expect(firstResult.coverImagePath, staleCoverPath);
    expect(dao.coverUpdates, isEmpty);

    final repairedCoverPath = currentCoverPath('retry.jpg');
    await createFile(repairedCoverPath);
    final secondResult = await service.repairSingleBookIfNeeded(firstResult);

    expect(secondResult.coverImagePath, repairedCoverPath);
    expect(dao.coverUpdates, [(7, repairedCoverPath)]);
    expectMetadataAndProgressPreserved(secondResult, original);
  });

  test('封面修复只接受完整文件名匹配，不误用同前缀的其他封面', () async {
    final validBookPath = currentBookPath('exact.epub');
    await createFile(validBookPath);
    final staleCoverPath = oldIosPath('covers', 'custom_7_100.jpg');
    await createFile(currentCoverPath('custom_7_100_1.jpg'));
    await createFile(currentCoverPath('custom_7_1000.jpg'));
    final original = richBook(
      filePath: validBookPath,
      coverImagePath: staleCoverPath,
    );

    final repaired = await buildService().repairSingleBookIfNeeded(original);

    expect(repaired.coverImagePath, staleCoverPath);
    expect(dao.coverUpdates, isEmpty);
  });

  test('有效路径、无 ID 书籍与 null/空封面均不产生多余写入或伪造封面', () async {
    final validBookPath = currentBookPath('valid.epub');
    final validCoverPath = currentCoverPath('valid.jpg');
    await createFile(validBookPath);
    await createFile(validCoverPath);
    final valid = richBook(
      filePath: validBookPath,
      coverImagePath: validCoverPath,
    );
    final withoutId = richBook(
      id: null,
      filePath: oldIosPath('books', 'valid.epub'),
      coverImagePath: oldIosPath('covers', 'valid.jpg'),
    );
    final withoutCover = richBook(filePath: validBookPath);
    final emptyCover = richBook(filePath: validBookPath, coverImagePath: '');

    final service = buildService();
    final repaired = <Book>[];
    for (final book in [valid, withoutId, withoutCover, emptyCover]) {
      repaired.add(await service.repairSingleBookIfNeeded(book));
    }

    expect(repaired[0].filePath, validBookPath);
    expect(repaired[0].coverImagePath, validCoverPath);
    expect(repaired[1].filePath, withoutId.filePath);
    expect(repaired[1].coverImagePath, withoutId.coverImagePath);
    expect(repaired[2].coverImagePath, isNull);
    expect(repaired[3].coverImagePath, '');
    expect(dao.fileUpdates, isEmpty);
    expect(dao.coverUpdates, isEmpty);
  });

  test('repairAllBooksIfNeeded 使用 DAO 中的书籍并返回修复数', () async {
    final repairedBookPath = currentBookPath('all.epub');
    await createFile(repairedBookPath);
    dao.books = [richBook(filePath: oldIosPath('books', 'all.epub'))];

    final repairedCount = await buildService().repairAllBooksIfNeeded();

    expect(repairedCount, 1);
    expect(dao.getAllBooksCalls, 1);
    expect(dao.fileUpdates, [(7, repairedBookPath)]);
    expect(dao.coverUpdates, isEmpty);
  });

  test('批量修复隔离单本书的 DAO 写入失败，其他书仍能恢复', () async {
    final firstCurrentPath = currentBookPath('first.epub');
    final secondCurrentPath = currentBookPath('second.epub');
    await createFile(firstCurrentPath);
    await createFile(secondCurrentPath);
    final first = richBook(id: 1, filePath: oldIosPath('books', 'first.epub'));
    final second = richBook(
      id: 2,
      filePath: oldIosPath('books', 'second.epub'),
    );
    dao.failingFileUpdateIds.add(1);

    dao.books = [first, second];

    final repairedCount = await buildService().repairAllBooksIfNeeded();

    expect(repairedCount, 1);
    expect(dao.getAllBooksCalls, 1);
    expect(dao.fileUpdates, [(2, secondCurrentPath)]);
  });
}
