# Reading cache

Local and online readers share bounded cache storage policies and the same SQLite pagination boundary store. File decoding and network fetching keep their existing adapters; source responses, parsed content, layout boundaries, and image bytes remain separate cache types.

## Read path

- Local TXT: reopen memory when appropriate → parsed JSON or streaming index/data → source file.
- Local EPUB: active chapter window → per-book chapter/resource files → source archive. Closing a reader releases its resource lease; reopen uses the disk index and saved pagination.
- Online text: reader chapter window → shared chapter/catalog memory → disk → source backend. Concurrent equivalent loads share work. Fresh downloaded content uses this same cache with background refresh disabled.
- Text pagination: memory → compact SQLite boundaries → line measurement. Online storage contains offsets only, never a second copy of chapter text.
- Images: decoded/image-byte memory → owned disk files → local extraction or network. Existing visible-first network scheduling stays in use.

## Identity and invalidation

Local identities combine the book identity, actual file modification time and size, encoding, and edit revision. Online content retains existing source configuration, variables, and authentication revision isolation. Online pagination additionally hashes source/book/chapter identity and the resulting readable text. Layout fingerprints include engine version, font profile, viewport, spacing, direction, and replacement rules.

Changing text invalidates its derived pagination. Changing layout preserves parsed content. The DAO uses global clear epochs and per-identity revision tokens so delayed writes cannot revive cleared entries or supersede a newer revision. Compatible v22 local pagination rows migrate into the local namespace; incompatible derived cache formats are rebuilt.

## Default budgets

Budgets are ceilings, not reserved allocations. Constructors permit smaller limits in tests or future configuration.

| Cache | Memory | Persistent data |
| --- | --- | --- |
| Online chapters and catalogs | Shared 24 MiB serialized-size budget; also 24 chapters / 12 catalogs | 256 MiB; 30-day expiry |
| Source covers | 24 MiB | 96 MiB; 7-day expiry |
| Source image pages | 64 MiB | 512 MiB; 30-day expiry |
| Local parsed resources | Existing chapter/window limits | 512 MiB per native resource root |
| Shared pagination | Existing reader windows; at most 128 stored payloads per identity | 32 MiB / 4096 entries globally; 128 per identity |
| Public source responses | Existing 4 MiB / 48 entries | Existing 16 MiB / 160 entries |

The shared disk budget groups streaming TXT index/data siblings and all files in one EPUB book directory. It evicts cold groups together, skips active resources, throttles directory scans, and checks cumulative online write growth against the byte budget. Native directory maintenance runs outside the critical opening path. Protected active books can temporarily exceed their quota; closing readers and completing their pending I/O triggers another maintenance pass.

## Clearing and ownership

`AppCacheManager` includes source image-page files, chapter/catalog memory estimates, native derived directories, and SQLite pagination payloads. Reading-cache clearing invalidates live pagination holders and releases native reopen memory. Active lazy resources are retained until the final reader or I/O operation releases them, including output files that did not exist when clearing began.

Imported books, saved downloads, saved covers, progress, annotations, credentials, and source configuration are not cache eviction candidates. Legacy directory cleanup remains for upgrades. Corrupt-cache recomputation and stale content during network failure remain intentional recovery paths.

Usage combines owned file bytes and available serialized/memory byte counters, not a precise Dart heap measurement. SQLite payload bytes become reusable database space after clearing; the shared application database file need not shrink immediately.

## Regression coverage

Tests cover byte limits, grouped eviction, protected/late-created resources, hot-read scan throttling, rapid write growth, clear/write races, version races, migration, corrupt payloads, local and online reopen hits, layout/content/source separation, external TXT edits with unchanged database metadata, and download reuse. Stateful reader tests use isolated filesystem roots and drain asynchronous cache work before the next case; they retain all rendering and navigation assertions.
