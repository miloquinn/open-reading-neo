# Canonical Locator Contract Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock the reader locator JSON and normalization contract before any structural refactor of `canonical_locator.dart`.

**Architecture:** Treat the five locator value types and `LocatorCodec` as one persisted protocol boundary. Add direct unit tests for normalization, URI construction/parsing, complete JSON round-trips, unknown enum fallbacks, derived reader selections, and malformed serialized input without changing production behavior.

**Tech Stack:** Dart, Flutter, `flutter_test`, JSON serialization.

## Global Constraints

- Do not modify `lib/core/reader/canonical_locator.dart` during this phase.
- Preserve compatibility with locator JSON already stored in the database and preferences.
- Do not add dependencies.
- Keep tests deterministic and independent of platform channels, filesystems, and databases.
- Preserve unrelated working-tree changes.

---

### Task 1: Establish the existing test baseline

**Files:**
- Test: `test/canonical_locator_test.dart`

**Interfaces:**
- Consumes: Existing `RenderedLocator.fromJson` and JSON round-trip behavior.
- Produces: Baseline evidence before expanding the contract suite.

- [x] **Step 1: Run the existing focused tests**

Run:

```bash
flutter test test/canonical_locator_test.dart
```

Expected: two existing tests pass.

### Task 2: Lock primitive and canonical locator behavior

**Files:**
- Modify: `test/canonical_locator_test.dart`

**Interfaces:**
- Consumes: `TextAnchor`, `CanonicalLocator`, and their `LocatorCodec` methods.
- Produces: Regression coverage for normalization, clamping, URI parsing, and complete JSON persistence.

- [x] **Step 1: Test `TextAnchor.create` normalization and non-negative offsets**

Create an anchor with repeated spaces, CRLF input, and negative offsets. Assert normalized text and offsets clamped to zero.

- [x] **Step 2: Test `TextAnchor` codec round-trip**

Encode and decode an anchor containing every optional field, then compare value equality.

- [x] **Step 3: Test `CanonicalLocator.fromComponents` URI semantics**

Use a chapter ID and excerpt containing URL-sensitive characters. Assert `chapterIdFromHref`, `offsetFromHref`, and `excerptFromHref` recover the source values.

- [x] **Step 4: Test canonical normalization and codec round-trip**

Assert progression is clamped to `0.0...1.0`, unknown formats decode as `BookFormat.unknown`, and every persisted optional field survives a codec round-trip.

### Task 3: Lock rendered, annotation, and selection contracts

**Files:**
- Modify: `test/canonical_locator_test.dart`

**Interfaces:**
- Consumes: `RenderedLocator`, `AnnotationAnchor`, `ReaderSelection`, and their codec methods.
- Produces: Regression coverage for layout-dependent positions, annotation persistence, and selection derivation.

- [x] **Step 1: Test complete rendered-locator normalization and round-trip**

Assert progression clamps, positions remain one-based, surrounding text normalizes, and optional rendering fields persist.

- [x] **Step 2: Test annotation-anchor round-trip and unknown enum fallbacks**

Round-trip a complete annotation. Separately decode unknown kind and resolution values and assert highlight/unresolved fallbacks.

- [x] **Step 3: Test selection derivation from canonical and rendered locators**

Assert canonical anchor values take precedence while rendered values supply renderer identity and serialized rendered location.

- [x] **Step 4: Test complete reader-selection codec round-trip**

Encode and decode every optional field and compare value equality.

### Task 4: Lock malformed-input behavior and verify

**Files:**
- Modify: `test/canonical_locator_test.dart`

**Interfaces:**
- Consumes: All `LocatorCodec.decode*` methods.
- Produces: Explicit safe failure behavior for empty, malformed, and non-object JSON.

- [x] **Step 1: Test malformed codec inputs**

For every decoder, assert empty strings, malformed JSON, and JSON arrays return `null` rather than throwing.

- [x] **Step 2: Format and run static analysis**

Run:

```bash
dart format test/canonical_locator_test.dart
flutter analyze lib/core/reader/canonical_locator.dart test/canonical_locator_test.dart
```

Expected: no issues found.

- [x] **Step 3: Run focused tests**

Run:

```bash
flutter test test/canonical_locator_test.dart
```

Expected: all locator contract tests pass.
