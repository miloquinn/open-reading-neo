import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/book.dart';
import '../books/book_dao.dart';
import '../books/book_import_models.dart';
import '../books/book_import_service.dart';
import '../books/book_storage_codec.dart';
import '../core/database_service.dart';
import 'book_content_sync_service.dart';
import 'book_sync_identity.dart';
import 'storage/sync_storage.dart';
import 'sync_dataset_catalog.dart';
import 'sync_models.dart';

typedef BookFileImporterFactory = BookFileImporter Function(String bookUid);

/// Imports and publishes readable book files through [SyncStorage]. WebDAV,
/// object storage and an official server use this same orchestration.
class BookFileSyncService {
  BookFileSyncService({
    SyncStorageProvider? storageProvider,
    DatabaseService? databaseService,
    Future<Database> Function()? database,
    BookContentSyncService? contentSyncService,
    BookFileImporter? importer,
    BookFileImporterFactory? importerFactory,
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? documentsDirectory,
    Future<Directory> Function()? contentStateDirectory,
  }) : _storageProvider = storageProvider ?? _noStorage,
       _databaseService = databaseService ?? DatabaseService(),
       _databaseProvider = database,
       _importer = importer,
       _importerFactory =
           importerFactory ??
           ((uid) => BookImportService(store: BookDao(importedBookUid: uid))),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory {
    _content =
        contentSyncService ??
        BookContentSyncService(
          storageProvider: _storageProvider,
          databaseService: _databaseService,
          database: database,
          stateDirectory: contentStateDirectory,
        );
  }

  static const int maxRecoverableFileBytes = 100 * 1024 * 1024;
  static const int maxCoverFileBytes = 10 * 1024 * 1024;

  final SyncStorageProvider _storageProvider;
  final DatabaseService _databaseService;
  final Future<Database> Function()? _databaseProvider;
  final BookFileImporter? _importer;
  final BookFileImporterFactory _importerFactory;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _documentsDirectory;
  late final BookContentSyncService _content;

  BookContentSyncService get contentSyncService => _content;
  Future<Database> get _database =>
      _databaseProvider?.call() ?? _databaseService.database;
  static Future<SyncStorage?> _noStorage() async => null;

  Future<RemoteBookDescriptor> upload(
    Book book, {
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    final source = File(book.filePath);
    if (!await source.exists()) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The local book file no longer exists.',
      );
    }
    if (SyncDatasetCatalog.hasPrivateSourceIdentity(book.sourceId) ||
        SyncDatasetCatalog.hasPrivateSourceIdentity(book.sourceBookId)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Books with private source identities stay on this device.',
      );
    }
    final size = await source.length();
    if (book.format.toLowerCase() != 'txt' && size > maxRecoverableFileBytes) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'This release can safely sync book files up to 100 MiB.',
      );
    }
    final db = await _database;
    final uid = await stableBookUidForMap(db, book.toMap());
    await _content.join(book, bookUid: uid);
    final result = await _content.reconcile(bookUid: uid);
    final state = (await _content.listStates())
        .where((candidate) => candidate.bookUid == uid)
        .single;
    if (result.failed > 0 ||
        state.status != BookContentSyncStatus.synced ||
        state.localHash == null ||
        state.localHash != state.baseHash ||
        state.remoteVersion == null) {
      throw WebDavSyncFailure(
        state.status == BookContentSyncStatus.conflict
            ? WebDavSyncErrorCode.conflict
            : WebDavSyncErrorCode.network,
        state.error ?? 'The readable cloud book is not fully committed.',
      );
    }
    final row = (await db.query(
      'sync_book_files',
      where: 'book_uid = ?',
      whereArgs: [uid],
      limit: 1,
    )).single;
    final cover = await _uploadCover(book, state.remotePath);
    if (cover != null) {
      await db.update(
        'sync_book_files',
        {
          'cover_blob_sha256': cover.hash,
          'cover_file_name': cover.fileName,
          'cover_file_size': cover.size,
          'cover_remote_path': cover.remotePath,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'book_uid = ?',
        whereArgs: [uid],
      );
    }
    onProgress?.call(
      BookFileTransferProgress(
        transferredBytes: result.uploadedBytes,
        totalBytes: result.uploadedBytes,
      ),
    );
    return RemoteBookDescriptor(
      bookUid: uid,
      title: book.title,
      author: book.author,
      format: book.format,
      fileAvailable: true,
      sizeBytes: row['file_size'] as int,
      blobSha256: row['blob_sha256'] as String,
      remotePath: row['remote_path'] as String,
      fileName: row['file_name'] as String,
      sourceId: book.sourceId,
      sourceBookId: book.sourceBookId,
      coverAvailable: cover != null,
      coverSizeBytes: cover?.size,
      coverBlobSha256: cover?.hash,
      coverRemotePath: cover?.remotePath,
      coverFileName: cover?.fileName,
    );
  }

  Future<Book> download(
    RemoteBookDescriptor descriptor, {
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    final remotePath = descriptor.remotePath;
    final expectedHash = descriptor.blobSha256;
    final fileName = descriptor.fileName;
    if (!descriptor.fileAvailable ||
        remotePath == null ||
        expectedHash == null ||
        fileName == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'This remote book does not include a downloadable file.',
      );
    }
    final declaredSize = descriptor.sizeBytes;
    if (descriptor.format.toLowerCase() != 'txt' &&
        declaredSize != null &&
        declaredSize > maxRecoverableFileBytes) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'This release can safely restore book files up to 100 MiB.',
      );
    }
    final storage = await _requireStorage();
    final objectPath = SyncPath(remotePath);
    final info = await storage.stat(objectPath);
    if (info == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The readable cloud book is missing.',
      );
    }
    final temporary = await _temporaryDirectory();
    final partial = File(
      path.join(
        temporary.path,
        'open-reading-${DateTime.now().microsecondsSinceEpoch}-${path.basename(fileName)}.part',
      ),
    );
    File? cover;
    try {
      final sink = partial.openWrite();
      try {
        final result = await storage.download(
          objectPath,
          sink,
          expectedVersion: info.version,
        );
        onProgress?.call(
          BookFileTransferProgress(
            transferredBytes: result.info.length,
            totalBytes: descriptor.sizeBytes ?? result.info.length,
          ),
        );
      } finally {
        await sink.close();
      }
      if (descriptor.sizeBytes != null &&
          await partial.length() != descriptor.sizeBytes) {
        throw _corrupt('The downloaded book size does not match metadata.');
      }
      if ('${await sha256.bind(partial.openRead()).first}' != expectedHash) {
        throw _corrupt('The downloaded book checksum does not match metadata.');
      }
      cover = await _downloadCover(storage, descriptor, temporary);
      var existing = await _existingBook(descriptor.bookUid);
      if (existing != null) {
        if (existing.filePath.trim().isEmpty ||
            !await File(existing.filePath).exists()) {
          existing = await _materializeExisting(
            existing,
            descriptor,
            partial,
            cover,
          );
        }
        await _content.join(existing, bookUid: descriptor.bookUid);
        await _content.reconcile(bookUid: descriptor.bookUid);
        return (await _existingBook(descriptor.bookUid)) ?? existing;
      }
      final importer = _importer ?? _importerFactory(descriptor.bookUid);
      final imported = await importer.importFile(
        BookImportSource(
          id: 'sync:${descriptor.bookUid}',
          kind: BookImportSourceKind.filePicker,
          ownership: BookImportOwnership.externalCopy,
          displayName: path.basename(fileName),
          extension: path.extension(fileName).replaceFirst('.', ''),
          locator: remotePath,
          localPath: partial.path,
          sizeBytes: await partial.length(),
        ),
      );
      var book = imported.book.copyWith(
        title: descriptor.title.trim().isEmpty
            ? imported.book.title
            : descriptor.title,
        author: descriptor.author.trim().isEmpty
            ? imported.book.author
            : descriptor.author,
        sourceId: descriptor.sourceId,
        sourceBookId: descriptor.sourceBookId,
      );
      if (cover != null) {
        book = book.copyWith(
          coverImagePath: await _restoreCover(book, descriptor, cover),
        );
      }
      final db = await _database;
      if (book.id != null) {
        final stored = await bookToStorageMap(
          book,
          documentsDirectory: _documentsDirectory,
        );
        await db.update(
          'books',
          {
            'title': book.title,
            'author': book.author,
            'source_id': book.sourceId,
            'source_book_id': book.sourceBookId,
            'cover_image_path': stored['cover_image_path'],
          },
          where: 'id = ?',
          whereArgs: [book.id],
        );
      }
      await _content.join(book, bookUid: descriptor.bookUid);
      await _content.reconcile(bookUid: descriptor.bookUid);
      return (await _existingBook(descriptor.bookUid)) ?? book;
    } finally {
      if (await partial.exists()) await partial.delete();
      if (cover != null && await cover.exists()) await cover.delete();
    }
  }

  Future<_Cover?> _uploadCover(Book book, String currentPath) async {
    final value = book.coverImagePath;
    if (value == null || value.trim().isEmpty) return null;
    final file = File(value);
    if (!await file.exists()) return null;
    final size = await file.length();
    if (size <= 0 || size > maxCoverFileBytes) return null;
    final storage = await _requireStorage();
    final hash = '${await sha256.bind(file.openRead()).first}';
    final directory = path.posix.dirname(currentPath);
    final extension = path.extension(file.path).toLowerCase();
    final safeExtension = extension.isEmpty || extension.length > 10
        ? '.img'
        : extension;
    final remote = SyncPath('$directory/cover$safeExtension');
    final existing = await storage.stat(remote);
    if (existing != null) {
      final temp = await _temporaryDirectory();
      final verify = File(
        path.join(
          temp.path,
          'cover-verify-${DateTime.now().microsecondsSinceEpoch}.part',
        ),
      );
      try {
        final sink = verify.openWrite();
        try {
          await storage.download(
            remote,
            sink,
            expectedVersion: existing.version,
          );
        } finally {
          await sink.close();
        }
        if ('${await sha256.bind(verify.openRead()).first}' == hash) {
          return _Cover(hash, path.basename(file.path), size, remote.value);
        }
      } finally {
        if (await verify.exists()) await verify.delete();
      }
    }
    final write = existing == null
        ? await storage.create(
            remote,
            file.openRead(),
            length: size,
            contentType: _coverContentType(safeExtension),
          )
        : await storage.compareAndSwap(
            remote,
            file.openRead(),
            length: size,
            contentType: _coverContentType(safeExtension),
            expectedVersion: existing.version,
          );
    final temp = await _temporaryDirectory();
    final verify = File(
      path.join(
        temp.path,
        'cover-verify-${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );
    try {
      final sink = verify.openWrite();
      try {
        await storage.download(
          remote,
          sink,
          expectedVersion: write.info.version,
        );
      } finally {
        await sink.close();
      }
      if ('${await sha256.bind(verify.openRead()).first}' != hash) {
        throw _corrupt('The published cover failed checksum verification.');
      }
    } finally {
      if (await verify.exists()) await verify.delete();
    }
    return _Cover(hash, path.basename(file.path), size, remote.value);
  }

  Future<File?> _downloadCover(
    SyncStorage storage,
    RemoteBookDescriptor descriptor,
    Directory temporary,
  ) async {
    if (!descriptor.coverAvailable) return null;
    final remotePath = descriptor.coverRemotePath;
    final expectedHash = descriptor.coverBlobSha256;
    final expectedSize = descriptor.coverSizeBytes;
    if (remotePath == null ||
        expectedHash == null ||
        expectedSize == null ||
        expectedSize <= 0 ||
        expectedSize > maxCoverFileBytes) {
      throw _corrupt('The remote cover metadata is incomplete.');
    }
    final remote = SyncPath(remotePath);
    final info = await storage.stat(remote);
    if (info == null) throw _corrupt('The remote cover is missing.');
    final file = File(
      path.join(
        temporary.path,
        'cover-${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );
    final sink = file.openWrite();
    try {
      await storage.download(remote, sink, expectedVersion: info.version);
    } finally {
      await sink.close();
    }
    if (await file.length() != expectedSize ||
        '${await sha256.bind(file.openRead()).first}' != expectedHash) {
      await file.delete();
      throw _corrupt('The downloaded cover failed verification.');
    }
    return file;
  }

  Future<String> _restoreCover(
    Book book,
    RemoteBookDescriptor descriptor,
    File source,
  ) async {
    final documents = await _documentsDirectory();
    final directory = Directory(path.join(documents.path, 'covers'));
    await directory.create(recursive: true);
    var extension = path.extension(descriptor.coverFileName ?? '');
    if (extension.isEmpty || extension.length > 10) extension = '.img';
    final name =
        '${descriptor.bookUid.substring(0, descriptor.bookUid.length.clamp(0, 16))}$extension';
    final target = File(path.join(directory.path, name));
    await source.copy(target.path);
    return target.path;
  }

  Future<Book?> _existingBook(String uid) async {
    final db = await _database;
    final bindings = await db.query(
      'sync_book_files',
      columns: ['local_book_id'],
      where: 'book_uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    int? localId;
    if (bindings.isNotEmpty) {
      localId = bindings.single['local_book_id'] as int?;
    }
    if (localId == null) {
      final frozen = await db.query(
        'sync_local_state',
        columns: ['key'],
        where: "key LIKE 'frozen_book_uid:%' AND value = ?",
        whereArgs: [uid],
        limit: 1,
      );
      if (frozen.isNotEmpty) {
        localId = int.tryParse(
          (frozen.single['key'] as String).substring('frozen_book_uid:'.length),
        );
      }
    }
    if (localId == null) return null;
    final books = await db.query(
      'books',
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return books.isEmpty
        ? null
        : bookFromStorageMap(
            books.single,
            documentsDirectory: _documentsDirectory,
          );
  }

  Future<Book> _materializeExisting(
    Book existing,
    RemoteBookDescriptor descriptor,
    File partial,
    File? cover,
  ) async {
    final documents = await _documentsDirectory();
    final directory = Directory(path.join(documents.path, 'books'));
    await directory.create(recursive: true);
    final safeName = path.basename(descriptor.fileName ?? 'book.bin');
    final suffix = descriptor.bookUid.length <= 12
        ? descriptor.bookUid
        : descriptor.bookUid.substring(0, 12);
    final destination = File(path.join(directory.path, '$suffix-$safeName'));
    await partial.copy(destination.path);
    var updated = existing.copyWith(
      title: descriptor.title.trim().isEmpty
          ? existing.title
          : descriptor.title,
      author: descriptor.author.trim().isEmpty
          ? existing.author
          : descriptor.author,
      filePath: destination.path,
      format: descriptor.format,
      storageType: 'local',
      sourceId: descriptor.sourceId ?? existing.sourceId,
      sourceBookId: descriptor.sourceBookId ?? existing.sourceBookId,
    );
    if (cover != null) {
      updated = updated.copyWith(
        coverImagePath: await _restoreCover(updated, descriptor, cover),
      );
    }
    final stored = await bookToStorageMap(
      updated,
      documentsDirectory: _documentsDirectory,
    );
    final db = await _database;
    await db.update(
      'books',
      {
        'title': stored['title'],
        'author': stored['author'],
        'filePath': stored['filePath'],
        'format': stored['format'],
        'storage_type': stored['storage_type'],
        'source_id': stored['source_id'],
        'source_book_id': stored['source_book_id'],
        'cover_image_path': stored['cover_image_path'],
        'content_hash': descriptor.blobSha256,
        'file_modified_time': DateTime.now().millisecondsSinceEpoch,
        'cached_content': null,
        'cached_pages': null,
        'table_of_contents': null,
      },
      where: 'id = ?',
      whereArgs: [existing.id],
    );
    return updated;
  }

  Future<SyncStorage> _requireStorage() async {
    final storage = await _storageProvider();
    if (storage == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Cloud storage is not configured.',
      );
    }
    return storage;
  }

  static WebDavSyncFailure _corrupt(String message) =>
      WebDavSyncFailure(WebDavSyncErrorCode.corruptRemoteData, message);

  static String _coverContentType(String extension) => switch (extension) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    _ => 'application/octet-stream',
  };
}

class _Cover {
  const _Cover(this.hash, this.fileName, this.size, this.remotePath);
  final String hash;
  final String fileName;
  final int size;
  final String remotePath;
}
