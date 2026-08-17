# Book-source page boundary cleanup plan

## Scope

- `lib/pages/book_sources/source_search_page.dart`
- `lib/pages/book_sources/book_sources_page.dart`
- `lib/pages/book_sources/book_source_management_page.dart`
- New focused `part` files beside those pages

## Behavior lock

- `test/book_source_architecture_test.dart`
- `test/book_source_search_page_test.dart`
- `test/book_source_management_page_test.dart`
- `test/book_source_page_modes_test.dart`
- Existing discovery and reader integration tests remain unchanged.

## Smells and order

1. Boundary violation: page state classes mix lifecycle/orchestration with large UI builders and modal workflows.
2. File-size regression: all three files exceed the repository's 800-line responsibility budget.
3. Mechanical extraction first: move cohesive private methods into same-library extension `part` files.
4. Do not change controller contracts, widget constructors, state fields, copy, layout, or async behavior.

## Planned boundaries

- Search page: keep search orchestration/lifecycle in the main file; move result/query UI builders to a UI part.
- Discovery page: keep ownership/lifecycle/navigation in the main file; move discovery/list sliver builders to a content part.
- Management page: keep ownership/list orchestration in the main file; move maintenance dialogs and add/information workflows to focused action parts.

## Fallback inventory

- `source_search_page.dart` catches an individual source search failure and converts it into a failed batch. Classification: grounded fail-safe boundary; multi-source search must preserve successful results when one remote source fails, and existing tests cover partial failures.
- Management provider lookup falls back to an owned coordinator only when no provider is registered. Classification: grounded dependency fallback used by standalone routes/tests; preserve.
- No masking fallback will be added or removed in this mechanical pass.

## Verification

1. Run the four targeted tests above after each page extraction.
2. Run `dart format` on touched Dart files.
3. Confirm every production book-source Dart file is below 800 lines through the architecture test.
