import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../../models/book.dart';

enum SourceRevisionOrigin {
  initialDownload,
  sourceAppend,
  sourceRefresh,
  userEdit,
  conflictResolution,
  sourceRebind,
}

enum SourceConflictResolution { keepLocal, useSource }

class TrackedSourceChapter {
  const TrackedSourceChapter({
    required this.sourceChapterId,
    required this.ordinal,
    required this.title,
    required this.baselineHash,
    required this.currentHash,
    required this.body,
    required this.userModified,
    this.sourceMarker,
    this.baselineAsset,
  });

  final String sourceChapterId;
  final int ordinal;
  final String title;
  final String? sourceMarker;
  final String? baselineAsset;
  final String? baselineHash;
  final String currentHash;
  final String body;
  final bool userModified;

  TrackedSourceChapter copyWith({
    int? ordinal,
    String? title,
    String? sourceMarker,
    String? baselineAsset,
    String? baselineHash,
    String? currentHash,
    String? body,
    bool? userModified,
  }) => TrackedSourceChapter(
    sourceChapterId: sourceChapterId,
    ordinal: ordinal ?? this.ordinal,
    title: title ?? this.title,
    sourceMarker: sourceMarker ?? this.sourceMarker,
    baselineAsset: baselineAsset ?? this.baselineAsset,
    baselineHash: baselineHash ?? this.baselineHash,
    currentHash: currentHash ?? this.currentHash,
    body: body ?? this.body,
    userModified: userModified ?? this.userModified,
  );

  Map<String, Object?> toJson() => {
    'source_chapter_id': sourceChapterId,
    'ordinal': ordinal,
    'title': title,
    'source_marker': sourceMarker,
    'baseline_asset': baselineAsset,
    'baseline_hash': baselineHash,
    'current_hash': currentHash,
    // This is the current chapter body needed to materialize the readable TXT.
    // Baseline/source candidates live in separate readable assets.
    'body': body,
    'user_modified': userModified,
  };

  factory TrackedSourceChapter.fromJson(Map<String, dynamic> json) =>
      TrackedSourceChapter(
        sourceChapterId: json['source_chapter_id']! as String,
        ordinal: (json['ordinal']! as num).toInt(),
        title: json['title']! as String,
        sourceMarker: json['source_marker'] as String?,
        baselineAsset: json['baseline_asset'] as String?,
        baselineHash: json['baseline_hash'] as String?,
        currentHash: json['current_hash']! as String,
        body: json['body']! as String,
        userModified: json['user_modified'] as bool? ?? false,
      );
}

class SourceContentConflict {
  const SourceContentConflict({
    required this.id,
    required this.sourceChapterId,
    required this.baselineAsset,
    required this.localAsset,
    required this.sourceAsset,
    required this.createdAt,
    this.resolution,
  });

  final String id;
  final String sourceChapterId;
  final String baselineAsset;
  final String localAsset;
  final String sourceAsset;
  final DateTime createdAt;
  final SourceConflictResolution? resolution;

  SourceContentConflict copyWith({SourceConflictResolution? resolution}) =>
      SourceContentConflict(
        id: id,
        sourceChapterId: sourceChapterId,
        baselineAsset: baselineAsset,
        localAsset: localAsset,
        sourceAsset: sourceAsset,
        createdAt: createdAt,
        resolution: resolution ?? this.resolution,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'source_chapter_id': sourceChapterId,
    'baseline_asset': baselineAsset,
    'local_asset': localAsset,
    'source_asset': sourceAsset,
    'created_at': createdAt.toUtc().toIso8601String(),
    'resolution': resolution?.name,
  };

  factory SourceContentConflict.fromJson(Map<String, dynamic> json) =>
      SourceContentConflict(
        id: json['id']! as String,
        sourceChapterId: json['source_chapter_id']! as String,
        baselineAsset: json['baseline_asset']! as String,
        localAsset: json['local_asset']! as String,
        sourceAsset: json['source_asset']! as String,
        createdAt: DateTime.parse(json['created_at']! as String),
        resolution: switch (json['resolution']) {
          'keepLocal' => SourceConflictResolution.keepLocal,
          'useSource' => SourceConflictResolution.useSource,
          _ => null,
        },
      );
}

class SourceChapterState {
  const SourceChapterState({
    required this.schemaVersion,
    required this.bookUid,
    required this.sourceId,
    required this.sourceBookId,
    required this.materializedContentHash,
    required this.baselineKnown,
    required this.chapters,
    required this.catalogChapterIds,
    required this.conflicts,
    required this.revisionOrigin,
  });

  final int schemaVersion;
  final String bookUid;
  final String sourceId;
  final String sourceBookId;
  final String materializedContentHash;
  final bool baselineKnown;
  final List<TrackedSourceChapter> chapters;
  final List<String> catalogChapterIds;
  final List<SourceContentConflict> conflicts;
  final SourceRevisionOrigin revisionOrigin;

  SourceChapterState copyWith({
    String? sourceId,
    String? sourceBookId,
    String? materializedContentHash,
    bool? baselineKnown,
    List<TrackedSourceChapter>? chapters,
    List<String>? catalogChapterIds,
    List<SourceContentConflict>? conflicts,
    SourceRevisionOrigin? revisionOrigin,
  }) => SourceChapterState(
    schemaVersion: schemaVersion,
    bookUid: bookUid,
    sourceId: sourceId ?? this.sourceId,
    sourceBookId: sourceBookId ?? this.sourceBookId,
    materializedContentHash:
        materializedContentHash ?? this.materializedContentHash,
    baselineKnown: baselineKnown ?? this.baselineKnown,
    chapters: chapters ?? this.chapters,
    catalogChapterIds: catalogChapterIds ?? this.catalogChapterIds,
    conflicts: conflicts ?? this.conflicts,
    revisionOrigin: revisionOrigin ?? this.revisionOrigin,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'book_uid': bookUid,
    'source_id': sourceId,
    'source_book_id': sourceBookId,
    'materialized_content_hash': materializedContentHash,
    'baseline_known': baselineKnown,
    'revision_origin': revisionOrigin.name,
    'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
    'catalog_chapter_ids': catalogChapterIds,
    'conflicts': conflicts.map((conflict) => conflict.toJson()).toList(),
  };

  factory SourceChapterState.fromJson(Map<String, dynamic> json) =>
      SourceChapterState(
        schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 1,
        bookUid: json['book_uid']! as String,
        sourceId: json['source_id']! as String,
        sourceBookId: json['source_book_id']! as String,
        materializedContentHash: json['materialized_content_hash']! as String,
        baselineKnown: json['baseline_known'] as bool? ?? false,
        revisionOrigin: SourceRevisionOrigin.values.firstWhere(
          (value) => value.name == json['revision_origin'],
          orElse: () => SourceRevisionOrigin.initialDownload,
        ),
        chapters: (json['chapters'] as List? ?? const [])
            .map(
              (value) => TrackedSourceChapter.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList(growable: false),
        catalogChapterIds: (json['catalog_chapter_ids'] as List? ?? const [])
            .map((value) => value as String)
            .toList(growable: false),
        conflicts: (json['conflicts'] as List? ?? const [])
            .map(
              (value) => SourceContentConflict.fromJson(
                Map<String, dynamic>.from(value as Map),
              ),
            )
            .toList(growable: false),
      );
}

class SourceStateAsset {
  const SourceStateAsset({required this.relativePath, required this.file});

  final String relativePath;
  final File file;
}

class SourceChapterStateStore {
  const SourceChapterStateStore();

  File sidecarFor(Book book) =>
      File('${book.filePath}.openreading-source.json');

  Directory assetDirectoryFor(Book book) =>
      Directory('${book.filePath}.openreading-source-assets');

  Future<SourceChapterState> _readState(File file) async {
    final json = await file.readAsString();
    try {
      return SourceChapterState.fromJson(
        Map<String, dynamic>.from(jsonDecode(json) as Map),
      );
    } on TypeError catch (error) {
      throw FormatException('Invalid source chapter sidecar fields', error);
    }
  }

  Future<SourceChapterState?> load(Book book) async {
    final file = sidecarFor(book);
    final backup = File('${file.path}.backup');
    if (!await file.exists()) {
      if (!await backup.exists()) return null;
      final recovered = await _readState(backup);
      await backup.rename(file.path);
      return recovered;
    }
    try {
      return await _readState(file);
    } on FormatException catch (error) {
      if (!await backup.exists()) {
        throw FormatException('Invalid source chapter sidecar', error);
      }
      final recovered = await _readState(backup);
      final directory = assetDirectoryFor(book);
      await directory.create(recursive: true);
      final corruptHash = await hashFile(file);
      await file.copy(
        path.join(directory.path, 'corrupt-state-$corruptHash.json'),
      );
      await file.delete();
      await backup.rename(file.path);
      return recovered;
    }
  }

  Future<void> save(Book book, SourceChapterState state) async {
    final previous = await load(book);
    final target = sidecarFor(book);
    if (previous != null &&
        (previous.sourceId != state.sourceId ||
            previous.sourceBookId != state.sourceBookId ||
            (previous.baselineKnown && !state.baselineKnown) ||
            previous.conflicts.any(
              (old) => !state.conflicts.any((current) => current.id == old.id),
            ))) {
      final directory = assetDirectoryFor(book);
      await directory.create(recursive: true);
      final json = jsonEncode(previous.toJson());
      final archive = File(
        path.join(directory.path, 'source-state-${hashText(json)}.json'),
      );
      if (!await archive.exists())
        await archive.writeAsString(json, flush: true);
    }
    final temporary = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
    if (await target.exists()) {
      final backup = File('${target.path}.backup');
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (!await target.exists() && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      try {
        if (await backup.exists()) await backup.delete();
      } catch (_) {
        // The new sidecar is already durable. A stale backup is harmless and
        // will be replaced by the next atomic save.
      }
    } else {
      await temporary.rename(target.path);
    }
  }

  Future<String> exportSidecar(Book book) async {
    final state = await load(book);
    if (state == null) throw StateError('Source chapter baseline is missing');
    return jsonEncode(state.toJson());
  }

  Future<SourceChapterState> importSidecar({
    required Book book,
    required String json,
  }) async {
    final state = SourceChapterState.fromJson(
      Map<String, dynamic>.from(jsonDecode(json) as Map),
    );
    final actualHash = await hashFile(File(book.filePath));
    if (actualHash != state.materializedContentHash) {
      throw StateError(
        'Source sidecar does not describe the current readable content',
      );
    }
    await save(book, state);
    return state;
  }

  Future<List<SourceStateAsset>> enumerateAssets(Book book) async {
    final assets = <SourceStateAsset>[];
    final sidecar = sidecarFor(book);
    if (await sidecar.exists()) {
      assets.add(
        SourceStateAsset(relativePath: 'source/book.json', file: sidecar),
      );
    }
    final directory = assetDirectoryFor(book);
    if (await directory.exists()) {
      await for (final entity in directory.list(recursive: true)) {
        if (entity is! File) continue;
        assets.add(
          SourceStateAsset(
            relativePath:
                'source/history/${path.relative(entity.path, from: directory.path)}',
            file: entity,
          ),
        );
      }
    }
    assets.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return assets;
  }

  Future<String> writeConflictAsset({
    required Book book,
    required String conflictId,
    required String label,
    required String title,
    required String body,
  }) async {
    final directory = assetDirectoryFor(book);
    await directory.create(recursive: true);
    final content = '$title\n\n$body\n';
    final contentHash = hashText(content);
    final safeId = _safe(conflictId);
    final shortId = safeId.length > 80 ? safeId.substring(0, 80) : safeId;
    final name = '$shortId-${_safe(label)}-$contentHash.txt';
    final file = File(path.join(directory.path, name));
    if (!await file.exists()) {
      await file.writeAsString(content, flush: true);
    } else if (await hashFile(file) != contentHash) {
      throw StateError('Source history asset does not match its content hash');
    }
    final metadata = File('${file.path}.json');
    if (!await metadata.exists()) {
      await metadata.writeAsString(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'content_hash': await hashFile(file),
          'title': title,
          'kind': label,
        }),
        flush: true,
      );
    }
    return name;
  }

  Future<SourceStateAsset> writeBookCandidate({
    required Book book,
    required String id,
    required String content,
  }) async {
    final directory = assetDirectoryFor(book);
    await directory.create(recursive: true);
    final name = '${_safe(id)}-source-candidate.txt';
    final file = File(path.join(directory.path, name));
    await file.writeAsString(content, flush: true);
    await File('${file.path}.json').writeAsString(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'content_hash': await hashFile(file),
        'kind': 'source_candidate',
      }),
      flush: true,
    );
    return SourceStateAsset(relativePath: 'source/history/$name', file: file);
  }

  Future<String> readAsset(Book book, String relativePath) async {
    final root = assetDirectoryFor(book);
    final normalized = path.normalize(path.join(root.path, relativePath));
    if (!path.isWithin(root.path, normalized)) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    return File(normalized).readAsString();
  }

  static Future<String> hashFile(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static String hashText(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String materialize(Iterable<TrackedSourceChapter> chapters) => chapters
      .map((chapter) => '${chapter.title}\n\n${chapter.body}\n\n\n')
      .join();

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
}
