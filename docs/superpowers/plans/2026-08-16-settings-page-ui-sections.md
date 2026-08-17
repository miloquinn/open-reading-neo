# Settings page UI-section cleanup plan

## Scope

- `lib/pages/settings/settings_page.dart`
- New same-library settings UI `part` files

## Behavior lock

- `test/settings_page_test.dart`
- `test/settings_page_preferences_test.dart`
- `test/settings_navigation_and_layout_pages_test.dart`
- `test/app_theme_accent_test.dart`
- Existing settings and font tests remain unchanged.

## Smells and order

1. Boundary violation: the state object owns lifecycle/persistence/navigation and also renders every settings section and modal.
2. Duplication risk: common setting-row helpers are buried among feature-specific builders.
3. Extract cohesive private UI methods into same-library extensions without changing widget keys, labels, callbacks, or state ownership.
4. Keep lifecycle, preference coordination, navigation, and controller wiring in the main file.

## Planned boundaries

- Appearance section: theme, UI style, accent color, fonts, language, and their modals.
- About/support section: about card, community links, update actions, donation and external-link actions.
- Shared settings widgets may remain in the main file unless moving them materially clarifies ownership.

## Fallback inventory

- Package-version loading retains the visible default version if platform metadata is unavailable. Classification: grounded UI fail-safe; the page remains usable and does not hide a user action failure.
- Cache usage refresh retains the existing displayed value when filesystem measurement fails. Classification: grounded non-critical telemetry fail-safe; preserve in this extraction.
- External URL failures already surface user feedback and are not silent defaults.

## Verification

1. Run targeted settings tests before and after extraction.
2. Run `dart format` and `flutter analyze` on the touched boundary.
3. Confirm no user-visible text, keys, navigation, or preference writes change.
