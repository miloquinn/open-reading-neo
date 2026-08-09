# Book Source Architecture Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every page/service-created book-source client graph one explicit owner and deterministic, idempotent disposal without changing protocol behavior.

**Architecture:** Keep `BookSourceClient` as the stable facade. Consumers distinguish owned dependencies created through private factories from borrowed injected dependencies. `BookSourceChangeService` resolves one client and shares that exact instance with its default shelf service.

**Tech Stack:** Flutter, Dart, Dio, flutter_test.

## Global Constraints

- Preserve existing user changes in `lib/book_sources/source_engine/source_runtime.dart` and `test/source_runtime_test.dart`.
- No new dependencies.
- Test behavior before production edits.
- Run Flutter tests sequentially because concurrent invocations race over native build artifacts.
- Do not change protocol routing, cache semantics, exception text, or reading-source behavior.

---

### Task 1: Lock service ownership behavior

**Files:**
- Create: `test/book_source_resource_ownership_test.dart`
- Modify: `lib/book_sources/services/book_source_shelf_service.dart`
- Modify: `lib/book_sources/services/book_source_change_service.dart`

**Interfaces:**
- Produces: idempotent `BookSourceShelfService.close()` and `BookSourceChangeService.close()`.
- Produces: private construction seams that distinguish internally created dependencies from injected borrowed dependencies.

- [ ] Add close-tracking client and shelf-service fakes.
- [ ] Assert injected clients are never closed by shelf service.
- [ ] Assert factory-created clients are closed exactly once.
- [ ] Cover `BookSourceChangeService` combinations: neither dependency injected, client only, shelf only, both.
- [ ] Assert default shelf service receives the exact resolved client.
- [ ] Run `flutter test test/book_source_resource_ownership_test.dart` and verify the new tests fail before implementation.
- [ ] Implement the minimal private factory/ownership state and shelf-before-client close order.
- [ ] Re-run the ownership suite and `flutter test test/book_source_change_service_test.dart`.

### Task 2: Lock page ownership behavior

**Files:**
- Modify: `lib/pages/book_sources/book_sources_page.dart`
- Modify: `lib/pages/book_sources/source_search_page.dart`
- Modify: `lib/pages/book_sources/book_source_change_page.dart`
- Modify: `lib/pages/reader/book_source/book_source_reader_page.dart`
- Modify: `lib/pages/home/home_mobile_dashboard_page.dart`
- Modify: `lib/pages/library/library_page.dart`
- Test: corresponding existing widget suites.

**Interfaces:**
- Consumes: idempotent service close methods from Task 1.
- Produces: owned dependency factories for tests and borrowed injected dependency semantics.

- [ ] Add the narrowest factory injection needed to create close-tracking dependencies that remain classified as owned.
- [ ] Add owned-versus-borrowed disposal assertions to existing widget suites.
- [ ] Add an in-flight request disposal assertion proving cancellation/settlement happens before client close.
- [ ] Run each modified widget suite and verify tests fail before implementation.
- [ ] Add ownership fields and dispose in cancellation-first, service-before-client order.
- [ ] Re-run widget suites sequentially.

### Task 3: Verify the Phase 1 boundary

**Files:**
- Modify only files listed in Tasks 1-2 and this plan if corrections are required.

**Interfaces:**
- Produces: verified Phase 1 ownership graph without protocol/runtime changes.

- [ ] Run `git diff --check`.
- [ ] Run `dart format --output=none --set-exit-if-changed` on changed Dart files.
- [ ] Run `flutter analyze`.
- [ ] Run ownership, protocol, response-cache, source-change, source-search/page, reader, shelf-service, and runtime tests sequentially.
- [ ] Compare the protected runtime diff and confirm no Phase 1 edits touched it.
- [ ] Stop and repair any behavioral change beyond ownership/disposal.

