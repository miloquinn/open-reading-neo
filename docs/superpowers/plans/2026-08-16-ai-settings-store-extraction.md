# AI Settings Store Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove AI preference and API-key persistence responsibilities from `ReaderHttpAIService` while preserving its public configuration API.

**Architecture:** Add injectable `AISettingsStore` and `AISecretStore` contracts in a separate part file of the existing AI library. `ReaderHttpAIService` delegates `loadSettings` and `saveSettings`; existing consumers continue importing `ai_service.dart` and see no API break.

**Tech Stack:** Dart, Flutter Secure Storage, SharedPreferences, Dio, `flutter_test`.

## Global Constraints

- Preserve every existing AI preference key.
- Preserve legacy plaintext API-key migration and Linux/no-keyring fallback behavior.
- Preserve `ReaderHttpAIService.loadSettings` and `saveSettings` signatures.
- Do not change HTTP endpoints, payloads, headers, prompts, or response parsing.
- Do not add dependencies.
- Preserve unrelated working-tree changes.

---

## Fallback classification

- Secure-storage read/write failure falling back to SharedPreferences is a **grounded compatibility fallback** for platforms without an available keyring. It remains, with direct tests for both read and write failure paths.
- Legacy plaintext migration is a **bounded compatibility migration**. Successful secure-storage access removes the plaintext copy.
- No masking HTTP or protocol fallback is changed in this phase.

### Task 1: Lock existing AI behavior

**Files:**
- Test: `test/ai_service_models_test.dart`
- Test: `test/ai_settings_page_test.dart`
- Test: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: Existing AI configuration, protocol HTTP behavior, and UI injection.
- Produces: Baseline evidence before moving persistence.

- [x] **Step 1: Run existing AI and settings tests**

Run:

```bash
flutter test test/ai_service_models_test.dart test/ai_settings_page_test.dart test/settings_page_test.dart
```

Expected: eight tests pass.

### Task 2: Define storage contract tests

**Files:**
- Create: `test/ai_settings_store_test.dart`

**Interfaces:**
- Consumes: `AISettingsStore`, `AISecretStore`, and existing provider settings models.
- Produces: Regression coverage for secure storage, plaintext migration, normalized persistence, and compatibility fallback.

- [x] **Step 1: Test successful plaintext migration**

Load an OpenAI key stored in legacy SharedPreferences. Assert it is written to the secret store and removed from plaintext preferences.

- [x] **Step 2: Test secure value precedence**

When secure and plaintext values coexist, assert the secure value wins and the plaintext residue is removed.

- [x] **Step 3: Test secure read failure fallback**

Make the secret store throw on read and assert the legacy plaintext key remains usable.

- [x] **Step 4: Test normalized custom-provider persistence**

Save a custom Anthropic-compatible configuration and assert active provider, normalized base URL, model, temperature, protocol, and secret key are persisted.

- [x] **Step 5: Test secure write failure fallback**

Make the secret store throw on write and assert the API key is persisted in SharedPreferences.

### Task 3: Extract storage implementation

**Files:**
- Create: `lib/reader_core/ai/ai_settings_store.dart`
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Produces: `AISecretStore`, `FlutterSecureAISecretStore`, `AISettingsStore`, and `SharedPreferencesAISettingsStore`.
- Consumes: Existing `AIProviderType`, `AIProtocolType`, `AIProviderSettings`, validation, and exception types.

- [x] **Step 1: Declare the part file**

Add `part 'ai_settings_store.dart';` to `ai_service.dart` so existing import compatibility is preserved.

- [x] **Step 2: Move all persistence keys and key-selection methods**

Move provider-specific API-key, base-URL, model, temperature, active-provider, and custom-protocol keys into `SharedPreferencesAISettingsStore`.

- [x] **Step 3: Move API-key secure-storage logic**

Wrap `FlutterSecureStorage` behind `AISecretStore`, preserving successful migration and read/write failure fallback behavior.

- [x] **Step 4: Move load/save normalization and validation**

The store validates normalized settings before persistence and throws the same `AIServiceException` codes.

### Task 4: Delegate from the HTTP service

**Files:**
- Modify: `lib/reader_core/ai/ai_service.dart`
- Modify: `test/ai_service_models_test.dart`

**Interfaces:**
- Consumes: `AISettingsStore`.
- Produces: `ReaderHttpAIService({Dio? dio, AISettingsStore? settingsStore})`.

- [x] **Step 1: Inject the settings store**

Default to `SharedPreferencesAISettingsStore`; retain the existing Dio default.

- [x] **Step 2: Delegate configuration methods**

`loadSettings` and `saveSettings` call the store directly. `_resolveActiveSettings` continues using the public service method.

- [x] **Step 3: Keep protocol integration deterministic**

Update the custom Anthropic integration test to use an in-memory settings store instead of platform secure storage.

### Task 5: Verify extraction

**Files:**
- Verify: `lib/reader_core/ai/ai_service.dart`
- Verify: `lib/reader_core/ai/ai_settings_store.dart`
- Verify: `test/ai_settings_store_test.dart`
- Verify: `test/ai_service_models_test.dart`

**Interfaces:**
- Consumes: Extracted storage boundary.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run full static analysis**

Run:

```bash
dart format lib/reader_core/ai/ai_service.dart lib/reader_core/ai/ai_settings_store.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run focused AI tests**

Run:

```bash
flutter test test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart test/settings_page_test.dart
```

Expected: all tests pass.

- [x] **Step 3: Run the accumulated regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart test/canonical_locator_test.dart test/app_theme_accent_test.dart test/widget_test.dart test/settings_page_preferences_test.dart test/settings_page_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all accumulated tests pass.
