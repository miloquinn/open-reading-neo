# Unified reading cache implementation

## Scope and collaboration

Work in the isolated `codex/unified-reading-cache` worktree. The baseline commit snapshots concurrent work. Transfer only changes after that baseline, checking each hunk against the live checkout. No new dependencies. Do not reformat or revert unrelated files.

## Accepted behavior and cleanup plan

1. Preserve memory -> persistent cache -> loader behavior, current reader navigation, source authentication isolation, and saved/downloaded book files.
2. Cover cache deletion, delayed-write races, quotas, corrupted/expired entries, content revisions and pagination round trips with focused regression tests before replacing their paths.
3. Reuse the current chapter/image caches and pagination codec. Add one bounded disk-budget primitive shared by online and local derived caches, including grouping for multi-file book caches. Remove superseded pruning code after coverage exists.
4. Generalize persisted pagination identities for local and online content. Keep compact boundaries and content/layout revisions; migrate reconstructable cache data safely without touching books. Reuse online pagination after reopen.
5. Complete cache statistics/deletion for database pagination, native memory and online image pages. Explicit clearing must invalidate in-flight writes and active cache holders; OS memory pressure must remain non-destructive.
6. Reuse already fetched online chapters for downloads under existing freshness/authentication rules. Retain visible-first prefetch behavior; avoid introducing a competing scheduler.
7. Apply byte limits and expiry cleanup at owned cache boundaries. Never evict imported books or saved downloads. Protect active local parser resources so disk eviction cannot break an open reader.
8. Remove obsolete alternate code only when replaced and tested. Retain legacy-directory cleanup for upgrades, corrupt-cache recomputation, and network stale-cache fallback: these are grounded compatibility/fail-safe behavior, not dead code.

## Verification

Run isolated relevant Flutter test files (cache manager, chapter cache, response cache, images, pagination DAO/codec, local parser and online reader integration). Run formatting, scoped/full Dart analysis, and diff whitespace checks. Distinguish inherited failures from this change with baseline reproduction. Recheck and apply the task-only patch to the shared checkout, preserving concurrent edits, then verify the integrated result.

## Ownership

- Cache storage lane: shared disk budget, online chapter/image cache limits, download cache reuse, own regression tests.
- Pagination lane: generalized DAO/schema and native/online pagination integration, own regression tests.
- Leader: cache management, local cache resource lifecycle/budgets, integration and verification.

## Implementation outcome

- Shared disk-budget helper and grouped native resource ownership are integrated; obsolete TXT count-only pruning and duplicate source image size/expiry implementations are removed.
- Local/online pagination share one bounded DAO and codec, with compatible v22 migration and clear/content revision guards.
- Cache management includes image-page disk data and SQLite boundaries; native resource reclamation waits for active readers and I/O, and scans do not block initial content loading.
- Download cache reuse keeps existing authentication/source-variable revisions and fresh-only download semantics.
- Native widget tests now drain asynchronous work and use owned temporary roots. All assertions remain enabled.
- Baseline backup: `codex/reading-cache-before-unification` (`22e782a`). Transfer only the post-baseline task diff; do not merge the snapshot wholesale into main.
- Validation includes cache/storage/DAO/codec tests and local/online reader regressions, including real SQLite close/reopen. After transferring the task-only patch, cache management, pagination DAO, and online persistence suites all passed again in the shared checkout. Final shared-checkout Flutter analysis reports no issues. An inherited unused-import warning seen in the isolated snapshot was resolved independently in the shared checkout; this task did not edit that file. No physical-device performance benchmark has been run.
- Integration transferred 37 task files after verifying no overlapping edits. The shared checkout index was unchanged; the implementation remains available on `codex/unified-reading-cache`.
