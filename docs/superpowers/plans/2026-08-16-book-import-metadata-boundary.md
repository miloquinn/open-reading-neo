# Book-import metadata boundary cleanup plan

## Scope

- `lib/services/books/book_import_service.dart`
- New same-library metadata extraction `part` files

## Behavior lock

- `test/book_import_service_test.dart`
- `test/book_import_models_test.dart`
- `test/book_import_source_service_test.dart`
- `test/book_import_schema_migration_test.dart`

## Smells and order

1. Boundary violation: file preparation/import transaction logic and format-specific metadata parsing share one service file.
2. Cohesive extraction: move metadata dispatch and format-specific parsers into same-library extension parts.
3. Keep copy, hashing, target allocation, rollback, persistence, and import transaction flow in the main service.
4. Preserve private helpers and exact metadata/fallback semantics; do not introduce a new abstraction or dependency.

## Fallback inventory

- Filename-derived titles for missing embedded metadata are grounded compatibility fallbacks and part of the import contract.
- Basic metadata extraction for unsupported/partially parsed formats is a grounded compatibility fallback; existing import tests protect successful degradation.
- Best-effort cleanup after failed imports is a grounded rollback fail-safe; errors are secondary to the primary import failure and must not replace it.
- No fallback path will be deleted without a dedicated primary/fallback regression test.

## Verification

1. Run book-import tests before extraction.
2. Extract one format group at a time and rerun `test/book_import_service_test.dart`.
3. Run the accumulated import test set, formatting, and static analysis.
