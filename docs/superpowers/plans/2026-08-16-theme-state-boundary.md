# Theme State Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the settings feature's dependency on the application entrypoint by moving `ThemeNotifier` into the core services boundary without changing behavior.

**Architecture:** `main.dart` remains the composition root and consumes theme state through `services/core/core_services.dart`. `SettingsPage` consumes both `ThemeNotifier` and `AppSettingsNotifier` from the same core-services boundary, while the notifier's persistence keys, migration behavior, and glass-effect synchronization remain unchanged.

**Tech Stack:** Flutter, Dart, Provider, SharedPreferences, `flutter_test`.

## Global Constraints

- Preserve the public `ThemeNotifier` API and all preference keys exactly.
- Preserve theme migration and glass-effect synchronization behavior.
- Do not change visual design or settings interactions.
- Do not add dependencies.
- Preserve unrelated working-tree changes.

---

### Task 1: Lock existing theme behavior

**Files:**
- Test: `test/app_theme_accent_test.dart`
- Test: `test/widget_test.dart`

**Interfaces:**
- Consumes: Existing `ThemeNotifier` and `XxReadApp` composition.
- Produces: Regression evidence for theme initialization, migration, persistence, and application mounting.

- [x] **Step 1: Run theme and smoke tests before moving code**

Run:

```bash
flutter test test/app_theme_accent_test.dart test/widget_test.dart
```

Expected: five tests pass.

### Task 2: Move theme state to the core services boundary

**Files:**
- Create: `lib/services/core/theme_notifier.dart`
- Create: `lib/widgets/restartable_app.dart`
- Modify: `lib/services/core/core_services.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `AppThemes`, `GlassEffectConfig`, `AppUiStyle`, and SharedPreferences.
- Produces: `ThemeNotifier` from `package:xxread/services/core/theme_notifier.dart`, re-exported by `core_services.dart`.

- [x] **Step 1: Create the focused theme-state file**

Move the existing `ThemeNotifier` class unchanged into `theme_notifier.dart` with direct imports for Flutter material types, SharedPreferences, theme utilities, glass configuration, and UI style.

- [x] **Step 2: Export `ThemeNotifier` from core services**

Add:

```dart
export 'package:xxread/services/core/theme_notifier.dart';
```

- [x] **Step 3: Remove the class definition from `main.dart`**

Keep `main.dart` as the Provider composition root. It obtains `ThemeNotifier` through the existing `core_services.dart` import.

- [x] **Step 4: Move the shared restart boundary out of `main.dart`**

Move `RestartableApp` unchanged into `lib/widgets/restartable_app.dart`. Import it directly from both `main.dart` and `settings_page.dart` so the settings feature does not regain an entrypoint dependency through its part files.

### Task 3: Remove feature-to-entrypoint coupling

**Files:**
- Modify: `lib/pages/settings/settings_page.dart`
- Modify: `test/app_theme_accent_test.dart`

**Interfaces:**
- Consumes: `ThemeNotifier` and `AppSettingsNotifier` from core services.
- Produces: Settings and theme tests that no longer import `main.dart` for state types.

- [x] **Step 1: Remove the `main.dart` import from settings**

`settings_page.dart` already imports `core_services.dart`; use that boundary for both notifier types.

- [x] **Step 2: Point the focused theme test at the new module**

Replace the `main.dart` import with:

```dart
import 'package:xxread/services/core/theme_notifier.dart';
```

### Task 4: Verify the boundary move

**Files:**
- Verify: `lib/services/core/theme_notifier.dart`
- Verify: `lib/main.dart`
- Verify: `lib/pages/settings/settings_page.dart`
- Verify: `test/app_theme_accent_test.dart`
- Verify: `test/widget_test.dart`

**Interfaces:**
- Consumes: Refactored module boundary.
- Produces: Static and behavioral completion evidence.

- [x] **Step 1: Format and run static analysis**

Run:

```bash
dart format lib/services/core/theme_notifier.dart lib/services/core/core_services.dart lib/main.dart lib/pages/settings/settings_page.dart test/app_theme_accent_test.dart
flutter analyze
```

Expected: no issues found.

- [x] **Step 2: Run theme and application smoke tests**

Run:

```bash
flutter test test/app_theme_accent_test.dart test/widget_test.dart
```

Expected: five tests pass.

- [x] **Step 3: Confirm settings no longer imports the entrypoint**

Run:

```bash
rg -n "package:xxread/main.dart" lib/pages/settings test/app_theme_accent_test.dart
```

Expected: no matches.
