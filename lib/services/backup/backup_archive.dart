import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../book_sources/services/book_source_registry_storage.dart';
import '../../book_sources/models/registered_book_source.dart';
import '../books/book_storage_paths.dart';
import 'backup_selection.dart';

/// A snapshot contains business rows, portable book files, sources and settings.
/// Imported archives never supply SQL or filesystem destinations.
class BackupArchive {
  BackupArchive({
    required this.database,
    required this.documents,
    required this.preferences,
    required this.sources,
  });
  final Database database;
  final Directory documents;
  final SharedPreferences preferences;
  final BookSourceRegistryStorage sources;
  static const tables = [
    'books',
    'bookmarks',
    'reading_stats',
    'reading_sessions',
    'book_notes',
  ];
  static const sourceKey = 'open_reading_book_sources_v1';

  // Account sessions, device permissions and cloud passwords are device-local.
  static bool includesPreference(String key) =>
      !RegExp(
        r'webdav|sync_|account|member|token|password|secret|api.?key|cookie|android.*folder|permission|agreement|privacy|ai_|reader_aloud_cloud_',
        caseSensitive: false,
      ).hasMatch(key) &&
      key != sourceKey;

  Future<Map<String, Object?>> _snapshot() async {
    const caches = {
      'cached_pages',
      'cached_content',
      'layout_signature',
      'last_rendered_locator',
    };
    final bookColumns = (await database.rawQuery(
      'PRAGMA table_info(books)',
    )).map((c) => c['name'] as String).toList();
    final rows = await database.transaction(
      (tx) async => <String, Object?>{
        for (final table in tables)
          table: await tx.query(
            table,
            columns: table == 'books'
                ? bookColumns.where((c) => !caches.contains(c)).toList()
                : null,
          ),
      },
    );
    rows['books'] = (rows['books'] as List)
        .map(
          (row) => <String, Object?>{
            ...Map<String, Object?>.from(row as Map),
            for (final column in bookColumns.where(caches.contains))
              column: null,
          },
        )
        .toList();
    final hasIdentities = (await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_local_state'",
    )).isNotEmpty;
    final identities = hasIdentities
        ? await database.query(
            'sync_local_state',
            where: 'key LIKE ?',
            whereArgs: ['frozen_book_uid:%'],
          )
        : <Map<String, Object?>>[];
    final rawSources =
        await sources.read() ??
        preferences.getString(sourceKey) ??
        '{"version":2,"sources":[],"groups":[]}';
    _validateSources(rawSources);
    return {
      'format': 'open-reading-backup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'schema': await database.getVersion(),
      'tables': rows,
      'identities': identities,
      'preferences': {
        for (final key in preferences.getKeys())
          if (includesPreference(key)) key: preferences.get(key),
      },
      'sources': rawSources,
    };
  }

  Future<List<BackupBook>> inventory() async {
    final paths = BookStoragePaths(documents.path);
    final result = <BackupBook>[];
    for (final row in await database.query('books')) {
      final raw = row['filePath'] as String? ?? '';
      if (raw.isEmpty || row['storage_type'] == 'online') continue;
      final file = File(paths.decode(raw));
      final available = await file.exists();
      var bytes = available ? await file.length() : 0;
      for (final extra in [
        row['cover_image_path'],
        '$raw.openreading-source.json',
      ]) {
        if (extra is! String || extra.isEmpty) continue;
        final f = File(paths.decode(extra));
        if (await f.exists()) bytes += await f.length();
      }
      result.add(
        BackupBook(row['id'] as int, row['title'] as String, bytes, available),
      );
    }
    return result;
  }

  Future<void> create(
    File destination, {
    BackupSelection? selection,
    void Function(int, int)? onProgress,
    void Function()? onVerifying,
  }) async {
    final snapshot = await _snapshot();
    if (selection?.isEmpty == true) throw StateError('Select backup content');
    final files = <String, File>{};
    final rows = snapshot['tables'] as Map<String, Object?>;
    final books = (rows['books'] as List)
        .map((row) => Map<String, Object?>.from(row as Map))
        .toList();
    rows['books'] = books;
    if (selection != null &&
        !books.map((b) => b['id']).toSet().containsAll(selection.bookIds)) {
      throw StateError('Selected books changed; choose books again');
    }
    if (selection != null) {
      snapshot['version'] = 2;
      snapshot['scope'] = selection.toJson();
      // Persist an identity before making portable metadata-only snapshots.
      await database.execute(
        'CREATE TABLE IF NOT EXISTS sync_local_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      for (final book in books) {
        await database.insert('sync_local_state', {
          'key': 'frozen_book_uid:${book['id']}',
          'value': const Uuid().v4(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      snapshot['identities'] = await database.query(
        'sync_local_state',
        where: 'key LIKE ?',
        whereArgs: ['frozen_book_uid:%'],
      );
      if (!selection.reading && selection.bookIds.isEmpty) {
        for (final table in ['books', 'bookmarks', 'book_notes']) {
          rows[table] = <Object>[];
        }
      }
      if (!selection.statistics) {
        rows['reading_stats'] = <Object>[];
        rows['reading_sessions'] = <Object>[];
      }
      if (!selection.sources) {
        snapshot['sources'] = '{"version":2,"sources":[],"groups":[]}';
      }
      if (!selection.settings) snapshot['preferences'] = <String, Object?>{};
    }
    final paths = BookStoragePaths(documents.path);
    for (final book in (rows['books'] as List).cast<Map<String, Object?>>()) {
      for (final column in ['filePath', 'cover_image_path']) {
        if (selection != null && !selection.bookIds.contains(book['id'])) {
          book[column] = column == 'filePath' ? '' : null;
          continue;
        }
        final raw = book[column];
        if (raw is! String || raw.isEmpty) continue;
        final file = File(paths.decode(raw));
        if (!await file.exists()) {
          if (column == 'filePath') {
            throw FileSystemException(
              'Book file is missing; backup was not created',
              raw,
            );
          }
          book[column] = null;
          continue;
        }
        final extension = p
            .extension(file.path)
            .replaceAll(RegExp('[^a-zA-Z0-9.]'), '');
        final name =
            '${column == 'filePath' ? 'books' : 'covers'}/${book['id']}$extension';
        book[column] = name;
        files[name] = file;
        if (column == 'filePath') {
          final sidecar = File('${file.path}.openreading-source.json');
          if (await sidecar.exists()) {
            files['$name.openreading-source.json'] = sidecar;
          }
        }
      }
      // Layout caches contain old device paths and can be rebuilt.
      for (final column in [
        'cached_pages',
        'cached_content',
        'layout_signature',
        'last_rendered_locator',
      ]) {
        if (book.containsKey(column)) book[column] = null;
      }
    }
    final filePaths = files.map((key, file) => MapEntry(key, file.path));
    final destinationPath = destination.path;
    final port = ReceivePort();
    final subscription = port.listen((message) {
      final values = message as List;
      onProgress?.call(values[0] as int, values[1] as int);
    });
    final send = port.sendPort;
    try {
      await _runEncoder(destinationPath, snapshot, filePaths, send);
    } finally {
      await subscription.cancel();
      port.close();
    }
    // Also catches a file changing between hashing and compression.
    onVerifying?.call();
    // The writer checks source stability. Restores validate all stored hashes;
    // extracting a second full copy here needlessly doubles disk work.
    if (!await destination.exists() || await destination.length() == 0) {
      throw const FormatException('Empty backup');
    }
  }

  static Future<void> _runEncoder(
    String destination,
    Map<String, Object?> snapshot,
    Map<String, String> paths,
    SendPort port,
  ) => Isolate.run(() => _encodeZip(destination, snapshot, paths, port));

  static Future<void> _encodeZip(
    String destinationPath,
    Map<String, Object?> snapshot,
    Map<String, String> filePaths,
    SendPort progress,
  ) async {
    final hashes = <String, String>{};
    final encoder = ZipFileEncoder()..create(destinationPath);
    var done = 0;
    final total = filePaths.values.fold<int>(
      0,
      (sum, path) => sum + File(path).lengthSync(),
    );
    progress.send([0, total * 2]);
    try {
      for (final entry in filePaths.entries) {
        final file = File(entry.value);
        final before = await file.stat();
        if (before.size > 2 * 1024 * 1024 * 1024 ||
            total > 8 * 1024 * 1024 * 1024) {
          throw const FormatException('Backup exceeds supported size');
        }
        var lastReport = DateTime.now();
        final stream = file.openRead().map((chunk) {
          done += chunk.length;
          if (DateTime.now().difference(lastReport).inMilliseconds >= 100) {
            progress.send([done, total * 2]);
            lastReport = DateTime.now();
          }
          return chunk;
        });
        hashes[entry.key] = (await sha256.bind(stream).first).toString();
        progress.send([done, total * 2]);
        // EPUB/PDF/images are already compressed. STORE avoids spending minutes
        // recompressing them and keeps the archive compatible with ordinary ZIP.
        await encoder.addFile(file, entry.key, ZipFileEncoder.STORE);
        final after = await file.stat();
        if (before.size != after.size || before.modified != after.modified) {
          throw const FileSystemException('Book changed during backup');
        }
        done += before.size;
        progress.send([done, total * 2]);
      }
      snapshot['files'] = hashes;
      final bytes = utf8.encode(jsonEncode(snapshot));
      encoder.addArchiveFile(ArchiveFile('backup.json', bytes.length, bytes));
    } finally {
      await encoder.close();
    }
  }

  Future<ValidatedBackup> validate(File file) async {
    final directory = await documents.createTemp('backup-stage-');
    try {
      final sourcePath = file.path;
      final stagingPath = directory.path;
      final extracted = await Isolate.run(
        () => _extractZip(sourcePath, stagingPath),
      );
      final names = extracted.$1;
      final data = extracted.$2;
      if (data['format'] != 'open-reading-backup' ||
          ![1, 2].contains(data['version']) ||
          data['schema'] != await database.getVersion()) {
        throw const FormatException('Unsupported backup version');
      }
      if (data['version'] == 2) {
        final scope = data['scope'];
        if (scope is! Map ||
            scope.length != 4 ||
            ![
              'reading',
              'statistics',
              'sources',
              'settings',
            ].every((k) => scope[k] is bool)) {
          throw const FormatException('Invalid backup scope');
        }
      }
      _validateSources(data['sources'] as String);
      final prefs = (data['preferences'] as Map).cast<String, dynamic>();
      for (final entry in prefs.entries) {
        final v = entry.value;
        if (!includesPreference(entry.key) ||
            !(v is String ||
                v is bool ||
                v is int ||
                v is double ||
                v is List && v.every((e) => e is String))) {
          throw const FormatException('Invalid backup setting');
        }
      }
      final hashes = (data['files'] as Map).cast<String, String>();
      if (names.length != hashes.length + 1 || !names.contains('backup.json')) {
        throw const FormatException('Incomplete backup');
      }
      for (final entry in hashes.entries) {
        if (!names.contains(entry.key) || entry.key == 'backup.json') {
          throw const FormatException('Missing backup file');
        }
        final digest = await sha256
            .bind(File(p.join(directory.path, entry.key)).openRead())
            .first;
        if (digest.toString() != entry.value) {
          throw const FormatException('Backup checksum mismatch');
        }
      }
      for (final identity in data['identities'] as List? ?? const []) {
        if (identity is! Map ||
            identity.length != 2 ||
            identity['key'] is! String ||
            !RegExp(
              r'^frozen_book_uid:[0-9]+$',
            ).hasMatch(identity['key'] as String) ||
            identity['value'] is! String) {
          throw const FormatException('Invalid book identity');
        }
      }
      final rows = (data['tables'] as Map).cast<String, dynamic>();
      if (rows.length != tables.length || !tables.every(rows.containsKey)) {
        throw const FormatException('Missing backup data');
      }
      for (final table in tables) {
        final columns = (await database.rawQuery(
          'PRAGMA table_info($table)',
        )).map((c) => c['name']).toSet();
        for (final row in rows[table] as List) {
          if (row is! Map ||
              row.keys.any((k) => !columns.contains(k)) ||
              row.values.any((v) => v != null && v is! String && v is! num)) {
            throw const FormatException('Invalid backup row');
          }
          if (table == 'books') {
            for (final column in ['filePath', 'cover_image_path']) {
              final value = row[column];
              if (value != null &&
                  !(column == 'filePath' &&
                      value == '' &&
                      (row['storage_type'] == 'online' ||
                          data['version'] == 2)) &&
                  !hashes.containsKey(value)) {
                throw const FormatException('Missing book file');
              }
            }
          }
        }
      }
      return ValidatedBackup(directory, data);
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static Future<(Set<String>, Map<String, dynamic>)> _extractZip(
    String sourcePath,
    String stagingPath,
  ) async {
    final input = InputFileStream(sourcePath);
    try {
      final archive = ZipDecoder().decodeBuffer(input);
      final names = <String>{};
      var total = 0;
      for (final entry in archive) {
        final name = entry.name;
        if (!entry.isFile ||
            entry.isSymbolicLink ||
            !names.add(name) ||
            name.contains('\\') ||
            name.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
            !(name == 'backup.json' ||
                name.startsWith('books/') ||
                name.startsWith('covers/'))) {
          throw const FormatException('Invalid backup entry');
        }
        total += entry.size;
        if (entry.size > 2 * 1024 * 1024 * 1024 ||
            total > 8 * 1024 * 1024 * 1024 ||
            (name == 'backup.json' && entry.size > 64 * 1024 * 1024)) {
          throw const FormatException('Backup exceeds supported size');
        }
        final target = File(p.join(stagingPath, name));
        await target.parent.create(recursive: true);
        final output = OutputFileStream(target.path);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      }
      final manifest = File(p.join(stagingPath, 'backup.json'));
      final data =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      return (names, data);
    } finally {
      await input.close();
    }
  }

  File get _journal =>
      File(p.join(documents.path, 'backups', 'restore-pending.json'));

  Future<bool> recoverInterruptedRestore() async {
    if (!await _journal.exists()) return false;
    final data = jsonDecode(await _journal.readAsString()) as Map;
    await database.execute(
      'CREATE TABLE IF NOT EXISTS backup_restore_commit(id TEXT PRIMARY KEY)',
    );
    final committed = (await database.query(
      'backup_restore_commit',
      where: 'id = ?',
      whereArgs: [data['id']],
    )).isNotEmpty;
    final state = data[committed ? 'after' : 'before'] as Map;
    await _replacePreferences(
      (state['preferences'] as Map).cast<String, Object?>(),
    );
    await _writeSources(state['sources'] as String);
    await _journal.delete();
    return committed;
  }

  Future<void> restore(
    ValidatedBackup backup, {
    RestoreSelection? selection,
  }) async {
    // New files have a unique root; existing library files are never overwritten.
    final id = const Uuid().v4();
    final moved = <Directory>[];
    final beforePrefs = {
      for (final key in preferences.getKeys())
        if (includesPreference(key)) key: preferences.get(key),
    };
    if (selection?.isEmpty == true) throw StateError('Select restore content');
    final originalScope = backup.data['scope'] as Map?;
    final scope = selection == null
        ? originalScope
        : <String, Object>{
            'reading': selection.reading && originalScope?['reading'] != false,
            'statistics':
                selection.statistics && originalScope?['statistics'] != false,
            'sources': selection.sources && originalScope?['sources'] != false,
            'settings':
                selection.settings && originalScope?['settings'] != false,
            'files': selection.files,
            'overwrite': selection.overwrite,
          };
    final afterPrefs = scope?['settings'] == false
        ? beforePrefs
        : scope?['overwrite'] == false
        ? {...(backup.data['preferences'] as Map), ...beforePrefs}
        : backup.data['preferences'];
    final beforeSources =
        await sources.read() ??
        preferences.getString(sourceKey) ??
        '{"version":2,"sources":[],"groups":[]}';
    final afterSources =
        scope?['sources'] == false ||
            (scope?['overwrite'] == false && _hasSources(beforeSources))
        ? beforeSources
        : backup.data['sources'];
    await database.execute(
      'CREATE TABLE IF NOT EXISTS backup_restore_commit(id TEXT PRIMARY KEY)',
    );
    await _journal.parent.create(recursive: true);
    final journalTemp = File('${_journal.path}.tmp');
    await journalTemp.writeAsString(
      jsonEncode({
        'id': id,
        'before': {'preferences': beforePrefs, 'sources': beforeSources},
        'after': {'preferences': afterPrefs, 'sources': afterSources},
      }),
      flush: true,
    );
    await journalTemp.rename(_journal.path);
    try {
      for (final kind in ['books', 'covers']) {
        if (scope?['reading'] == false || scope?['files'] == false) continue;
        final staged = Directory(p.join(backup.directory.path, kind));
        if (!await staged.exists()) continue;
        final target = Directory(p.join(documents.path, kind, 'restored-$id'));
        await target.parent.create(recursive: true);
        await staged.rename(target.path);
        moved.add(target);
      }
      final rows = (backup.data['tables'] as Map).cast<String, dynamic>();
      await database.transaction((tx) async {
        if (scope != null) {
          await _restoreSelected(tx, backup, id, scope);
        } else {
          for (final table in tables.reversed) {
            await tx.delete(table);
          }
          for (final table in tables) {
            for (final original in rows[table] as List) {
              final row = Map<String, Object?>.from(original as Map);
              if (table == 'books') {
                for (final key in ['filePath', 'cover_image_path']) {
                  final value = row[key];
                  if (value is String && value.isNotEmpty) {
                    final parts = value.split('/');
                    row[key] =
                        '${parts.first}/restored-$id/${parts.skip(1).join('/')}';
                  }
                }
              }
              await tx.insert(table, row);
            }
          }
          if ((await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
            throw const FormatException('Invalid backup references');
          }
          // Old sync state must not bind restored book ids to previous identities.
          final legacy = await tx.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'sync_%'",
          );
          for (final table in legacy) {
            final name = table['name'] as String;
            if (RegExp(r'^sync_[a-z_]+$').hasMatch(name)) await tx.delete(name);
          }
          await tx.execute(
            'CREATE TABLE IF NOT EXISTS sync_local_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          for (final identity
              in (backup.data['identities'] as List? ?? const [])) {
            await tx.insert(
              'sync_local_state',
              Map<String, Object?>.from(identity as Map),
            );
          }
        }
        await tx.delete('backup_restore_commit');
        await tx.insert('backup_restore_commit', {'id': id});
        await _replacePreferences((afterPrefs as Map).cast<String, Object?>());
        await _writeSources(afterSources as String);
      });
    } catch (_) {
      if (await recoverInterruptedRestore()) return;
      for (final dir in moved) {
        await dir.delete(recursive: true);
      }
      rethrow;
    }
    // Once committed, a cleanup failure must not be reported as a failed restore.
    try {
      await _journal.delete();
    } catch (_) {}
  }

  Future<void> _restoreSelected(
    Transaction tx,
    ValidatedBackup backup,
    String operation,
    Map scope,
  ) async {
    final rows = backup.data['tables'] as Map;
    final mapping = <int, int>{};
    final skipped = <int>{};
    await tx.execute(
      'CREATE TABLE IF NOT EXISTS sync_local_state(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    final identities = <int, String>{
      for (final row in backup.data['identities'] as List? ?? const [])
        int.parse((row['key'] as String).split(':').last):
            row['value'] as String,
    };
    final localIds = <String, int>{
      for (final row in await tx.query(
        'sync_local_state',
        where: 'key LIKE ?',
        whereArgs: ['frozen_book_uid:%'],
      ))
        row['value'] as String: int.parse(
          (row['key'] as String).split(':').last,
        ),
    };
    if (scope['reading'] == true) {
      for (final original in rows['books'] as List) {
        final row = Map<String, Object?>.from(original as Map);
        final oldId = row.remove('id') as int;
        final uid =
            identities[oldId] ??
            'legacy-backup-${backup.data['createdAt']}-$oldId';
        final existing = localIds[uid] == null
            ? <Map<String, Object?>>[]
            : await tx.query(
                'books',
                where: 'id = ?',
                whereArgs: [localIds[uid]],
              );
        if (existing.isNotEmpty && scope['overwrite'] == false) {
          mapping[oldId] = existing.single['id'] as int;
          skipped.add(oldId);
          continue;
        }
        for (final key in ['filePath', 'cover_image_path']) {
          if (scope['files'] == false) row[key] = key == 'filePath' ? '' : null;
          final value = row[key];
          if (value is String && value.isNotEmpty) {
            final parts = value.split('/');
            row[key] =
                '${parts.first}/restored-$operation/${parts.skip(1).join('/')}';
          } else if (existing.isNotEmpty) {
            row[key] = existing.single[key];
          } else if (key == 'filePath' && row['storage_type'] != 'online') {
            // A portable placeholder; the source device path must never be opened.
            row[key] = 'books/missing-${const Uuid().v4()}';
          }
        }
        final int newId;
        if (existing.isNotEmpty) {
          newId = existing.single['id'] as int;
          await tx.update('books', row, where: 'id = ?', whereArgs: [newId]);
        } else {
          newId = await tx.insert('books', row);
        }
        mapping[oldId] = newId;
        await tx.insert('sync_local_state', {
          'key': 'frozen_book_uid:$newId',
          'value': uid,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final table in ['bookmarks', 'book_notes']) {
        final fk = table == 'bookmarks' ? 'bookId' : 'book_id';
        for (final id
            in mapping.entries
                .where((e) => !skipped.contains(e.key))
                .map((e) => e.value)) {
          await tx.delete(table, where: '$fk = ?', whereArgs: [id]);
        }
        for (final original in rows[table] as List) {
          final row = Map<String, Object?>.from(original as Map)..remove('id');
          if (skipped.contains(row[fk])) continue;
          if (!mapping.containsKey(row[fk])) {
            throw const FormatException('Invalid book reference');
          }
          row[fk] = mapping[row[fk]];
          await tx.insert(table, row);
        }
      }
    }
    if (scope['statistics'] == true &&
        (scope['overwrite'] != false ||
            ((await tx.query('reading_stats', limit: 1)).isEmpty &&
                (await tx.query('reading_sessions', limit: 1)).isEmpty))) {
      for (final table in ['reading_stats', 'reading_sessions']) {
        await tx.delete(table);
        for (final original in rows[table] as List) {
          final row = Map<String, Object?>.from(original as Map);
          if (table == 'reading_sessions') {
            final old = row['bookId'];
            row['bookId'] = mapping[old] ?? localIds[identities[old]];
          }
          await tx.insert(table, row);
        }
      }
    }
    if ((await tx.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
      throw const FormatException('Invalid backup references');
    }
  }

  Future<void> _writeSources(String raw) async {
    final external = await sources.read() != null;
    if (await sources.write(raw)) {
      if (!await preferences.remove(sourceKey)) {
        throw StateError('Could not save sources');
      }
    } else if (external || !await preferences.setString(sourceKey, raw)) {
      throw StateError('Could not save sources');
    }
  }

  Future<void> _replacePreferences(Map<String, Object?> values) async {
    for (final key in preferences.getKeys().where(includesPreference)) {
      if (!values.containsKey(key) && !await preferences.remove(key)) {
        throw StateError('Could not restore settings');
      }
    }
    for (final entry in values.entries) {
      final v = entry.value;
      final ok = switch (v) {
        String v => await preferences.setString(entry.key, v),
        bool v => await preferences.setBool(entry.key, v),
        int v => await preferences.setInt(entry.key, v),
        double v => await preferences.setDouble(entry.key, v),
        List v => await preferences.setStringList(entry.key, v.cast<String>()),
        _ => false,
      };
      if (!ok) throw StateError('Could not restore settings');
    }
  }

  static bool _hasSources(String raw) {
    final data = jsonDecode(raw);
    return data is List
        ? data.isNotEmpty
        : ((data as Map)['sources'] as List).isNotEmpty ||
              (data['groups'] as List? ?? const []).isNotEmpty;
  }

  static void _validateSources(String raw) {
    final value = jsonDecode(raw);
    if (value is! List && !(value is Map && value['sources'] is List)) {
      throw const FormatException('Invalid sources');
    }
    final items = value is List ? value : value['sources'] as List;
    for (final item in items) {
      RegisteredBookSource.fromJson((item as Map).cast<String, dynamic>());
    }
  }
}

class ValidatedBackup {
  ValidatedBackup(this.directory, this.data);
  final Directory directory;
  final Map<String, dynamic> data;
}
