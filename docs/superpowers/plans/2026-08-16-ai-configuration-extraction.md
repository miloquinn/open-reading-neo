# AI Configuration Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move AI provider/protocol configuration, URL normalization, validation, and provider settings out of the HTTP service file.

**Architecture:** Keep configuration declarations in the same Dart library through `ai_configuration.dart`. Existing consumers continue importing `ai_service.dart`; preset, settings-store, protocol-adapter, and UI code retain the same types and functions.

**Tech Stack:** Dart, Flutter test.

## Global Constraints

- Preserve all provider/protocol storage values and display names.
- Preserve URL normalization and validation error codes exactly.
- Preserve default settings and temperature rules.
- Do not alter HTTP behavior, presets, persistence keys, or public imports.
- Do not add dependencies.
- Preserve unrelated working-tree changes.

---

### Task 1: Lock configuration behavior

**Files:**
- Create: `test/ai_configuration_test.dart`

**Interfaces:**
- Consumes: Provider/protocol enums, URL normalization, validation, and `AIProviderSettings`.
- Produces: Direct configuration contract coverage.

- [x] **Step 1: Test provider and protocol storage mappings**

Assert value serialization, parsing fallbacks, and default protocol selection.

- [x] **Step 2: Test protocol-specific URL normalization**

Assert full OpenAI chat, Anthropic messages, and Gemini generation endpoints reduce to stable base URLs.

- [x] **Step 3: Test provider defaults**

Assert built-in providers receive valid preset defaults while custom remains empty and OpenAI-compatible.

- [x] **Step 4: Test normalization boundaries**

Assert whitespace trimming, protocol correction, and finite temperature clamping.

- [x] **Step 5: Test validation error codes**

Cover missing key/model, invalid URL, provider model mismatch, and protocol temperature limits.

### Task 2: Move configuration declarations

**Files:**
- Create: `lib/reader_core/ai/ai_configuration.dart`
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Produces: Existing `AIProviderType`, `AIProtocolType`, extensions, normalization, validation, and `AIProviderSettings` declarations.
- Consumes: `AIModelPresets` from the same AI library.

- [x] **Step 1: Declare the configuration part file**

Add `part 'ai_configuration.dart';` to `ai_service.dart`.

- [x] **Step 2: Move declarations mechanically**

Move the complete block from `AIProviderType` through `AIProviderSettings` without semantic edits.

- [x] **Step 3: Preserve import compatibility**

Confirm settings, stores, adapters, presets, and tests still resolve all types through `ai_service.dart`.

### Task 3: Verify extraction

**Files:**
- Verify: `lib/reader_core/ai/ai_service.dart`
- Verify: `lib/reader_core/ai/ai_configuration.dart`
- Verify: `test/ai_configuration_test.dart`

**Interfaces:**
- Consumes: Extracted configuration module.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run full static analysis**

Run:

```bash
dart format lib/reader_core/ai/ai_service.dart lib/reader_core/ai/ai_configuration.dart test/ai_configuration_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run focused AI tests**

Run:

```bash
flutter test test/ai_configuration_test.dart test/ai_model_presets_test.dart test/ai_settings_store_test.dart test/ai_protocol_adapter_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all tests pass.

- [x] **Step 3: Run the accumulated regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart test/canonical_locator_test.dart test/app_theme_accent_test.dart test/widget_test.dart test/settings_page_preferences_test.dart test/settings_page_test.dart test/ai_configuration_test.dart test/ai_model_presets_test.dart test/ai_error_translator_test.dart test/ai_protocol_adapter_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all accumulated tests pass.
