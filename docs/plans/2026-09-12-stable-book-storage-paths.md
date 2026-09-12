# Stable managed book and cover paths

The first fix repaired absolute paths when the library loaded. That treats the symptom; it does not make persisted identity independent of iOS container UUIDs.

## Contract

- Persist files owned by this app under Documents/books and Documents/covers as relative paths.
- Resolve those paths at the database boundary; Book objects exposed to readers, library, import/export, and sync retain usable absolute paths.
- Recognize legacy iOS sandbox paths structurally and migrate their managed suffix, without requiring the file to exist and without matching arbitrary basenames.
- Preserve external paths, platform URIs, nullable cover records, and all reading/source metadata.
- Reuse one pure path codec for the DAO, database migration, and existing direct SQL consumers. Add no dependency or global path cache.

## Sequence

1. Add regression tests for storage representation, repeated root relocation, legacy records, direct SQL sync consumers, and external file boundaries.
2. Introduce the pure codec and apply it to book DAO reads, writes, and path lookup.
3. Migrate existing database book paths; normalize direct SQL sync reads/writes through the same codec.
4. Remove the library-specific repair pass. Keep unrelated historical file recovery behavior conservative.
5. Verify actual first shelf render, import/export/cover/sync regressions, migration idempotency, and full static analysis. Run stateful widget suites in separate processes.

## Limits

This addresses container relocation, not actual loss of image bytes. Existing null records do not retain enough identity to safely guess a custom cover. Physical iOS update testing remains separate from simulated directory relocation.

## Implemented

- `lib/services/books/book_storage_paths.dart`: pure managed-path encoding and decoding, including legacy iOS device/simulator paths.
- `lib/services/books/book_storage_codec.dart`: one asynchronous database/runtime boundary, resolving the Documents root only when needed for reads.
- `lib/services/books/book_dao.dart`: normalized insert/update/path lookup and all book read entrypoints.
- `lib/data/migration/book_storage_path_migration.dart` and `lib/services/core/database_service.dart`: transactional schema v25 data migration.
- `lib/models/book.dart`: documents runtime path semantics; generic model serialization remains platform independent.
- `lib/services/sync/{webdav_book_file_service,webdav_sync_controller,mutable_txt_sync_service,book_sync_identity}.dart` and `lib/services/books/txt_edit_reference_service.dart`: raw SQL consumers use the same path boundary and preserve sync identity.
- `lib/pages/library/library_page.dart`: removed the shelf-specific recovery pass introduced in the first fix.
- `lib/services/books/book_storage_repair_service.dart`: retains conservative historical fallback; missing covers are not erased. It is no longer the mechanism that handles sandbox upgrades.

## Verification

- Pure codec tests cover repeated root changes without any files present, legacy device/simulator paths, external paths and URIs, Unicode/nested paths, and Windows managed roots.
- DAO tests inspect raw SQLite values after every write type, exercise all retrieval APIs, preserve reading/source metadata, and verify migration idempotence.
- An isolated widget test opens an actual v24 database containing legacy iOS absolute paths, triggers v25 upgrade, and checks the first library image provider and persisted relative paths.
- Import, export, cover edit, deletion, and library regressions pass.
- 84 sync/TXT tests pass, including identical UID hashes for stored relative and runtime absolute paths, WebDAV cover storage, and TXT commit roundtrip.
- Full `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings` reports no issues; `git diff --check` passes.
- Not tested on a physical iPhone performing an app update; not published in this task.
