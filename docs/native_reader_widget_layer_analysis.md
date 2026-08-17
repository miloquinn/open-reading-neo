# Native Flutter Reader Widget-Layer Analysis

**Repo:** `/Users/xiaoyuan/code/open-reading` **Package:** `xxread`

This is a “native” (local-file / local-book) reader built in pure Flutter (no webview). The state, paging, caching, parsing and controls all live in one library split into Dart **part files** of `lib/pages/reader/native/native_reader_page.dart` (the `part ...` declarations are at lines 92-110 of that file).

## 1. Overall widget hierarchy

Single entry widget `NativeReaderPage` (`native_reader_page.dart:191`) -> one private `State` `_NativeReaderPageState` (`:213`, mixes in `WidgetsBindingObserver`). All other files are `extension ... on _NativeReaderPageState` split across `native_reader_scaffold.dart`, `native_reader_shell.dart`, `native_reader_rendering.dart`, `native_reader_page_cache.dart`, `native_reader_controls.dart`, `native_reader_session.dart` plus hidden siblings (`_chapter`, `_pagination`, `_parsers`, `_document_parsers`, `_horizontal_paging`, `_vertical_paging`, `_horizontal_window`, `_continuous_layout`, `_loading`, `_configuration`, `_interaction`, `_navigation`).

`build(...)` at `native_reader_page.dart:723` delegates to `_buildReaderPage(context)` (`native_reader_scaffold.dart:4`).

The tree (top to bottom):

- `AnnotatedRegion<SystemUiOverlayStyle>` (scaffold:7,19)
- `PopScope` (canPop: `_exitPositionCommitted`) (scaffold:22)
- `Theme(data: _readerThemeData)` (scaffold:36)
- `FutureBuilder<List<_NativeChapter>>` (scaffold:38, future: `_chaptersFuture`) | loading/error/not-ready stages -> opening or message Scaffold
- `Scaffold(key: native-reader-content, resizeToAvoidBottomInset:false)` (scaffold:91)
  - `ReaderThemeBackground(palette: _readerTheme)` (scaffold:101)
    - `LayoutBuilder` -> size/viewport constraints (scaffold:103)
      - `ReaderPullBookmark(enabled: _pullBookmarkEnabled)` (scaffold:319)
        - `Stack`:
          - `Positioned.fill` -> `BookOpenTransition.buildReaderContentReveal` (scaffold:333)
            - `ReaderTapObserver(onTap: _handleReaderTap)` (scaffold:335)
              - `GestureDetector` (horizontal-swipe hook) (scaffold:341)
                - `_buildReaderContent(...)` (scaffold:359)
          - `Positioned.fill` -> `ColoredBox` positioning-placeholder (scaffold:377)
          - `ReaderFloatingStatusOverlay` (vertical only) (scaffold:389)
          - `ReaderChromeOverlay` (view controls) (scaffold:396)
- optional `ReaderTapZoneEditorOverlay` (scaffold:475)

`_buildReaderContent` (the **paging-surface dispatcher**, `native_reader_shell.dart:62`) selects the active paging surface:

- `verticalScroll`: (scrollByChapter==false) `_buildVerticalReadingWindow(_buildVerticalBook(chapters, viewport))` (shell:71-80) | (true) `_buildVerticalReadingWindow(_buildVerticalPageList(chapter, pages, viewport))` (shell:81-83)
- `instantPage`: falls through to `_buildPageLeaf(...)` single leaf (shell:85-97,267-274)
- `horizontalSlide`: `_buildHorizontalSlideSurface(...)` = `PageView.builder` (shell:98-105; horizontal:332-422)
- `coverSlide`: `ReaderCoverPageTurn` (spread or single) (shell:106-179)
- `pageCurl`: `ReaderShaderPageCurl` / `ReaderPageCurlSpread` (shell:180-239)
- fallback leaf/spread: `_buildPageLeaf` | `_buildSpread` (shell:240-274)

Page leaves/spreads are built in `native_reader_rendering.dart`: `_buildPageLeaf` (`:296`) wraps a page in `ReaderPaperPageLeaf`; `_buildSpread` (`:354`) = `Row[Expanded(left), gutter, Expanded(right??)]`; plus `_buildBookPageSnapshot` (`:68`), `_buildBlankPageSnapshot` (`:225`), `_buildCoverSpreadSnapshot` (`:31`), `_buildPageCurlSpread` (`:103`). The cell builder `_buildPage` (`native_reader_shell.dart:4`) renders one `_ReaderPageData`: styled text, an inline chapter-title column (if `showsInlineChapterTitle`, shell:18-28), or an image+text column when `imageBlockIndex != null` (shell:31-59).

## 2. Paging-mode decision and ONE shared pagination result

### Mode enum
`enum ReaderPageMode { verticalScroll, instantPage, horizontalSlide, coverSlide, pageCurl }` - `lib/core/reader/reader_layout.dart:4`, aliased locally `typedef NativePageMode = ReaderPageMode;` (`native_reader_page.dart:112`). Default `ReaderSettings.defaultPageMode = ReaderPageMode.horizontalSlide` (`lib/core/reader/reader_settings.dart:56`); stored field `NativePageMode _pageMode` (`native_reader_page.dart:293`).

### How a mode is chosen / changed
- Loaded from settings in `_loadPageMode()` (`native_reader_configuration.dart:4`): reads `_readerSettingsStore.load()` and assigns `_pageMode = settings.pageMode` (`:26`).
- Changed by the user via `_showPageModeSettings()` (`native_reader_controls.dart:470`) -> `_setPageMode(mode)` (`native_reader_page.dart:676`): nulls `_pageController`, bumps `_pageControllerGeneration`, sets `_pageIndex=0`, `_restoreAnchorAfterLayout=true`, resets the horizontal window, and persists the setting.

### SHARED pagination: one canonical page list per chapter
Both single-chapter and multi-chapter modes consume the **same** `List<_ReaderPageData>` produced by `_pagesFor(...)` (`native_reader_page_cache.dart:4`) - the only place `_paginateChapter`/`_restoreNativePagination` is called. Field: `late Map<String, List<_ReaderPageData>> _pageCache` (`native_reader_page.dart:256`).

`_pagesFor(chapter, chapterIndex, size, direction, textScaler)` (`page_cache.dart:4`):
1. Computes `_paginationFingerprintFor(...)` (`:192`, see section 4).
2. Returns `_pageCache[key]` if present (`:23-24`).
3. Else restores from `_persistedPaginationPayloads` via `_restoreNativePagination` (`:26-42`).
4. Else calls `_paginateChapter(...)` (Timeline span `paginateChapter`, `:48-75`) and stores+persists (`:76-81`).

The per-chapter `pages` list is computed **once** in `_buildReaderPage` (scaffold:124-130: `final pages = _pagesFor(...); _visiblePages = pages;`) and passed to `_buildReaderContent`. Mode dispatch on the SAME list:

| Mode | Surface consumes | Wrapper list |
| --- | --- | --- |
| `verticalScroll` | `_ReaderPageData` via `_ContinuousReaderPart` | none (scaffold:132-140) |
| `instantPage` | `pages[_pageIndex]` via `_buildPageLeaf` | none (shell:267-274) |
| `horizontalSlide` | `_ReaderPageData` per page | `List<_BookPageRef>` (`_bookPagesFor`, horizontal:42-149) -> `PageView.builder` |
| `coverSlide` | `_ReaderPageData` per snapshot | `_BookPageRef` -> `ReaderCoverPageTurn` |
| `pageCurl` | `_ReaderPageData` per snapshot | `_BookPageRef` -> `ReaderShaderPageCurl` / `ReaderPageCurlSpread` |

The three book modes build a flat `_BookPageRef` list by iterating `_horizontalFirstChapter.._horizontalLastChapter`, calling `_pagesFor` per chapter and wrapping each page. `class _BookPageRef` (`native_reader_chapter.dart:277-303`) carries `chapterIndex`, `pageIndex`, `pageCount`, `layoutFingerprint`, and `final _ReaderPageData content` (the SAME page object) plus `isBlank` and `isForwardBoundary` (sentinel from `_BookPageRef.forwardBoundary`, :287, for window expansion).

The branch is scaffold:143-156: `bookPages` is non-empty only for `horizontalSlide`/`coverSlide`/`pageCurl`; else `const <_BookPageRef>[]`. So **one** `_ReaderPageData` list per (chapter x layout-fingerprint) is produced and simply *consumed differently* by each surface; all four share the same position/progress persistence (section 5).

### Pagination data model
`class _ReaderPageData extends ReaderTextPage` (`native_reader_chapter.dart:315`). Base `class ReaderTextPage` (`lib/core/reader/reader_text_pagination.dart:27`): `text`, `startOffset`, `endOffset` (canonical UTF-16 source range), `layout` (`ReaderTextLayout?`), `layoutStart/layoutEnd/displayStart/displayEnd` (boundaries in `layout` actually painted), `isChapterTitle`. Subclass adds `imageBlockIndex` and `showsInlineChapterTitle` (`:347-348`), `const _ReaderPageData.chapterTitle()` (`:330`), `fromTextPage(...)` (`:335`), `copyWith` (`:350`). Continuous vertical mode flattens pages into `class _ContinuousReaderPart { final _ReaderPageData content; final int? imageBlockIndex; }` (`:369-374`).

## 3. Chapter parsing feeds pagination

Parsing produces `_NativeChapter` values (`chapter.dart:3`) whose key fields feed pagination: `id`, `title`, `depth`, `isNeedSplitTitle`, `replaceBookTitle`, the `plainText` getter (`:95`, post replace-rules), `blocks` getter (`:100`) and `textBlocks` (`:105`). Lazy variants: `_NativeChapter.lazyFileText(...)` (`:17`) for large TXT via a byte-range index; `_NativeChapter.lazyEpub(...)` (`:30`) loaded from the EPUB isolate.

Parsers (all `part of` the page file):

- **`native_reader_parsers.dart`** - rich book parsers:
  - `_parseEpubChapters(bytes)` (`:3`): `EpubReader.readBook`, walks the **spine** (reading order), borrows titles/depth from the NCX, converts each XHTML via `_chapterMapFromHtmlDocument`, returns `{'chapters':[...], 'images':{name:base64}}`.
  - `_chapterMapFromHtmlDocument(...)` (`:100`): builds `plainText` + `blocks` (text blocks with fontScale/bold/italic/color; image blocks at `startOffset==endOffset`).
  - `_parseKindleChapters(bytes)` (`:228`): `parseKindleContent`, splits MOBI7 by `<mbp:pagebreak>`, rewrites image refs, reuses the same HTML converter.
  - `_parseTxtFileInBackground` (`:341`) and `_indexTxtFileInBackground` (`:368`) - the latter writes a byte-range index (`dataPath`, per-chapter `start`/`end`) for lazy reads.
  - `_richChaptersFromParsed` (`:538`) decodes each image base64 once and shares bytes across `_NativeBlock`s; `_nativeChaptersFromFileIndex` (`:591`) builds lazy chapters.
- **`native_reader_document_parsers.dart`** - plain documents (all produce `blocks: [_NativeBlock.text(text)]`): `_parseHtmlDocument` (`:3`), `_parseMarkdownDocument` (`:49`) -> `_parseTxtChapters`, `_parseFb2Document` (`:62`), `_extractRtfText` (`:159`), `_extractDocxText` (`:173`), `_parseTxtChapters` (`:196`) using `parseTxtChapterSections` (`txt_chapter_parser.dart`).
- **`native_reader_chapter.dart`**: `_NativeChapter.navigationOffsetFor(navigation)` (`:171`) maps a nav entry to a canonical offset; `applyEpubResult` (`:148`) applies isolate output.

**Parsing -> pagination bridge:** a parsed `_NativeChapter`'s `plainText`/`blocks` go to `_paginateChapter` (`native_reader_pagination.dart:3`), which (1) builds `imageOffsets` for `block.hasImage` (`:14-32`), (2) computes dedicated/inline title handling (`:34-47`), (3) segments text between images (`paginateRange`, `:54-94`) calling core `paginateReaderText(...)` (`lib/core/reader/reader_text_pagination.dart:142`), (4) reduces the first page text height for image pages (`:108-113`), and (5) returns `_ReaderPageData` (single empty page fallback at `:149-158`). `paginateReaderText` builds one shared `ReaderTextLayout.build(...)` for the whole chapter, runs `NativeTextPaginator(...).paginate(...)` (`:249-258`), and maps each range back to canonical `startOffset/endOffset` via `layout.sourceOffsetForDisplayOffset` (`:263-270`). `_normalizesParagraphBreaks(format)` (`pagination.dart:168`) is true for `txt`/`epub`.

Heavy per-chapter layout is deferred by **`_scheduleBookPaginationWarm`** (`native_reader_page_cache.dart:85`): defers whole-chapter pagination until the opening animation settles (`_openingFlightSettledNow`), loads lazy text via `_loadIndexedChapterWindow`, waits for the PageView to be idle, then calls `_pagesFor`. Warmed chapters: `_horizontalLastChapter+1` and `_horizontalFirstChapter-1` (scaffold:157-174).

## 4. Page caching & pagination-cache persistence

### 4a. In-memory page cache (per layout fingerprint)
- Field: `late Map<String, List<_ReaderPageData>> _pageCache` (`native_reader_page.dart:256`).
- Key: `_paginationFingerprintFor(chapterIndex, size, direction, textScaler)` (`page_cache.dart:192`) builds a `ReaderLayoutFingerprint` (`lib/core/reader/reader_layout.dart:35`) whose `cacheKey('native-line-v8')` (`:217`) hashes `contentKey='$chapterIndex'`, `viewport`, `fontSize`, `fontWeight`, `lineHeight`, `letterSpacing`, `textAlign`, `horizontalMargin`, `verticalMargin=_topMargin+_bottomMargin`, `textScaler`, `locale`, `pageMode`, `firstLineIndent`, `paragraphSpacing`, `textDirection`, plus an `extra` string combining the vertical/safe-area `paginationSignature`, `_readerFont.id`, and the TXT title-page flag (`:213-216`).
- Eviction: `maxCachedLayouts = (format=='epub' ? 12 : 96)`; when full, remove `_pageCache.keys.first` (`:17-21`). Also invalidated on font/layout/replace-rule changes.

### 4b. Persistent pagination cache (disk via `PaginationCacheDao`)
Fields (`native_reader_page.dart`): `_persistedPaginationPayloads` (`:259`, `Map<String,Uint8List>`), `_paginationCacheLoadFuture` (`:260`), `_paginationCacheWriteQueue` (`:261`). Extension `native_reader_pagination_cache.dart`:

- **`_paginationBookRevision`** (`:4`): `sha1(utf8(_bookCacheKey))`, where `_bookCacheKey` encodes format-prefix + `contentHash`/`filePath` + `fileModifiedTime` + `textEncoding` (page.dart:555).
- `_loadPersistedPaginationCache()` (`:7`): `_paginationCacheDao.loadForBook(bookId, _paginationBookRevision)` -> fills `_persistedPaginationPayloads`.
- `_persistNativePagination({layoutFingerprint, chapterIndex, pages})` (`:24`): serializes via `_encodeNativePagination` (`:67`) -> `ReaderPaginationCacheCodec.encode(...)`, stores in memory, queues `_paginationCacheDao.upsert(bookId, bookRevision, layoutFingerprint, chapterIndex, payload)` on the write queue.
- `_clearPersistedPaginationCache()` (`:54`): clears + `_paginationCacheDao.deleteForBook(bookId)` (used after replace-rule reload, controls:390).
- Encode captures per page (`:67-89`): `isChapterTitle`, `showsInlineChapterTitle`, `imageBlockIndex`, `layoutSourceStart/layoutSourceEnd`, `layoutStart/layoutEnd`, `displayStart/displayEnd`, `sourceStart/sourceEnd`.
- Restore `_restoreNativePagination(payload, chapter, firstLineIndent, paragraphSpacing, normalizeParagraphBreaks)` (`:92`): re-decodes into `_ReaderPageData`, **rebuilds** `ReaderTextLayout.build` per unique `(layoutSourceStart, layoutSourceEnd)` range (`:149-165`), validates bounds/invariants (`:105-177`) and source-coverage continuity (`:194-200`); any inconsistency -> returns `null` and the caller drops the key (`page_cache.dart:41`).

### 4c. Module-level memory caches (`native_reader_page.dart:121-125`)

    final Map<String, Future<List<_NativeChapter>>> _bookMemoryCache;
    final Map<String, List<ReaderNavigationChapter>> _navigationMemoryCache;
    final Map<String, Map<String, List<_ReaderPageData>>> _paginationMemoryCache;

Keyed by `_bookCacheKey`; avoid re-parsing/re-warming across re-opens of the same book (cleared on replace-rule reload, controls:393-395).

## 5. Page position / progress -> canonical offsets and saving

### Canonical model
A page's canonical anchor is its **UTF-16 source offset** into `_NativeChapter.plainText`: `_ReaderPageData.startOffset` / `endOffset`. The persistence unit is a **`CanonicalLocator`** (`lib/core/reader/canonical_locator.dart`).

### Main persister: `_saveCanonicalProgress` (`native_reader_page.dart:615-662`)
Given `chapter`, `page` (`_ReaderPageData`), `chapterIndex`: `_anchorOffset = page.startOffset` (`:620`); builds `CanonicalLocator.fromComponents(format, chapterId, offset, excerpt: 72 chars, progression)` (`:628-636`); `chapterProgress = page.endOffset/chapter.plainText.length`; `readingProgress = (chapterIndex+chapterProgress)/chapterCount` (`:637-643`). Two write paths: `ReadingResumeService.recordPosition(bookId, canonicalLocator, chapterIndex)` (`:645-651`) and queued `BookDao().updateBookCanonicalLocator(bookId, canonicalLocator, null, _layoutSignature, chapterIndex, readingProgress)` (`:652-661`). Writes serialize through `_positionSaveQueue` (`ReaderPositionSaveQueue`, page.dart:284) via `_queuePositionWrite` (`:670`), flushed by `_flushPendingPositionSave` (`session.dart:165`).

### Per-mode position -> offset translation
- **Non-vertical modes:** LayoutBuilder detects change via `locationKey = '$_chapterIndex:$_pageIndex:${pages[_pageIndex].startOffset}'` vs `_lastSavedLocation`, then post-frame calls `_saveCanonicalProgress(chapter, pages[_pageIndex], _chapterIndex)` (scaffold:213-229). Horizontal also commits pending pages via `_onBookPageChanged` / `_publishPendingHorizontalPage` (horizontal_window.dart:160).
- **Vertical / scroll-by-chapter:** `_onVerticalPagePositionsChanged` (vertical_paging.dart:36) computes `_continuousOffsetAtViewportCenter(...)` and saves a synthetic `_ReaderPageData(text:'', startOffset:offset, endOffset:offset)` (`:59-63`).
- **Vertical whole-book:** `_onVerticalChapterPositionsChanged` (`:66`) picks the chapter+page whose item crosses the viewport center, updates `_chapterIndex/_pageIndex`, queues `_queueBookProgress(bookId, nextChapter)` on chapter change, saves the centerline offset (`:131-141`).
- **Read-aloud:** `_persistReaderAloudPosition` (controls:139) maps `(chapterIndex, offset)` -> locator and queues the same DB write.

### Save triggers
- Route exit: `_exitReader` (session:119) -> `_persistCurrentReaderPosition(reason:'exit')` + `_flushPendingPositionSave`. Commits a deferred horizontal pending page first (session:142-152), else the visible page (session:154-163).
- Lifecycle pause/hide: `_persistCurrentReaderPosition(reason:'lifecycle')` (page:404-405).
- Restore side: init sets `_anchorOffset = toCanonicalLocator()?.textAnchor?.startOffsetUtf16`, `_savedChapterId`, `_initialPositionRestored` (page:374-379). LayoutBuilder restores the page index from the anchor via `_restoreAnchorAfterLayout` (scaffold:185-211) by finding the `_ReaderPageData` whose range contains the anchor; vertical schedules `_scheduleInitialContinuousScrollRestore`.

## Key field / method cheat-sheet

- `_pageMode` (NativePageMode = ReaderPageMode), `_chapterIndex`, `_pageIndex`, `_visiblePages: List<_ReaderPageData>`, `_visibleContinuousParts: List<_ContinuousReaderPart>`.
- `_pageController` (PageController) + `_horizontalPageIndexMap` (`_HorizontalPageIndexMap`, horizontal:3), `_horizontalFirstChapter` / `_horizontalLastChapter`.
- `_pageCache`, `_persistedPaginationPayloads`, `_positionSaveQueue`, `_anchorOffset`, `_verticalCanonicalOffset`, `_horizontalPageTurnTracker` (`PendingHorizontalPage<_BookPageRef>`).
- Surface builders: `_buildReaderContent` (shell:62), `_buildPage` (shell:4), `_buildPageLeaf` / `_buildSpread` (rendering:296/354), `_buildHorizontalSlideSurface` (horizontal:332), `_buildVerticalReadingWindow` / `_buildVerticalBook` / `_buildVerticalPageList` (vertical:14/517/487).
- Pagination: `_pagesFor` (page_cache:4), `_paginateChapter` (pagination:3), `paginateReaderText` (core reader_text_pagination:142), `_bookPagesFor` (horizontal:42).
