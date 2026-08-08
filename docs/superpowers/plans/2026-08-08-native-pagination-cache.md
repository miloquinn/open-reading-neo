# Native Pagination Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Execute this plan task-by-task with regression gates between schema, codec, and reader integration.

**Goal:** Persist exact local-reader page boundaries so reopening an unchanged book with an identical layout skips synchronous `TextPainter` pagination.

**Architecture:** Add a versioned SQLite cache table keyed by book revision and the existing complete `ReaderLayoutFingerprint`. Store compact binary page-boundary payloads rather than page text, then rebuild `ReaderTextLayout` from canonical chapter text so annotations, generated indentation, rich EPUB spans, and canonical offsets remain correct. Load all matching rows before the reader becomes renderable; writes run asynchronously through an ordered queue and old revisions are pruned.

**Tech Stack:** Flutter/Dart, sqflite, `ByteData`, existing `ReaderTextLayout`, existing native reader part files.

**Execution status:** Completed and verified on 2026-08-08.

## Global Constraints

- Do not modify `lib/book_sources/**`, `lib/pages/book_sources/**`, their tests, or the other AI's localization changes.
- Do not add dependencies.
- Preserve exact `TextPainter` pagination behavior and all canonical/display offset mappings.
- Never perform SQLite reads or JSON decoding synchronously from a widget build.
- Cache failures must fall back to normal pagination and must never block opening a book.
- Keep cache storage bounded and delete entries when a book is deleted.

---

### Task 1: Versioned pagination cache schema and DAO

**Files:**
- Create: `lib/data/migration/pagination_cache_schema_migration.dart`
- Create: `lib/services/books/pagination_cache_dao.dart`
- Modify: `lib/services/core/database_service.dart`
- Test: `test/pagination_cache_dao_test.dart`

**Interfaces:**
- Produces: `PaginationCacheDao.loadForBook(int bookId, String bookRevision)` returning `Map<String, Uint8List>`.
- Produces: `PaginationCacheDao.upsert(...)`, `deleteForBook(int bookId)`, and bounded pruning.

- [ ] **Step 1: Write a failing DAO test**

Create a temporary SQLite database with the migration, insert two layout payloads, verify round-trip bytes, replace one payload, load only the requested book revision, and confirm deletion removes all rows for the book.

- [ ] **Step 2: Run the DAO test and verify it fails**

Run: `flutter test test/pagination_cache_dao_test.dart`

Expected: compilation failure because the migration and DAO do not exist.

- [ ] **Step 3: Add schema migration**

Create `reader_pagination_cache` with:

```sql
book_id INTEGER NOT NULL,
book_revision TEXT NOT NULL,
layout_fingerprint TEXT NOT NULL,
chapter_index INTEGER NOT NULL,
payload BLOB NOT NULL,
updated_at INTEGER NOT NULL,
PRIMARY KEY (book_id, book_revision, layout_fingerprint),
FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
```

Add indexes for `(book_id, book_revision)` and pruning by `(book_id, updated_at DESC)`. Raise the database version to 22 and invoke the migration from both creation and upgrade paths.

- [ ] **Step 4: Add the DAO**

Use injected `Future<Database> Function()` in tests and `DatabaseService().database` by default. Upsert with conflict replacement, remove stale revisions before loading/writing, and retain at most 128 layouts per book.

- [ ] **Step 5: Run the DAO test**

Run: `flutter test test/pagination_cache_dao_test.dart`

Expected: all tests pass.

### Task 2: Lossless page-boundary codec

**Files:**
- Modify: `lib/core/reader/reader_text_pagination.dart`
- Create: `lib/pages/reader/native/native_reader_pagination_cache.dart`
- Modify: `lib/pages/reader/native/native_reader_page.dart`
- Modify: `lib/pages/reader/native/native_reader_chapter.dart`
- Test: `test/native_reader_pagination_cache_test.dart`

**Interfaces:**
- Adds `layoutStart` and `layoutEnd` to `ReaderTextPage`, representing the owned display-text range before folded whitespace is hidden.
- Produces private `_encodeNativePagination(...)` and `_restoreNativePagination(...)` functions in the native reader library.

- [ ] **Step 1: Write codec round-trip tests**

Cover plain TXT with generated indentation and paragraph spacing, a dedicated chapter-title page, EPUB-style rich spans, and an image-bearing page. Assert the restored pages retain page text, canonical start/end offsets, visible display ranges, image block indexes, title flags, and selection mapping.

- [ ] **Step 2: Run the codec test and verify it fails**

Run: `flutter test test/native_reader_pagination_cache_test.dart`

Expected: compilation failure because the codec does not exist.

- [ ] **Step 3: Preserve ownership boundaries in `ReaderTextPage`**

Set `layoutStart: range.start` and `layoutEnd: range.end` in `paginateReaderText`. Existing manually constructed pages default to their visible range, preserving compatibility.

- [ ] **Step 4: Implement compact binary codec**

Use a fixed header containing magic, format version, and page count followed by fixed-width signed 32-bit records. Each record stores flags, image index, layout source start/end, owned display start/end, visible display start/end, and canonical source start/end. Validate every count, range, and chapter boundary before accepting a payload.

- [ ] **Step 5: Rebuild layouts from canonical chapter text**

Group cached pages by `(layoutSourceStart, layoutSourceEnd)`, call `ReaderTextLayout.build` once per group with the current indent/spacing/normalization parameters, then rebuild `_ReaderPageData`. Return `null` for any invalid payload so the caller repaginates normally.

- [ ] **Step 6: Run codec and existing pagination tests**

Run:

```bash
flutter test test/native_reader_pagination_cache_test.dart
flutter test test/native_text_paginator_test.dart
flutter test test/reader_text_layout_mapping_test.dart
```

Expected: all tests pass in separate processes.

### Task 3: Native reader cache lifecycle integration

**Files:**
- Modify: `lib/pages/reader/native/native_reader_loading.dart`
- Modify: `lib/pages/reader/native/native_reader_page_cache.dart`
- Modify: `lib/pages/reader/native/native_reader_controls.dart`
- Modify: `lib/services/books/book_dao.dart`
- Test: `test/native_reader_pagination_persistence_test.dart`

**Interfaces:**
- Consumes: DAO and binary codec from Tasks 1–2.
- Produces: cold-open restoration before `_pagesFor` executes and ordered background persistence after a real pagination miss.

- [ ] **Step 1: Write persistence behavior test**

Open a local fixture, wait for pagination, dispose it, clear the process memory cache, reopen using the same database row and assert `onPaginationCacheMiss` is not called. Change a pagination setting and assert exactly one miss occurs. Corrupt the stored payload and assert normal pagination succeeds and replaces the bad row.

- [ ] **Step 2: Run the persistence test and verify it fails**

Run: `flutter test test/native_reader_pagination_persistence_test.dart`

Expected: reopening reports a pagination miss because only memory caching exists.

- [ ] **Step 3: Load persisted payloads during dependency preparation**

Await one DAO query alongside chapter preparation when `book.id != null`. Use a SHA-1 revision derived from `_bookCacheKey`. Keep payload bytes in a reader-owned map; do not place database access in `_pagesFor`.

- [ ] **Step 4: Restore before computing and persist after misses**

In `_pagesFor`, attempt validated restoration before invoking `_paginateChapter`. On a miss, paginate exactly as before, update memory immediately, encode synchronously from integer metadata, and enqueue the SQLite upsert without awaiting it.

- [ ] **Step 5: Invalidate on replacement-rule changes and deletion**

Clear reader-owned payloads and delete the book's persistent cache when replacement rules change. Ensure normal book deletion relies on the foreign-key cascade and explicitly clears cache for database implementations where needed.

- [ ] **Step 6: Run reader regression tests**

Run each in a separate Flutter process:

```bash
flutter test test/native_reader_pagination_persistence_test.dart
flutter test test/native_reader_epub_chapter_transition_test.dart
flutter test test/native_text_paginator_test.dart
flutter test test/reader_text_layout_mapping_test.dart
flutter analyze lib/core/reader lib/pages/reader/native lib/services/books/pagination_cache_dao.dart lib/data/migration/pagination_cache_schema_migration.dart
```

Expected: all tests pass and analysis reports no issues in changed scope.

### Task 4: Cleanup and bounded-storage verification

**Files:**
- Modify only files already touched if cleanup is necessary.
- Test: `test/pagination_cache_dao_test.dart`

- [ ] **Step 1: Remove obsolete or duplicated helpers introduced during implementation**

Keep one binary validation path, one revision computation path, and one ordered write queue. Do not retain compatibility code for a cache format that has never shipped.

- [ ] **Step 2: Verify pruning and corruption fallback**

Run the DAO and persistence tests with more than 128 generated layout keys and with truncated/malformed payloads. Confirm storage remains bounded and the reader falls back without surfacing an exception.

- [ ] **Step 3: Review the diff boundary**

Run `git diff --name-only` and confirm no file under `lib/book_sources/`, `lib/pages/book_sources/`, or their tests appears in this task's staged set.
