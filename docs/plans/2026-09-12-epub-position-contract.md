# EPUB position persistence and restoration

## Scope and evidence

Limit work to the native text reader's position selection, restoration, and persistence paths and their regression tests. Preserve unrelated concurrent edits, database schema, existing locators, and horizontal gesture semantics. No new dependencies.

The first regression reproduces offset 436 being overwritten with 0 on backgrounding. Reusing the bookmark anchor fixes that write, but a stronger repeated-open regression still fails: chapter-scoped scrolling changes 436 to 288 while reopening without reading. Therefore a single exit-site change is insufficient for the full position contract.

## Cleanup plan before implementation

1. Protect both continuous modes with exact database/session anchor assertions, repeated reopen/close cycles, and restoration-in-progress lifecycle coverage. Keep horizontal restore and pending-swipe exit tests.
2. Move position selection out of bookmark navigation into the reader session responsibility. Use one named current-position selector for bookmarks and lifecycle/exit saves; remove the bookmark-specific coupling introduced by the first fix.
3. Treat restoration as positioning, not reading: freeze its target across asynchronous frames and prevent provisional scroll callbacks from overwriting it. Restore to the same viewport reference used when capturing the anchor.
4. Inspect mode/chapter transitions for stale anchors and apply the same restoration rule where required by a failing regression. Preserve text-offset locators and the serialized database queue.
5. Run each stateful regression in a separate Flutter process, then Flutter analyze and formatting/diff checks. Review the bounded diff before integrating it into the shared checkout.

## Fallback inventory

- Page/part-start fallback when no precise anchor is available: grounded initial-position behavior. Retain for genuinely new/unpositioned books, never let it overwrite a known restore target.
- Saved chapter-index fallback when old locators have no chapter id: legacy compatibility; preserve.
- Queue error callback: reports write errors rather than throwing from detached UI work; not the reproduced cause. Do not hide failures or add retries to mask the position bug.
- Multiple temporary positions during layout: responsibility violation; fix capture/restoration boundaries instead of adding version-specific EPUB exceptions.

## Acceptance

A stored chapter/text anchor survives background, exit, and repeated reopening without reading. The saved text is visible after restoration in both scroll modes. A user scroll may move progress backward or forward. Horizontal pages and pending-swipe exit retain existing semantics. Previously saved locators remain readable.

## Review-driven refinement

The first arbitrary-offset regression also reproduces 2400 -> 2395 on passive recapture after restoration. Restrict viewport capture to actual scroll lifetimes, including programmatic keyboard/automatic scrolling; use a revision to prevent a delayed end callback from closing a newer gesture. Require a successful rendered-anchor placement before marking restoration complete.

Consolidate startup, mode/layout changes, and bookmark navigation behind the same continuous-position request boundary. Remove the duplicate manual-bookmark placement sequence and the estimated preceding-height pass: positioned-list jump selects the chapter/part, then the rendered paragraph places the source anchor. Use a completion future for navigation callers and a revision to discard obsolete scheduled placement. Preserve image-only/empty parts as successful coarse placements, not infinite retries.

## Final implementation scope

- `lib/pages/reader/native/native_reader_session.dart`: shared current-position selector and restoration request boundary; lifecycle/exit capture the final active scroll position.
- `lib/pages/reader/native/native_reader_page.dart`: restore completion lifecycle, mode/scope transition capture, centralized valid canonical offsets, and write suppression while positioning.
- `lib/pages/reader/native/native_reader_continuous_layout.dart`: one rendered positioning sequence with frozen chapter/part/offset, revision checks, success-only readiness, and exact-target persistence.
- `lib/pages/reader/native/native_reader_vertical_paging.dart`: actual-scroll capture boundaries and final-frame sampling; explicit text/coarse positioning result.
- `lib/pages/reader/native/native_reader_navigation.dart`: bookmarks use the shared restoration completion instead of duplicating the placement algorithm.
- `lib/pages/reader/native/native_reader_interaction.dart`: direct chapter changes establish a new chapter/offset target; remove the competing chapter scroll animation.
- `lib/pages/reader/native/native_reader_scaffold.dart`: share position selection and page-offset lookup; bound legacy offsets against loaded content.
- `lib/pages/reader/native/native_reader_configuration.dart`: layout changes request restoration through the same boundary.
- `lib/pages/reader/native/native_reader_auto_page_turn.dart`: automatic-scroll surface changes use the same boundary.
- `test/native_reader_initial_progress_test.dart`: both scroll scopes; chapter start/deep/oversized locators; arbitrary-offset preservation; active-session snapshots; background during restore; repeated reopening with rendered caret assertions; backward scrolling; mode changes; bookmark and chapter navigation.

## Compatibility and limits

Existing locator JSON and database schema remain unchanged. For a saved offset beyond the end of an updated/shortened chapter, the only representable location is bounded to the chapter end; this is validated before rendering and before saving, avoiding RangeError. Image/empty parts retain their coarse anchor when no text caret exists. No new dependencies or version-specific EPUB bypasses were added.

The reported bug is reproduced with a synthetic EPUB. Physical devices, abrupt OS process termination, and the reporter's original EPUB have not been exercised; successful persistence cannot reconstruct a location that an older build already overwrote. The change fixes the identified overwrite/restore-drift class without claiming that every unrelated reader feature or file format has been exhaustively tested.

## Verification completed

26 tests passed in isolated Flutter processes: six comprehensive scroll scenarios (both scopes x new/deep/oversized locators), five initial/horizontal/search regressions, two automatic-scroll regressions, two save-queue tests, seven resume-service tests, and four horizontal page-tracker tests. The comprehensive scenarios validate initial arbitrary-offset preservation, interruption during restore, session and database writes, three reopen/close cycles with actual rendered-caret checks, backward scrolling, mode changes, cold bookmark navigation, and chapter changes as applicable.

Full `flutter analyze --no-pub`: no issues. Dart formatting and `git diff --check`: passed. Independent reviewer reran both oversized-offset cases and approved the final changes with no remaining findings. Validation ran on an isolated checkout to preserve concurrent unrelated work.
