# Canonical Locator boundary decision plan

## Scope

- `lib/core/reader/canonical_locator.dart`
- `test/canonical_locator_test.dart`

## Behavior lock

- The expanded canonical-locator suite covers value types, JSON round trips, malformed inputs, URI parsing, normalization, and fallbacks.

## Decision criteria

1. Split only if the file combines independently changing responsibilities with a clear dependency direction.
2. Do not split merely to reduce line count when the value objects and codec form one contract surface.
3. Prefer leaving a cohesive contract module intact over creating barrels or cross-file private coupling.

## Fallback inventory

- Invalid or absent persisted locator data normalizes to documented safe values. Classification: grounded compatibility fallback for historical data; directly covered by tests.
- Malformed payload decoding returns the established nullable/failure result rather than inventing an alternate locator. Preserve.

## Verification and outcome

1. Review type groupings, imports, and call sites against the decision criteria.
2. If no independent boundary is demonstrated, document a deliberate no-change decision and keep the production file cohesive.
3. Rerun `test/canonical_locator_test.dart` regardless of outcome.

## Final decision

- Keep `canonical_locator.dart` as one public contract module.
- The file is large (1,380 lines), but its enums, persisted value objects, normalization helpers, and codec form one serialization contract. All nine current consumers import that contract as a unit.
- A `part`-only split would reduce per-file line counts without reducing coupling or creating an independently testable/service-owned boundary. It would therefore be cosmetic indirection rather than responsibility repair.
- The 13 direct contract tests pass, including malformed historical payloads and every persisted value type. Revisit only if a type group gains a separate dependency direction or release cadence.
