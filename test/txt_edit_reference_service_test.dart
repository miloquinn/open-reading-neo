import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/core/reader/canonical_locator.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/txt_edit_reference_service.dart';
import 'package:xxread/services/books/txt_edit_service.dart';

void main() {
  late Database database;

  setUp(() async {
    sqfliteFfiInit();
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY, title TEXT, author TEXT, filePath TEXT,
        format TEXT, currentPage INTEGER, totalPages INTEGER,
        reading_progress REAL, importDate INTEGER, cached_content TEXT,
        cached_pages TEXT, file_modified_time INTEGER, content_hash TEXT,
        table_of_contents TEXT, cover_image_path TEXT, text_encoding TEXT,
        last_canonical_locator TEXT, last_rendered_locator TEXT,
        layout_signature TEXT, storage_type TEXT, source_id TEXT,
        source_book_id TEXT, source_json TEXT, source_book_json TEXT,
        source_kind TEXT, source_locator TEXT, source_modified_time INTEGER
      )
    ''');
    await database.execute('''
      CREATE TABLE book_notes (
        id INTEGER PRIMARY KEY, book_id INTEGER, content TEXT, cfi TEXT,
        canonical_locator TEXT, payload_json TEXT, chapter TEXT, type TEXT,
        color TEXT, reader_note TEXT, page_number INTEGER,
        start_offset INTEGER, end_offset INTEGER, create_time TEXT,
        update_time TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE bookmarks (
        id INTEGER PRIMARY KEY, bookId INTEGER, pageNumber INTEGER,
        note TEXT, createDate INTEGER, cfi TEXT, canonical_locator TEXT,
        anchor_key TEXT, chapter_index INTEGER, chapter_title TEXT,
        excerpt TEXT
      )
    ''');
    await database.execute('''
      CREATE TABLE sync_local_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  });

  tearDown(() => database.close());

  String locator(String quote, int offset, {String chapterId = 'txt-0'}) =>
      LocatorCodec.encodeCanonicalLocator(
        CanonicalLocator.fromComponents(
          format: BookFormat.txt,
          chapterId: chapterId,
          offset: offset,
          excerpt: quote,
        ),
      );

  test(
    'maps verified references and marks overlapping references unresolved',
    () async {
      final book = Book(
        id: 1,
        title: '书',
        filePath: '/tmp/book.txt',
        format: 'txt',
        contentHash: 'old',
        lastCanonicalLocator: locator('omega', 13),
      );
      await database.insert('books', book.toMap());
      await database.insert('book_notes', <String, Object?>{
        'id': 1,
        'book_id': 1,
        'content': 'omega',
        'cfi': 'old',
        'canonical_locator': locator('omega', 13),
        'payload_json': null,
        'chapter': '第一章',
        'type': 'highlight',
        'color': 'yellow',
        'start_offset': 13,
        'end_offset': 18,
        'create_time': DateTime(2026).toIso8601String(),
        'update_time': DateTime(2026).toIso8601String(),
      });
      await database.insert('book_notes', <String, Object?>{
        'id': 2,
        'book_id': 1,
        'content': 'CHANGE',
        'cfi': 'old',
        'canonical_locator': locator('CHANGE', 6),
        'payload_json': jsonEncode(<String, Object>{'kept': true}),
        'chapter': '第一章',
        'type': 'highlight',
        'color': 'yellow',
        'start_offset': 6,
        'end_offset': 12,
        'create_time': DateTime(2026).toIso8601String(),
        'update_time': DateTime(2026).toIso8601String(),
      });
      await database.insert('bookmarks', <String, Object?>{
        'id': 1,
        'bookId': 1,
        'pageNumber': 0,
        'note': '',
        'createDate': 0,
        'canonical_locator': locator('CHANGE', 6),
        'anchor_key': 'txt-0:6',
        'chapter_index': 0,
        'chapter_title': '第一章',
        'excerpt': 'CHANGE',
      });
      final service = TxtEditReferenceService(
        databaseProvider: () async => database,
      );
      final updated = await service.commitRevision(
        book: book,
        commit: TxtEditCommit(
          contentHash: 'new',
          modifiedAt: DateTime(2026, 9, 5),
          textEncoding: 'utf8',
          mapping: const TxtEditRevisionMapping(
            chapterId: 'txt-0',
            oldLength: 18,
            oldText: 'alpha CHANGE omega',
            newText: 'alpha NEW omega',
            commonPrefixLength: 6,
            commonSuffixLength: 6,
          ),
        ),
      );

      final bookLocator = LocatorCodec.decodeCanonicalLocator(
        updated.lastCanonicalLocator!,
      );
      expect(bookLocator!.textAnchor!.startOffsetUtf16, 10);
      expect(bookLocator.contentSignature, 'new');
      expect(updated.textEncoding, 'utf8');
      expect(updated.lastRenderedLocator, isNull);
      final notes = await database.query('book_notes', orderBy: 'id');
      expect(notes[0]['start_offset'], 10);
      expect(notes[0]['end_offset'], 15);
      expect(notes[1]['canonical_locator'], isNull);
      expect(
        isTxtNoteLocatorResolved(Map<String, dynamic>.from(notes[1])),
        isFalse,
      );
      expect(notes[1]['content'], 'CHANGE');
      final bookmarks = await database.query('bookmarks');
      expect(
        isTxtBookmarkLocatorResolved(bookmarks.single['anchor_key'] as String?),
        isFalse,
      );
      expect(bookmarks.single['excerpt'], 'CHANGE');
    },
  );

  test(
    'rewrites the existing progress event for the new TXT revision',
    () async {
      final book = Book(
        id: 1,
        title: '书',
        filePath: '/tmp/book.txt',
        format: 'txt',
        currentPage: 0,
        readingProgress: 0.4,
        contentHash: 'old',
        lastCanonicalLocator: locator('omega', 13),
      );
      await database.insert('books', book.toMap());
      await database.insert('sync_local_state', {
        'key': 'frozen_book_uid:1',
        'value': 'book-uid',
      });
      final oldEvent = jsonEncode({
        'current_page': 0,
        'reading_progress': 0.4,
        'canonical_locator': book.lastCanonicalLocator,
        'event_id': 'read-event',
        'device_id': 'device-a',
        'device_sequence': 1,
        'vector': {'device-a': 1},
      });
      for (final prefix in const ['progress_event:', 'progress_head:']) {
        await database.insert('sync_local_state', {
          'key': '${prefix}book-uid',
          'value': oldEvent,
        });
      }

      await TxtEditReferenceService(
        databaseProvider: () async => database,
      ).commitRevision(
        book: book,
        commit: TxtEditCommit(
          contentHash: 'new',
          modifiedAt: DateTime(2026, 9, 5),
          textEncoding: 'utf8',
          mapping: const TxtEditRevisionMapping(
            chapterId: 'txt-0',
            oldLength: 18,
            oldText: 'alpha CHANGE omega',
            newText: 'alpha NEW omega',
            commonPrefixLength: 6,
            commonSuffixLength: 6,
          ),
        ),
      );

      final raw =
          (await database.query(
                'sync_local_state',
                where: 'key = ?',
                whereArgs: ['progress_event:book-uid'],
              )).single['value']!
              as String;
      final event = (jsonDecode(raw) as Map).cast<String, dynamic>();
      final mapped = LocatorCodec.decodeCanonicalLocator(
        event['canonical_locator'] as String,
      );
      expect(event['event_id'], 'read-event');
      expect(event['vector'], {'device-a': 1});
      expect(event['locator_revision'], 'new');
      expect(mapped!.contentSignature, 'new');
      expect(mapped.textAnchor!.startOffsetUtf16, 10);
    },
  );

  test(
    'does not retarget an overlapping quote to another occurrence',
    () async {
      final book = Book(
        id: 3,
        title: '书',
        filePath: '/tmp/book.txt',
        format: 'txt',
      );
      await database.insert('books', book.toMap());
      await database.insert('book_notes', <String, Object?>{
        'id': 4,
        'book_id': 3,
        'content': 'TARGET',
        'cfi': 'old',
        'canonical_locator': locator('TARGET', 2),
        'chapter': '第一章',
        'type': 'highlight',
        'color': 'yellow',
        'start_offset': 2,
        'end_offset': 8,
        'create_time': DateTime(2026).toIso8601String(),
        'update_time': DateTime(2026).toIso8601String(),
      });
      final service = TxtEditReferenceService(
        databaseProvider: () async => database,
      );

      await service.commitRevision(
        book: book,
        commit: TxtEditCommit(
          contentHash: 'new',
          modifiedAt: DateTime(2026, 9, 5),
          textEncoding: 'utf8',
          mapping: const TxtEditRevisionMapping(
            chapterId: 'txt-0',
            oldLength: 19,
            oldText: '前 TARGET 中 TARGET 后',
            newText: '前  中 TARGET 后',
            commonPrefixLength: 2,
            commonSuffixLength: 11,
          ),
        ),
      );

      final note = (await database.query('book_notes')).single;
      expect(note['canonical_locator'], isNull);
      expect(note['content'], 'TARGET');
      expect(
        isTxtNoteLocatorResolved(Map<String, dynamic>.from(note)),
        isFalse,
      );
    },
  );

  test(
    'whole-file restore preserves excerpts but invalidates every locator',
    () async {
      final book = Book(
        id: 2,
        title: '书',
        filePath: '/tmp/book.txt',
        format: 'txt',
        contentHash: 'current',
        lastCanonicalLocator: locator('omega', 13),
      );
      await database.insert('books', book.toMap());
      await database.insert('book_notes', <String, Object?>{
        'id': 3,
        'book_id': 2,
        'content': '保留摘录',
        'cfi': 'old',
        'canonical_locator': locator('omega', 13),
        'chapter': '第一章',
        'type': 'highlight',
        'color': 'yellow',
        'start_offset': 13,
        'end_offset': 18,
        'create_time': DateTime(2026).toIso8601String(),
        'update_time': DateTime(2026).toIso8601String(),
      });
      await database.insert('bookmarks', <String, Object?>{
        'id': 2,
        'bookId': 2,
        'pageNumber': 0,
        'note': '',
        'createDate': 0,
        'canonical_locator': locator('omega', 13),
        'anchor_key': 'txt-0:13',
        'chapter_index': 0,
        'chapter_title': '第一章',
        'excerpt': 'omega',
      });
      final service = TxtEditReferenceService(
        databaseProvider: () async => database,
      );

      final updated = await service.commitRevision(
        book: book,
        commit: TxtEditCommit(
          contentHash: 'restored',
          modifiedAt: DateTime(2026, 9, 5),
          textEncoding: 'utf8',
          invalidateAllReferences: true,
        ),
      );

      expect(updated.lastCanonicalLocator, isNull);
      final note = (await database.query('book_notes')).single;
      expect(note['content'], '保留摘录');
      expect(note['canonical_locator'], isNull);
      expect(
        isTxtNoteLocatorResolved(Map<String, dynamic>.from(note)),
        isFalse,
      );
      final bookmark = (await database.query('bookmarks')).single;
      expect(bookmark['excerpt'], 'omega');
      expect(
        isTxtBookmarkLocatorResolved(bookmark['anchor_key'] as String?),
        isFalse,
      );
    },
  );

  test(
    'invalidates references in bounded parts shifted by an earlier edit',
    () async {
      final precedingLocator = locator('HEAD', 4);
      final shiftedLocator = locator('TAIL', 12, chapterId: 'txt-0-part-2');
      final book = Book(
        id: 4,
        title: '书',
        filePath: '/tmp/book.txt',
        format: 'txt',
        lastCanonicalLocator: shiftedLocator,
      );
      await database.insert('books', book.toMap());
      await database.insert('book_notes', <String, Object?>{
        'id': 5,
        'book_id': 4,
        'content': 'TAIL',
        'cfi': 'old',
        'canonical_locator': shiftedLocator,
        'chapter': '第一章 · 2/2',
        'type': 'highlight',
        'color': 'yellow',
        'start_offset': 12,
        'end_offset': 16,
        'create_time': DateTime(2026).toIso8601String(),
        'update_time': DateTime(2026).toIso8601String(),
      });
      await database.insert('book_notes', <String, Object?>{
        'id': 6,
        'book_id': 4,
        'content': 'HEAD',
        'cfi': 'old',
        'canonical_locator': precedingLocator,
        'chapter': '第一章',
        'type': 'highlight',
        'color': 'yellow',
        'start_offset': 4,
        'end_offset': 8,
        'create_time': DateTime(2026).toIso8601String(),
        'update_time': DateTime(2026).toIso8601String(),
      });
      await database.insert('bookmarks', <String, Object?>{
        'id': 3,
        'bookId': 4,
        'pageNumber': 1,
        'note': '',
        'createDate': 0,
        'canonical_locator': shiftedLocator,
        'anchor_key': 'txt-0-part-2:12',
        'chapter_index': 2,
        'chapter_title': '第一章 · 3/3',
        'excerpt': 'TAIL',
      });

      final updated =
          await TxtEditReferenceService(
            databaseProvider: () async => database,
          ).commitRevision(
            book: book,
            commit: TxtEditCommit(
              contentHash: 'new-bounded-revision',
              modifiedAt: DateTime(2026, 9, 5),
              textEncoding: 'utf8',
              mapping: const TxtEditRevisionMapping(
                chapterId: 'txt-0-part-1',
                oldLength: 8,
                oldText: 'HEADBODY',
                newText: 'HEADBODY',
                commonPrefixLength: 8,
                commonSuffixLength: 0,
                invalidatedChapterIds: <String>['txt-0-part-2'],
              ),
            ),
          );

      expect(updated.lastCanonicalLocator, isNull);
      final notes = await database.query('book_notes', orderBy: 'id');
      expect(notes[0]['content'], 'TAIL');
      expect(notes[0]['canonical_locator'], isNull);
      expect(
        isTxtNoteLocatorResolved(Map<String, dynamic>.from(notes[0])),
        isFalse,
      );
      expect(notes[1]['canonical_locator'], precedingLocator);
      expect(
        isTxtNoteLocatorResolved(Map<String, dynamic>.from(notes[1])),
        isTrue,
      );
      final bookmark = (await database.query('bookmarks')).single;
      expect(bookmark['excerpt'], 'TAIL');
      expect(bookmark['canonical_locator'], isNull);
      expect(
        isTxtBookmarkLocatorResolved(bookmark['anchor_key'] as String?),
        isFalse,
      );
    },
  );
}
