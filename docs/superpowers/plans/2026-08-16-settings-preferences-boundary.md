# Settings Preferences Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the complete settings page direct regression coverage and move its page-local preference serialization out of Widget state.

**Architecture:** Introduce an immutable `SettingsPagePreferences` snapshot and a `SettingsPagePreferencesStore` interface. The SharedPreferences implementation owns keys plus reader-top-bar persistence; `SettingsPage` remains responsible for transient UI state and delegates loading/saving through injected collaborators.

**Tech Stack:** Flutter, Dart, Provider, SharedPreferences, `flutter_test`.

## Global Constraints

- Preserve all existing preference keys and default values.
- Preserve immediate keep-screen-on behavior and reader-top-bar persistence.
- Do not change settings layout, labels, navigation, or visual styling.
- Do not add dependencies.
- Preserve unrelated working-tree changes.

---

### Task 1: Lock the complete page composition

**Files:**
- Create: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `SettingsPage`, `ThemeNotifier`, `AppSettingsNotifier`, `WebDavSyncController`, and `MemberAccountController`.
- Produces: A widget-level smoke test proving the complete page mounts with its required Provider graph.

- [x] **Step 1: Add a deterministic cache-manager fake**

Subclass `AppCacheManager`, override `usage`, and return zero bytes for every cache category.

- [x] **Step 2: Mount the complete settings page**

Use mocked SharedPreferences, localization delegates, and the four required ChangeNotifier providers. Assert the `SettingsPage` and account-card key are present with no framework exception.

- [x] **Step 3: Run the smoke test before persistence refactoring**

Run:

```bash
flutter test test/settings_page_test.dart
```

Expected: the page mounts and the test passes.

### Task 2: Introduce the preference snapshot and store

**Files:**
- Create: `lib/services/core/settings_page_preferences.dart`
- Create: `test/settings_page_preferences_test.dart`
- Modify: `lib/services/core/core_services.dart`

**Interfaces:**
- Produces: `SettingsPagePreferences`, `SettingsPagePreferencesStore`, and `SharedPreferencesSettingsPagePreferencesStore`.
- Consumes: SharedPreferences, `ReaderKeepScreenOnController.preferenceKey`, `ReadingResumeService.enabledPreferenceKey`, and `ReaderSystemUiController`.

- [x] **Step 1: Add load/save contract tests**

Verify every stored field, default value, reader-top-bar style, and `enableAnimations=true` migration behavior.

- [x] **Step 2: Implement the immutable preference snapshot**

Represent auto-save, interval, cover extraction, volume-key turn, auto-resume, top-bar style, fullscreen, developer flags, FPS, and keep-screen-on values.

- [x] **Step 3: Implement SharedPreferences serialization**

Keep the current keys and defaults exactly. Continue using `ReaderSystemUiController` for top-bar style.

- [x] **Step 4: Export the new boundary from core services**

Add the new module to `core_services.dart`.

### Task 3: Inject page collaborators and delegate persistence

**Files:**
- Modify: `lib/pages/settings/settings_page.dart`
- Modify: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: `SettingsPagePreferencesStore` and `ConfigurableAIService`.
- Produces: A settings page whose storage and AI-summary loading are replaceable in tests.

- [x] **Step 1: Extend `SettingsPage` constructor**

Add optional `preferencesStore` and `aiService` parameters while retaining current defaults.

- [x] **Step 2: Replace direct load serialization**

Load a `SettingsPagePreferences` snapshot and copy its values into the existing UI fields.

- [x] **Step 3: Replace direct save serialization**

Build a snapshot from current UI fields and delegate to the store. Keep `_setKeepScreenOn` as the immediate side-effect path.

- [x] **Step 4: Use fakes in the page smoke test**

Provide deterministic preference and AI collaborators so the widget test performs no secure-storage or platform-channel work.

### Task 4: Verify behavior and repository health

**Files:**
- Verify: `lib/services/core/settings_page_preferences.dart`
- Verify: `lib/pages/settings/settings_page.dart`
- Verify: `test/settings_page_preferences_test.dart`
- Verify: `test/settings_page_test.dart`

**Interfaces:**
- Consumes: The extracted persistence boundary.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run full static analysis**

Run:

```bash
dart format lib/services/core/settings_page_preferences.dart lib/pages/settings/settings_page.dart test/settings_page_preferences_test.dart test/settings_page_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run focused settings tests**

Run:

```bash
flutter test test/settings_page_preferences_test.dart test/settings_page_test.dart
```

Expected: all settings persistence and page tests pass.

- [x] **Step 3: Run the accumulated regression suite**

Run:

```bash
flutter test test/book_import_service_test.dart test/canonical_locator_test.dart test/app_theme_accent_test.dart test/widget_test.dart test/settings_page_preferences_test.dart test/settings_page_test.dart
```

Expected: all accumulated tests pass.
