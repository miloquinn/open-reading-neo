# AI Error Translator Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Dio and provider-specific error interpretation out of `ReaderHttpAIService` without changing user-facing error codes.

**Architecture:** Add an injectable `AIErrorTranslator` in a separate part file of the AI library. It converts Dio failures into `AIServiceException` and owns compact response snippets; the HTTP service retains only the catch boundaries and request flow.

**Tech Stack:** Dart, Dio, JSON decoding, `flutter_test`.

## Global Constraints

- Preserve every existing `AIServiceException.code` mapping.
- Preserve endpoint, status, text, error, and snippet metadata.
- Do not change request/response protocol behavior, settings persistence, or prompts.
- Do not add dependencies.
- Preserve unrelated working-tree changes.

---

### Task 1: Lock direct error mappings

**Files:**
- Create: `test/ai_error_translator_test.dart`

**Interfaces:**
- Consumes: `AIErrorTranslator.translate(DioException)`.
- Produces: Regression coverage for provider hints and generic network failures.

- [x] **Step 1: Test MiniMax hint mapping**

Map an error response containing `invalid chat setting` to `request_failed_minimax_hint` with status and endpoint.

- [x] **Step 2: Test Claude header hint mapping**

Map an `anthropic-version` error to `request_failed_claude_hint`.

- [x] **Step 3: Test API-key mismatch mapping**

Map invalid API-key text to `request_failed_provider_mismatch_hint`.

- [x] **Step 4: Test missing-response mapping**

Map Dio/native missing-body wording to `failed_read_body`.

- [x] **Step 5: Test generic structured and transport failures**

Map ordinary provider messages to `request_failed_generic` and transport failures to `network_request_failed`.

- [x] **Step 6: Test response snippet compaction**

Assert whitespace is compacted and long response text is truncated to the configured limit.

### Task 2: Extract the translator

**Files:**
- Create: `lib/reader_core/ai/ai_http_error_translator.dart`
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Produces: `AIErrorTranslator.translate` and `truncateForError`.
- Consumes: Dio exceptions, JSON, and `AIServiceException`.

- [x] **Step 1: Declare the translator part file**

Add `part 'ai_http_error_translator.dart';` to the AI library. Keep it distinct from the existing UI-localization `ai_error_translator.dart` library.

- [x] **Step 2: Move structured error-message extraction**

Preserve nested `error.message`, top-level `message`, and `detail` precedence.

- [x] **Step 3: Move provider-hint classification**

Preserve MiniMax, Claude, API-key mismatch, missing-body, and generic mappings.

- [x] **Step 4: Move response-snippet compaction**

Preserve the 220-character default and whitespace normalization.

### Task 3: Delegate from the HTTP service

**Files:**
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Consumes: `AIErrorTranslator`.
- Produces: Constructor injection plus thin catch-boundary delegation.

- [x] **Step 1: Inject the translator**

Add optional `errorTranslator` while retaining all existing constructor calls.

- [x] **Step 2: Delegate Dio exception conversion**

Use the translator in model-list and chat request catch blocks.

- [x] **Step 3: Delegate invalid-JSON snippet generation**

Use `truncateForError` when creating `invalid_json_error`.

### Task 4: Verify extraction

**Files:**
- Verify: `lib/reader_core/ai/ai_service.dart`
- Verify: `lib/reader_core/ai/ai_http_error_translator.dart`
- Verify: `test/ai_error_translator_test.dart`

**Interfaces:**
- Consumes: Extracted error boundary.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run full static analysis**

Run:

```bash
dart format lib/reader_core/ai/ai_service.dart lib/reader_core/ai/ai_http_error_translator.dart test/ai_error_translator_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run focused AI tests**

Run:

```bash
flutter test test/ai_error_translator_test.dart test/ai_protocol_adapter_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart
```

Expected: all tests pass.

- [x] **Step 3: Run the accumulated regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart test/canonical_locator_test.dart test/app_theme_accent_test.dart test/widget_test.dart test/settings_page_preferences_test.dart test/settings_page_test.dart test/ai_error_translator_test.dart test/ai_protocol_adapter_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all accumulated tests pass.
