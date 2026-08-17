# Book Import Path Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the unused legacy single-file import path so every in-repository book import uses the tested `BookFileImporter.importFile` contract.

**Architecture:** Keep `BookImportService.importFile` as the single import transaction for desktop/mobile and web sources. File selection remains in `BookImportSourceService` and UI orchestration remains in `ImportBookController`; `BookImportService` owns materialization, hash verification, metadata extraction, persistence, rollback, and post-import analysis scheduling.

**Tech Stack:** Flutter, Dart, `flutter_test`, `file_picker`, `sqflite`, local filesystem APIs.

## Global Constraints

- Preserve all existing `importFile` behavior and public `BookFileImporter` interfaces.
- Do not modify synced files under the ChatGPT project mirror `sources/`.
- Do not add dependencies.
- Preserve unrelated working-tree changes.
- Treat repository-external callers of `BookImportService.importBook` as unknown; repository search is the available compatibility boundary.

---

## Scope and evidence

- `BookImportService.importFile` is used by `ImportBookController`, `IncomingBookService`, and `WebDavBookFileService`.
- `BookImportService.importBook` has no callers under `lib/` or `test/`.
- The legacy path duplicates file picking, size validation, hashing, duplicate detection, copying, metadata extraction, persistence, and AI scheduling.
- The legacy path bypasses the injected `BookImportStore` through a private `BookDao`, while the active path uses the injected store.
- Existing regression tests cover duplicate skipping, managed-in-place sources, rollback cleanup, and large-file hash consistency.

## Fallback classification

- Legacy `importBook`: **masking fallback slop**. It is an alternate untested execution path with different persistence and failure semantics. Repository search found no remaining caller, so no escalation is required before deletion.
- Metadata fallbacks below `_extractEnhancedMetadataFromFile`: **grounded compatibility/fail-safe fallbacks**. They handle malformed or partially supported ebook formats and remain outside this cleanup pass.
- Best-effort rollback logging: **grounded fail-safe behavior**. It preserves the primary failure while reporting cleanup failure and remains unchanged.

### Task 1: Lock the active import transaction

**Files:**
- Test: `test/book_import_service_test.dart`

**Interfaces:**
- Consumes: `BookImportService.importFile(BookImportSource, {BookImportProgress? onProgress})`
- Produces: Regression evidence for the active import transaction.

- [x] **Step 1: Run the focused regression suite before cleanup**

Run:

```bash
flutter test test/book_import_service_test.dart
```

Expected: four tests pass, covering duplicate handling, managed sources, rollback, and large-file hashing.

- [x] **Step 2: Re-run the same suite after cleanup**

Run:

```bash
flutter test test/book_import_service_test.dart
```

Expected: the same four tests pass without behavior changes.

### Task 2: Delete the alternate import path

**Files:**
- Modify: `lib/services/books/book_import_service.dart`

**Interfaces:**
- Consumes: Existing `BookFileImporter` contract from `book_import_models.dart`.
- Produces: One in-repository book import transaction, `BookImportService.importFile`.

- [x] **Step 1: Remove legacy-only imports and state**

Delete the `file_picker` import and the private `_bookDao` field. Keep `BookDao` imported because it remains the default `BookImportStore` implementation.

- [x] **Step 2: Remove legacy-only helpers**

Delete:

```dart
Future<String?> _calculateFileHash(String filePath)
Future<Book?> _checkDuplicateByHash(String hash)
```

The active path uses `_calculateRequiredHash` and `_store.getBookByHash` directly.

- [x] **Step 3: Remove the unused public legacy method**

Delete:

```dart
Future<Book?> importBook({ImportProgressCallback? progressCallback})
```

Do not change metadata extraction helpers shared by `importFile`.

- [x] **Step 4: Format the modified Dart file**

Run:

```bash
dart format lib/services/books/book_import_service.dart
```

Expected: formatter completes without errors.

### Task 3: Verify the consolidation

**Files:**
- Verify: `lib/services/books/book_import_service.dart`
- Verify: `test/book_import_service_test.dart`

**Interfaces:**
- Consumes: The consolidated service from Task 2.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Confirm no legacy symbol or duplicate caller remains**

Run:

```bash
rg -n "importBook\(|_calculateFileHash|_checkDuplicateByHash|_bookDao|FilePicker" lib/services/books/book_import_service.dart lib test
```

Expected: no result associated with the removed `BookImportService` path; unrelated uses in other services are acceptable.

- [x] **Step 2: Run focused static analysis**

Run:

```bash
flutter analyze lib/services/books/book_import_service.dart test/book_import_service_test.dart
```

Expected: no issues found.

- [x] **Step 3: Run the focused regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart
```

Expected: all tests pass.

## Deferred independent plans

The following areas require separate behavior locks and should not be bundled into this deletion pass:

1. `SettingsPage` state/persistence boundary consolidation.
2. Canonical locator serialization and compatibility test expansion.
3. AI provider storage, protocol adapter, and HTTP transport separation.
