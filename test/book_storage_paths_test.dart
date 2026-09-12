// 文件说明：书籍存储路径 codec 测试，覆盖跨沙盒根目录和历史 iOS 路径迁移。
// 技术要点：纯字符串验证，不创建或检查任何文件。

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/books/book_storage_paths.dart';

void main() {
  const uuidA = '11111111-2222-4333-8444-555555555555';
  const uuidB = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

  test('受管路径编码后可跨 Documents 根目录 A、B、C 解码', () {
    final rootA = BookStoragePaths('/sandbox/A/Documents');
    final rootB = BookStoragePaths('/sandbox/B/Documents');
    final rootC = BookStoragePaths('/sandbox/C/Documents');

    final stored = rootA.encode('/sandbox/A/Documents/books/科幻 小说/三体.epub');

    expect(stored, 'books/科幻 小说/三体.epub');
    expect(rootB.decode(stored), '/sandbox/B/Documents/books/科幻 小说/三体.epub');
    final storedAgain = rootB.encode(rootB.decode(stored));
    expect(
      rootC.decode(storedAgain),
      '/sandbox/C/Documents/books/科幻 小说/三体.epub',
    );
  });

  test('历史 iOS 真机沙盒路径映射到当前 Documents', () {
    final paths = BookStoragePaths('/current/Documents');
    final legacy =
        '/private/var/mobile/Containers/Data/Application/$uuidA/'
        'Documents/covers/custom_7_123.jpg';

    expect(paths.encode(legacy), 'covers/custom_7_123.jpg');
    expect(paths.decode(legacy), '/current/Documents/covers/custom_7_123.jpg');
  });

  test('历史 CoreSimulator 沙盒路径映射到当前 Documents', () {
    final paths = BookStoragePaths('/current/Documents');
    final legacy =
        '/Users/developer/Library/Developer/CoreSimulator/Devices/$uuidA/'
        'data/Containers/Data/Application/$uuidB/Documents/'
        'books/nested/book.epub';

    expect(paths.encode(legacy), 'books/nested/book.epub');
    expect(paths.decode(legacy), '/current/Documents/books/nested/book.epub');
  });

  test('只识别严格的 iOS 沙盒形状，外部 Documents/books 相似路径保持不变', () {
    final paths = BookStoragePaths('/current/Documents');
    final lookalikes = <String>[
      '/Volumes/Archive/Documents/books/external.epub',
      '/Users/me/Documents/books/external.epub',
      '/tmp/prefix/Documents/books/external.epub',
      '/private/var/mobile/Containers/Data/Application/not-a-uuid/'
          'Documents/books/external.epub',
      '/Users/me/Library/Developer/CoreSimulator/Devices/$uuidA/'
          'data/Containers/Data/Application/not-a-uuid/Documents/books/book.epub',
    ];

    for (final path in lookalikes) {
      expect(paths.encode(path), path, reason: path);
      expect(paths.decode(path), path, reason: path);
    }
  });

  test('needsResolution 只对受管相对路径和严格历史 iOS 路径返回 true', () {
    final legacyDevice =
        '/var/mobile/Containers/Data/Application/$uuidA/'
        'Documents/books/book.epub';
    final legacySimulator =
        '/Users/developer/Library/Developer/CoreSimulator/Devices/$uuidA/'
        'data/Containers/Data/Application/$uuidB/Documents/covers/book.jpg';

    expect(BookStoragePaths.needsResolution('books/book.epub'), isTrue);
    expect(BookStoragePaths.needsResolution('covers/nested/book.jpg'), isTrue);
    expect(BookStoragePaths.needsResolution(legacyDevice), isTrue);
    expect(BookStoragePaths.needsResolution(legacySimulator), isTrue);
    expect(
      BookStoragePaths.needsResolution('/current/Documents/books/book.epub'),
      isFalse,
    );
    expect(
      BookStoragePaths.needsResolution(
        '/Users/me/Documents/books/external.epub',
      ),
      isFalse,
    );
    expect(BookStoragePaths.needsResolution('books/../secret.epub'), isFalse);
    expect(
      BookStoragePaths.needsResolution('content://provider/book'),
      isFalse,
    );
  });

  test('外部路径、URI、其他目录和非规范相对路径保持不变', () {
    final paths = BookStoragePaths('/current/Documents');
    final unmanaged = <String>[
      '',
      '/external/book.epub',
      '/current/Documents/exports/book.epub',
      'content://provider/document/book',
      'https://example.com/book.epub',
      'http://example.com/cover.jpg',
      'web-book://${'a' * 64}',
      '../books/book.epub',
      'books/../secret.epub',
      'books//book.epub',
      'books/./book.epub',
      'books\\book.epub',
      'books/',
    ];

    for (final path in unmanaged) {
      expect(paths.encode(path), path, reason: path);
      expect(paths.decode(path), path, reason: path);
    }
  });

  test('book map 只改写 filePath 和 cover_image_path，其他元数据完全保留', () {
    final paths = BookStoragePaths('/current/Documents');
    final row = <String, dynamic>{
      'id': 9,
      'title': '书名',
      'currentPage': 37,
      'reading_progress': 0.42,
      'nested': <String, dynamic>{'keep': true},
      'filePath': '/current/Documents/books/book.epub',
      'cover_image_path': '/current/Documents/covers/book.jpg',
    };

    final encoded = paths.encodeBookMap(row);

    expect(encoded['filePath'], 'books/book.epub');
    expect(encoded['cover_image_path'], 'covers/book.jpg');
    expect(
      encoded
        ..remove('filePath')
        ..remove('cover_image_path'),
      {
        'id': 9,
        'title': '书名',
        'currentPage': 37,
        'reading_progress': 0.42,
        'nested': <String, dynamic>{'keep': true},
      },
    );
    expect(row['filePath'], '/current/Documents/books/book.epub');
    expect(row['cover_image_path'], '/current/Documents/covers/book.jpg');

    final decoded = paths.decodeBookMap(<String, dynamic>{
      ...row,
      'filePath': 'books/book.epub',
      'cover_image_path': null,
    });
    expect(decoded['filePath'], '/current/Documents/books/book.epub');
    expect(decoded['cover_image_path'], isNull);
    expect(decoded['title'], '书名');
    expect(decoded['currentPage'], 37);
  });

  test('Windows Documents 根目录使用 Windows 语义并保持统一存储形式', () {
    final paths = BookStoragePaths(r'C:\Users\Reader\Documents');

    expect(
      paths.encode(r'C:\Users\Reader\Documents\books\nested\book.epub'),
      'books/nested/book.epub',
    );
    expect(
      paths.decode('covers/中文 封面.jpg'),
      r'C:\Users\Reader\Documents\covers\中文 封面.jpg',
    );
    expect(
      paths.encode(r'D:\Documents\books\external.epub'),
      r'D:\Documents\books\external.epub',
    );
  });
}
