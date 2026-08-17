# AI Model Presets Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the AI model preset catalog out of `ai_service.dart` without changing any preset identity or selection behavior.

**Architecture:** Keep the preset classes in the same Dart library through a dedicated part file. Existing callers continue importing `ai_service.dart`; the service file no longer carries the large static vendor/model catalog.

**Tech Stack:** Dart, Flutter test.

## Global Constraints

- Preserve every preset ID, label, vendor, provider, URL, model, and temperature.
- Preserve default-provider selection, matching, and provider filtering.
- Do not change public imports or add dependencies.
- Preserve unrelated working-tree changes.

---

### Task 1: Lock preset catalog behavior

**Files:**
- Create: `test/ai_model_presets_test.dart`

**Interfaces:**
- Consumes: `AIModelPreset`, `AIModelPresets`, and `AIProviderSettings`.
- Produces: Catalog integrity and selection regression coverage.

- [x] **Step 1: Test unique preset IDs**

Assert every preset ID is non-empty and unique.

- [x] **Step 2: Test provider defaults**

Assert every provider resolves to a preset for that provider and produces valid settings.

- [x] **Step 3: Test provider filtering**

Assert filtered lists are non-empty and contain only the requested provider.

- [x] **Step 4: Test normalized preset matching**

Assert settings created from each preset match the same preset after URL/model normalization.

### Task 2: Move the preset catalog

**Files:**
- Create: `lib/reader_core/ai/ai_model_presets.dart`
- Modify: `lib/reader_core/ai/ai_service.dart`

**Interfaces:**
- Produces: Existing `AIModelPreset` and `AIModelPresets` declarations from a part file.
- Consumes: Existing provider and settings types in the AI library.

- [x] **Step 1: Declare the part file**

Add `part 'ai_model_presets.dart';` to `ai_service.dart`.

- [x] **Step 2: Move declarations mechanically**

Move the complete block from `class AIModelPreset` through `AIModelPresets.byProvider` without content changes.

- [x] **Step 3: Preserve external import compatibility**

Confirm settings pages and tests still see both types through `ai_service.dart`.

### Task 3: Verify extraction

**Files:**
- Verify: `lib/reader_core/ai/ai_service.dart`
- Verify: `lib/reader_core/ai/ai_model_presets.dart`
- Verify: `test/ai_model_presets_test.dart`

**Interfaces:**
- Consumes: Extracted preset catalog.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run full static analysis**

Run:

```bash
dart format lib/reader_core/ai/ai_service.dart lib/reader_core/ai/ai_model_presets.dart test/ai_model_presets_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run focused AI tests**

Run:

```bash
flutter test test/ai_model_presets_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all tests pass.

- [x] **Step 3: Run the accumulated regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart test/canonical_locator_test.dart test/app_theme_accent_test.dart test/widget_test.dart test/settings_page_preferences_test.dart test/settings_page_test.dart test/ai_model_presets_test.dart test/ai_error_translator_test.dart test/ai_protocol_adapter_test.dart test/ai_settings_store_test.dart test/ai_service_models_test.dart test/ai_settings_page_test.dart
```

Expected: all accumulated tests pass.
