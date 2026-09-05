import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/book.dart';
import '../books/book_import_models.dart';
import '../books/book_import_service.dart';
import '../core/database_service.dart';
import 'adapters/metadata_sync_adapters.dart';
import 'book_sync_identity.dart';
import 'mutable_txt_sync_service.dart';
import 'secure_sync_config.dart';
import 'sync_dataset_catalog.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'webdav_client.dart';

class WebDavBookFileService {
  WebDavBookFileService({
    SecureSyncConfigStore? configStore,
    DatabaseService? databaseService,
    WebDavClientFactory? clientFactory,
    BookFileImporter? importer,
    Future<Directory> Function()? temporaryDirectory,
    Future<Directory> Function()? documentsDirectory,
    Future<Database> Function()? database,
    MutableTxtSyncService? mutableTxtSyncService,
    Future<Directory> Function()? mutableStateDirectory,
  }) : _configStore = configStore ?? SecureSyncConfigStore(),
       _databaseService = databaseService ?? DatabaseService(),
       _clientFactory = clientFactory ?? WebDavClient.standard,
       _importer = importer ?? BookImportService(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _documentsDirectory =
           documentsDirectory ?? getApplicationDocumentsDirectory,
       _databaseProvider = database {
    _mutableTxtSyncService =
        mutableTxtSyncService ??
        MutableTxtSyncService(
          configStore: _configStore,
          databaseService: _databaseService,
          clientFactory: _clientFactory,
          database: database,
          stateDirectory: mutableStateDirectory,
        );
  }

  static const int maxRecoverableFileBytes = 100 * 1024 * 1024;
  static const int maxCoverFileBytes = 10 * 1024 * 1024;

  final SecureSyncConfigStore _configStore;
  final DatabaseService _databaseService;
  final WebDavClientFactory _clientFactory;
  final BookFileImporter _importer;
  final Future<Directory> Function() _temporaryDirectory;
  final Future<Directory> Function() _documentsDirectory;
  final Future<Database> Function()? _databaseProvider;
  late final MutableTxtSyncService _mutableTxtSyncService;

  Future<Database> get _database =>
      _databaseProvider?.call() ?? _databaseService.database;

  Future<RemoteBookDescriptor> upload(
    Book book, {
    void Function(BookFileTransferProgress progress)? onProgress,
    bool incrementalTxt = false,
  }) async {
    if (book.isOnline) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Online-source chapter caches are not uploaded as book files.',
      );
    }
    if (SyncDatasetCatalog.hasPrivateSourceIdentity(book.sourceId) ||
        SyncDatasetCatalog.hasPrivateSourceIdentity(book.sourceBookId)) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'Books with private source identities stay on this device.',
      );
    }
    final source = File(book.filePath);
    if (!await source.exists()) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.notFound,
        'The local book file no longer exists.',
      );
    }
    final size = await source.length();
    final mutableTxt = book.format.toLowerCase() == 'txt';
    if (!mutableTxt && size > maxRecoverableFileBytes) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'This release can safely sync non-TXT book files up to 100 MiB.',
      );
    }
    if (mutableTxt) {
      return _uploadMutableTxt(
        book,
        size: size,
        onProgress: onProgress,
        incremental: incrementalTxt,
      );
    }
    final credentials = await _credentials();
    final client = _clientFactory(credentials);
    final digest = await sha256.bind(source.openRead()).first;
    final hash = '$digest';
    final fileName = path.basename(book.filePath);
    final uid = await bookUidForMap(book.toMap());
    final db = await _database;
    final existingRemotePath = await _existingReadableRemotePath(
      db: db,
      client: client,
      bookUid: uid,
      hash: hash,
      fileName: fileName,
    );
    final remotePath =
        existingRemotePath ??
        await _uploadOriginalBook(
          client: client,
          source: source,
          book: book,
          fileName: fileName,
          hash: hash,
          size: size,
          onProgress: onProgress,
        );
    if (existingRemotePath != null) {
      onProgress?.call(
        BookFileTransferProgress(transferredBytes: size, totalBytes: size),
      );
    }

    final cover = await _uploadCover(client, book);
    await db.insert('sync_book_files', {
      'book_uid': uid,
      'local_book_id': book.id,
      'blob_sha256': hash,
      'file_name': fileName,
      'file_size': size,
      'remote_path': remotePath,
      'cover_blob_sha256': cover?.sha256,
      'cover_file_name': cover?.fileName,
      'cover_file_size': cover?.sizeBytes,
      'cover_remote_path': cover?.remotePath,
      'sync_enabled': 1,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return RemoteBookDescriptor(
      bookUid: uid,
      title: book.title,
      author: book.author,
      format: book.format,
      fileAvailable: true,
      sizeBytes: size,
      blobSha256: hash,
      remotePath: remotePath,
      fileName: fileName,
      sourceId: book.sourceId,
      sourceBookId: book.sourceBookId,
      coverAvailable: cover != null,
      coverSizeBytes: cover?.sizeBytes,
      coverBlobSha256: cover?.sha256,
      coverRemotePath: cover?.remotePath,
      coverFileName: cover?.fileName,
    );
  }

  Future<RemoteBookDescriptor> _uploadMutableTxt(
    Book book, {
    required int size,
    void Function(BookFileTransferProgress progress)? onProgress,
    bool incremental = false,
  }) async {
    final db = await _database;
    final uid = await stableBookUidForMap(db, book.toMap());
    await _mutableTxtSyncService.join(
      book,
      bookUid: uid,
      incremental: incremental,
    );
    await _mutableTxtSyncService.setEnabled(uid, true);
    final result = await _mutableTxtSyncService.reconcile(bookUid: uid);
    final states = await _mutableTxtSyncService.listStates();
    final state = states.where((candidate) => candidate.bookUid == uid).single;
    if (result.failed > 0 || state.status == MutableTxtSyncStatus.failed) {
      throw WebDavSyncFailure(
        WebDavSyncErrorCode.network,
        state.error ?? 'The TXT file could not be published to WebDAV.',
      );
    }
    if (state.status == MutableTxtSyncStatus.conflict) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.conflict,
        'The cloud TXT has another version that needs review.',
      );
    }
    onProgress?.call(
      BookFileTransferProgress(
        transferredBytes: incremental ? result.uploadedBytes : size,
        totalBytes: incremental ? result.uploadedBytes : size,
      ),
    );
    final cover = await _uploadCover(
      _clientFactory(await _credentials()),
      book,
    );
    if (cover != null) {
      await db.update(
        'sync_book_files',
        {
          'cover_blob_sha256': cover.sha256,
          'cover_file_name': cover.fileName,
          'cover_file_size': cover.sizeBytes,
          'cover_remote_path': cover.remotePath,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'book_uid = ?',
        whereArgs: [uid],
      );
    }
    return RemoteBookDescriptor(
      bookUid: uid,
      title: book.title,
      author: book.author,
      format: book.format,
      fileAvailable: true,
      sizeBytes: size,
      blobSha256: state.localHash,
      remotePath: state.remotePath,
      fileName: path.basename(book.filePath),
      sourceId: book.sourceId,
      sourceBookId: book.sourceBookId,
      coverAvailable: cover != null,
      coverSizeBytes: cover?.sizeBytes,
      coverBlobSha256: cover?.sha256,
      coverRemotePath: cover?.remotePath,
      coverFileName: cover?.fileName,
    );
  }

  Future<String?> _existingReadableRemotePath({
    required Database db,
    required WebDavClient client,
    required String bookUid,
    required String hash,
    required String fileName,
  }) async {
    final rows = await db.query(
      'sync_book_files',
      columns: ['remote_path'],
      where: 'book_uid = ? AND blob_sha256 = ? AND file_name = ?',
      whereArgs: [bookUid, hash, fileName],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final remotePath = rows.first['remote_path'] as String?;
    if (remotePath == null) return null;
    final segments = _remotePathSegments(remotePath);
    if (segments.length != 3 ||
        segments.first != 'books' ||
        segments.last != fileName) {
      return null;
    }
    return await client.exists(client.path(segments)) ? remotePath : null;
  }

  Future<String> _uploadOriginalBook({
    required WebDavClient client,
    required File source,
    required Book book,
    required String fileName,
    required String hash,
    required int size,
    void Function(BookFileTransferProgress progress)? onProgress,
  }) async {
    final baseFolder = _remoteBookFolderName(book, fileName);
    for (var copyNumber = 1; copyNumber <= 999; copyNumber++) {
      final folder = _numberedRemoteFolder(baseFolder, copyNumber);
      final remoteDirectory = ['books', folder];
      final remoteSegments = [...remoteDirectory, fileName];
      final remoteUri = client.path(remoteSegments);
      if (await client.exists(remoteUri)) {
        if (await _remoteFileMatches(client, remoteUri, hash, size)) {
          onProgress?.call(
            BookFileTransferProgress(transferredBytes: size, totalBytes: size),
          );
          return remoteSegments.join('/');
        }
        continue;
      }

      await client.ensureProtocolPath(remoteDirectory);
      final temporary = client.path([
        ...remoteDirectory,
        '.upload.${DateTime.now().microsecondsSinceEpoch}.part',
      ]);
      try {
        await client.putFile(
          temporary,
          source,
          onProgress: (sent, total) => onProgress?.call(
            BookFileTransferProgress(transferredBytes: sent, totalBytes: total),
          ),
        );
        try {
          await client.move(temporary, remoteUri);
          return remoteSegments.join('/');
        } on WebDavSyncFailure catch (error) {
          if (error.code != WebDavSyncErrorCode.conflict ||
              !await client.exists(remoteUri)) {
            rethrow;
          }
          if (await _remoteFileMatches(client, remoteUri, hash, size)) {
            return remoteSegments.join('/');
          }
        }
      } finally {
        try {
          await client.delete(temporary);
        } catch (_) {
          // Cleanup must not hide the original upload or MOVE result.
        }
      }
    }
    throw const WebDavSyncFailure(
      WebDavSyncErrorCode.conflict,
      'Too many different book files use the same readable WebDAV name.',
    );
  }

  Future<bool> _remoteFileMatches(
    WebDavClient client,
    Uri remoteUri,
    String expectedHash,
    int expectedSize,
  ) async {
    final temporaryRoot = await _temporaryDirectory();
    final partial = File(
      path.join(
        temporaryRoot.path,
        'open-reading-webdav-compare-${DateTime.now().microsecondsSinceEpoch}.part',
      ),
    );
    try {
      await client.downloadFile(remoteUri, partial);
      if (await partial.length() != expectedSize) return false;
      return '${await sha256.bind(partial.openRead()).first}' == expectedHash;
    } on WebDavSyncFailure catch (error) {
      if (error.code == WebDavSyncErrorCode.notFound) return false;
      rethrow;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
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
    final size = descriptor.sizeBytes;
    final mutableTxt =
        descriptor.format.toLowerCase() == 'txt' &&
        (remotePath.startsWith('v2:') || remotePath.startsWith('v3:'));
    final incrementalTxt = mutableTxt && remotePath.startsWith('v3:');
    if (!mutableTxt && size != null && size > maxRecoverableFileBytes) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.invalidConfiguration,
        'This release can safely restore non-TXT book files up to 100 MiB.',
      );
    }
    final credentials = await _credentials();
    final client = _clientFactory(credentials);
    final temporaryRoot = await _temporaryDirectory();
    final safeFileName = path.basename(fileName);
    final partial = File(
      path.join(
        temporaryRoot.path,
        'open-reading-webdav-${DateTime.now().microsecondsSinceEpoch}-$safeFileName.part',
      ),
    );
    File? coverPartial;
    try {
      String? incrementalEncoding;
      if (incrementalTxt) {
        if (size == null) {
          throw const WebDavSyncFailure(
            WebDavSyncErrorCode.corruptRemoteData,
            'The chunked cloud TXT is missing its expected size.',
          );
        }
        incrementalEncoding = await _mutableTxtSyncService
            .downloadIncrementalFile(
              client: client,
              bookUid: descriptor.bookUid,
              expectedHash: expectedHash,
              expectedSize: size,
              destination: partial,
            );
        onProgress?.call(
          BookFileTransferProgress(
            transferredBytes: await partial.length(),
            totalBytes: size,
          ),
        );
      } else {
        await client.downloadFile(
          _storedRemoteUri(
            client,
            remotePath,
            expectedBookUid: descriptor.bookUid,
          ),
          partial,
          onProgress: (received, total) => onProgress?.call(
            BookFileTransferProgress(
              transferredBytes: received,
              totalBytes: total > 0 ? total : size ?? 0,
            ),
          ),
        );
      }
      final actualSize = await partial.length();
      if (size != null && actualSize != size) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The downloaded book size does not match its metadata.',
        );
      }
      final actualHash = '${await sha256.bind(partial.openRead()).first}';
      if (actualHash != expectedHash) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The downloaded book checksum does not match its metadata.',
        );
      }
      final mutableRemoteEncoding =
          incrementalEncoding ??
          (mutableTxt
              ? await _mutableTxtSyncService.validatedRemoteRevisionEncoding(
                  client: client,
                  bookUid: descriptor.bookUid,
                  contentHash: actualHash,
                  file: partial,
                )
              : null);
      coverPartial = await _downloadCover(client, descriptor, temporaryRoot);
      if (mutableTxt) {
        final existing = await _existingBookForUid(descriptor.bookUid);
        if (existing != null) {
          final restoredCoverPath = await _restoreCover(
            existing,
            descriptor,
            coverPartial,
          );
          final updated = existing.copyWith(
            title: descriptor.title.trim().isEmpty
                ? existing.title
                : descriptor.title.trim(),
            author: descriptor.author.trim().isEmpty
                ? existing.author
                : descriptor.author.trim(),
            coverImagePath: restoredCoverPath,
          );
          final db = await _database;
          await db.update(
            'books',
            {
              'title': updated.title,
              'author': updated.author,
              'cover_image_path': ?restoredCoverPath,
            },
            where: 'id = ?',
            whereArgs: [updated.id],
          );
          await _mutableTxtSyncService.join(
            updated,
            bookUid: descriptor.bookUid,
            incremental: incrementalTxt,
          );
          try {
            await _mutableTxtSyncService.reconcile(bookUid: descriptor.bookUid);
          } catch (_) {
            // The existing library item remains available and any divergent
            // local/remote versions stay in the durable conflict workflow.
          }
          final refreshed = await db.query(
            'books',
            where: 'id = ?',
            whereArgs: [updated.id],
            limit: 1,
          );
          return refreshed.isEmpty ? updated : Book.fromMap(refreshed.single);
        }
      }
      final extension = path.extension(safeFileName).replaceFirst('.', '');
      final result = await _importer.importFile(
        BookImportSource(
          id: 'webdav:${descriptor.bookUid}',
          kind: BookImportSourceKind.filePicker,
          ownership: BookImportOwnership.externalCopy,
          displayName: safeFileName,
          extension: extension,
          locator: remotePath,
          localPath: partial.path,
          sizeBytes: actualSize,
        ),
      );
      final restoredCoverPath = await _restoreCover(
        result.book,
        descriptor,
        coverPartial,
      );
      final restoredTitle = descriptor.title.trim().isEmpty
          ? result.book.title
          : descriptor.title.trim();
      final restoredAuthor = descriptor.author.trim().isEmpty
          ? result.book.author
          : descriptor.author.trim();
      var restoredBook = result.book.copyWith(
        title: restoredTitle,
        author: restoredAuthor,
        coverImagePath: restoredCoverPath,
        textEncoding: mutableRemoteEncoding,
      );
      final db = await _database;
      final bookUpdates = <String, Object?>{
        'title': restoredTitle,
        'author': restoredAuthor,
        'cover_image_path': ?restoredCoverPath,
        if (mutableRemoteEncoding != null) ...{
          'text_encoding': mutableRemoteEncoding,
          'cached_content': null,
          'cached_pages': null,
          'table_of_contents': null,
        },
      };
      if (descriptor.sourceId != null && descriptor.sourceBookId != null) {
        restoredBook = restoredBook.copyWith(
          sourceId: descriptor.sourceId,
          sourceBookId: descriptor.sourceBookId,
        );
        bookUpdates.addAll({
          'source_id': descriptor.sourceId,
          'source_book_id': descriptor.sourceBookId,
        });
      }
      if (restoredBook.id != null) {
        await db.update(
          'books',
          bookUpdates,
          where: 'id = ?',
          whereArgs: [restoredBook.id],
        );
      }
      await db.insert('sync_book_files', {
        'book_uid': descriptor.bookUid,
        'local_book_id': restoredBook.id,
        'blob_sha256': expectedHash,
        'file_name': safeFileName,
        'file_size': actualSize,
        'remote_path': remotePath,
        'cover_blob_sha256': descriptor.coverBlobSha256,
        'cover_file_name': descriptor.coverFileName,
        'cover_file_size': descriptor.coverSizeBytes,
        'cover_remote_path': descriptor.coverRemotePath,
        'sync_enabled': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (restoredBook.format.toLowerCase() == 'txt') {
        await _mutableTxtSyncService.join(
          restoredBook,
          bookUid: descriptor.bookUid,
          incremental: incrementalTxt,
        );
        try {
          await _mutableTxtSyncService.reconcile(bookUid: descriptor.bookUid);
        } catch (_) {
          // The verified download is already usable. Keep its durable pending
          // binding so a later automatic cycle can establish the baseline.
        }
      }
      return restoredBook;
    } finally {
      if (await partial.exists()) await partial.delete();
      if (coverPartial != null && await coverPartial.exists()) {
        await coverPartial.delete();
      }
    }
  }

  Future<_RemoteCover?> _uploadCover(WebDavClient client, Book book) async {
    final localPath = book.coverImagePath;
    if (localPath == null || localPath.trim().isEmpty) return null;
    final source = File(localPath);
    if (!await source.exists()) return null;
    final size = await source.length();
    if (size <= 0 || size > maxCoverFileBytes) return null;
    final hash = '${await sha256.bind(source.openRead()).first}';
    final prefix = hash.substring(0, 2);
    final remoteSegments = ['blobs', 'covers', 'sha256', prefix, hash];
    final remoteUri = client.path(remoteSegments);
    await client.ensureProtocolPath(['blobs', 'covers', 'sha256', prefix]);
    if (!await client.exists(remoteUri)) {
      final temporary = client.path([
        'blobs',
        'covers',
        'sha256',
        prefix,
        '.$hash.${DateTime.now().microsecondsSinceEpoch}.part',
      ]);
      try {
        await client.putFile(temporary, source);
        await client.move(temporary, remoteUri);
      } finally {
        try {
          await client.delete(temporary);
        } catch (_) {
          // Cleanup must not hide the original cover upload result.
        }
      }
    }
    return _RemoteCover(
      sha256: hash,
      fileName: path.basename(source.path),
      sizeBytes: size,
      remotePath: remoteSegments.join('/'),
    );
  }

  Future<File?> _downloadCover(
    WebDavClient client,
    RemoteBookDescriptor descriptor,
    Directory temporaryRoot,
  ) async {
    if (!descriptor.coverAvailable) return null;
    final remotePath = descriptor.coverRemotePath;
    final expectedHash = descriptor.coverBlobSha256;
    final fileName = descriptor.coverFileName;
    final size = descriptor.coverSizeBytes;
    if (remotePath == null ||
        expectedHash == null ||
        fileName == null ||
        size == null ||
        size <= 0 ||
        size > maxCoverFileBytes) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The remote cover metadata is incomplete or invalid.',
      );
    }
    final partial = File(
      path.join(
        temporaryRoot.path,
        'open-reading-webdav-cover-${DateTime.now().microsecondsSinceEpoch}-${path.basename(fileName)}.part',
      ),
    );
    try {
      await client.downloadFile(
        client.path(
          remotePath
              .split('/')
              .where((segment) => segment.isNotEmpty)
              .toList(growable: false),
        ),
        partial,
      );
      if (await partial.length() != size) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The downloaded cover size does not match its metadata.',
        );
      }
      final actualHash = '${await sha256.bind(partial.openRead()).first}';
      if (actualHash != expectedHash) {
        throw const WebDavSyncFailure(
          WebDavSyncErrorCode.corruptRemoteData,
          'The downloaded cover checksum does not match its metadata.',
        );
      }
      return partial;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<String?> _restoreCover(
    Book imported,
    RemoteBookDescriptor descriptor,
    File? coverPartial,
  ) async {
    if (coverPartial == null) return imported.coverImagePath;
    final existingPath = imported.coverImagePath;
    late final File destination;
    if (existingPath != null && existingPath.trim().isNotEmpty) {
      destination = File(existingPath);
    } else {
      final documents = await _documentsDirectory();
      final covers = Directory(path.join(documents.path, 'covers'));
      await covers.create(recursive: true);
      var extension = path.extension(descriptor.coverFileName ?? '');
      if (extension.isEmpty || extension.length > 10) extension = '.img';
      final hash =
          descriptor.coverBlobSha256 ??
          sha256.convert(descriptor.bookUid.codeUnits).toString();
      final shortHash = hash.substring(0, hash.length.clamp(0, 16));
      destination = File(path.join(covers.path, 'webdav-$shortHash$extension'));
    }
    await destination.parent.create(recursive: true);
    await coverPartial.copy(destination.path);
    return destination.path;
  }

  Future<StoredSyncCredentials> _credentials() async {
    final credentials = await _configStore.readCredentials();
    if (credentials == null) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.authentication,
        'WebDAV is not configured or its secure password is unavailable.',
      );
    }
    return credentials;
  }

  Future<Book?> _existingBookForUid(String bookUid) async {
    final db = await _database;
    final direct = await db.rawQuery(
      '''
      SELECT b.*
      FROM sync_book_files f
      JOIN books b ON b.id = f.local_book_id
      WHERE f.book_uid = ?
      LIMIT 1
    ''',
      [bookUid],
    );
    if (direct.isNotEmpty) {
      try {
        return Book.fromMap(direct.single);
      } catch (_) {
        return null;
      }
    }
    final rows = await db.query('books');
    for (final row in rows) {
      try {
        if (await stableBookUidForMap(db, row) == bookUid) {
          return Book.fromMap(row);
        }
      } catch (_) {
        // A provider-owned or incomplete row cannot be updated as local TXT.
      }
    }
    return null;
  }
}

List<String> _remotePathSegments(String remotePath) => remotePath
    .split('/')
    .where((segment) => segment.isNotEmpty)
    .toList(growable: false);

Uri _storedRemoteUri(
  WebDavClient client,
  String remotePath, {
  required String expectedBookUid,
}) {
  final mutableV2 = remotePath.startsWith('v2:');
  final mutableV3 = remotePath.startsWith('v3:');
  final mutable = mutableV2 || mutableV3;
  final value = mutable ? remotePath.substring(3) : remotePath;
  final segments = _remotePathSegments(value);
  if (mutable) {
    final expectedSegment = base64Url
        .encode(utf8.encode(expectedBookUid))
        .replaceAll('=', '');
    final expectedLeaf = mutableV3 ? 'current.json' : 'current.txt';
    if (segments.length != 3 ||
        segments.first != 'books' ||
        segments[1] != expectedSegment ||
        segments.last != expectedLeaf) {
      throw const WebDavSyncFailure(
        WebDavSyncErrorCode.corruptRemoteData,
        'The mutable TXT path does not match its stable book identity.',
      );
    }
    return mutableV3
        ? client.incrementalMutablePath(segments)
        : client.mutablePath(segments);
  }
  return client.path(segments);
}

String _remoteBookFolderName(Book book, String fileName) {
  final fallbackTitle = path.basenameWithoutExtension(fileName);
  final title = _safeRemoteFolderSegment(book.title, fallbackTitle);
  final author = _meaningfulRemoteAuthor(book.author);
  final label = author.isEmpty ? title : '$title - $author';
  return _truncateRemoteFolder(label, 56);
}

String _meaningfulRemoteAuthor(String value) {
  final normalized = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  final lower = normalized.toLowerCase();
  if (normalized.isEmpty ||
      lower == 'unknown' ||
      lower == 'unknown author' ||
      lower == 'null' ||
      lower == 'none' ||
      normalized == '未知' ||
      normalized == '未知作者') {
    return '';
  }
  return _safeRemoteFolderSegment(normalized, '');
}

String _safeRemoteFolderSegment(String value, String fallback) {
  var safe = value
      .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '')
      .trim();
  if (safe.isEmpty) {
    safe = fallback
        .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '')
        .trim();
  }
  if (safe.isEmpty) safe = '未命名书籍';
  if (RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
    caseSensitive: false,
  ).hasMatch(safe)) {
    safe = '_$safe';
  }
  return safe;
}

String _numberedRemoteFolder(String base, int copyNumber) {
  if (copyNumber <= 1) return base;
  final suffix = ' ($copyNumber)';
  return '${_truncateRemoteFolder(base, 56 - suffix.runes.length)}$suffix';
}

String _truncateRemoteFolder(String value, int maxRunes) {
  if (value.runes.length <= maxRunes) return value;
  return String.fromCharCodes(value.runes.take(maxRunes));
}

class _RemoteCover {
  const _RemoteCover({
    required this.sha256,
    required this.fileName,
    required this.sizeBytes,
    required this.remotePath,
  });

  final String sha256;
  final String fileName;
  final int sizeBytes;
  final String remotePath;
}
