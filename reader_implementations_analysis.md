# Open Reading — Reader Implementations Analysis

Analysis of two reader implementations in `/Users/xiaoyuan/code/open-reading`:
**A) PDF reader** (`pdfx`) and **B) online book-source reader** (curl rendering + book-source page).

Both readers ultimately share two rendering substrates:
- The **full-page bitmap** reader (`PagedImageReader`) reused by PDF, comics, and image-only chapters.
- The **flowing-text page** reader (text pagination primitives: `ReaderTextPage`, `NativeTextPaginator`, `ReaderPaperPageLeaf`, `ReaderShaderPageCurl`) reused by online chapters.

---

## 1. PDF reader (pdfx)

**File:** `lib/pages/reader/pdf/pdf_reader_page.dart` (239 lines) — a **full-page bitmap** reader that does *not* use text line boxes at all (header comment lines 1-6). It renders every PDF page to a PNG raster and hands it to the shared image-paging skeleton `PagedImageReader`.

### 1.1 Document opening (PdfDocument, not PdfPageImage)
- Imports `package:pdfx/pdfx.dart` (line 13).
- `PdfReaderPage` (line 25) takes `Book book` + `ReaderThemePalette initialTheme` (lines 32-33) and exposes statics `open(...)` (lines 36-62) wrapping the route in a cover-expanding transition (`BookOpenTransition.createRoute` / `push`, lines 49-56).
- State `_PdfReaderPageState` (line 68) opens the document lazily into `late final Future<PdfDocument> _documentFuture` (line 75), created by `_openDocument()` (123-132): **Web** reads from `WebBookFileStore` -> `PdfDocument.openData(bytes)` (124-129); **Native** -> `PdfDocument.openFile(...)` (131).
- The reader uses only `PdfDocument` + per-page `page.render(...)` -> `PdfPageImage`. It extracts `.bytes` from the returned `PdfPageImage`; it does NOT use the `PdfPageImage` widget/thumbnail APIs.

### 1.2 Page rendering (serial chain + LRU)
- Target render width `_renderWidth` (84): initially 1080, then `didChangeDependencies` (96-103) = `media.size.width * media.devicePixelRatio`, clamped `[480, _maxRenderWidth]`; `_maxRenderWidth = 2160` (73) caps pixel load.
- `_renderPage(PdfDocument, int)` (165-183): `document.getPage(index + 1)` (1-based, 166) -> uniform `scale = _renderWidth / page.width` (168) -> `page.render(width/height scaled, format: PdfPageImageFormat.png, backgroundColor:'#FFFFFF')` (169-175; white fill for transparent PDFs) -> `image.bytes` (179) -> `await page.close()` in `finally` (181). pdfx (Android) forbids parallel rendering — one page must close before the next opens (comments 79-81).
- **Serial chain `_renderChain`** (81): every `_loadPage` job is appended via `_renderChain = _renderChain.then((_) async { ... })` (145), guaranteeing one render+close at a time.

### 1.3 Page cache (LRU)
- `final LinkedHashMap<int, Uint8List> _pageCache` (76); `_pageCacheLimit = 5` (70; one A4 page at 2x approx 10 MB).
- `_loadPage` (134-163): hit -> `_pageCache.remove(index)` then re-insert to move to **tail** (LRU touch, 135-139); in-flight dedupe via `_pendingPages` (140-141, 144); after render inserts `_pageCache[index]` and evicts head while `length > _pageCacheLimit` (151-154); errors propagate via `Completer` (143, 156-159).

### 1.4 Page navigation, position tracking & saving
- Delegated to shared `PagedImageReader` (`lib/pages/reader/image/paged_image_reader.dart`, import line 19; used 227-234): `pageCount: document.pagesCount`, `initialPage: widget.book.currentPage` (restore), `loadPage: (index) => _loadPage(document, index)`, `onPageChanged: (index) => _saveProgress(index, document.pagesCount)`, `bookId`.
- `_saveProgress(int,int)` (185-197) -> `BookDao().updateBookProgress(bookId, index, readingProgress: (index+1)/pageCount)`.
- `initState` -> `ReadingResumeService.markReading(book.id)` (91); `dispose` -> `markClosed` (108) and waits for the render chain to drain before `document.close()` (110-119).
- Open failure / zero pages -> `PagedReaderMessageScaffold` (207-226).

**PagedImageReader (shared skeleton):** `PageView.builder` + `InteractiveViewer` zoom (double-tap/pinch; zooming disables swiping via `_zoomed`), volume-key paging, RTL tap-zone mirroring, per-book direction/background persistence, jump dialog, progress slider. See constructor 28-58, state 64-88, preload + `onPageChanged` 121-133, paging 156-208, build 363-399, zoom 701-793.

### 1.5 Linux unsupported logic (pdfx has no Linux implementation)
- `lib/core/reader/native_reader_service.dart` `NativeReaderService.openBook` (50): in the `if (format == 'pdf')` dispatch (115): `if (!kIsWeb && Platform.isLinux)` -> `showSideToast(..., context.l10n.readerPdfLinuxUnsupported, kind: SideToastKind.warning)` and **returns without opening** (116-125); otherwise `PdfReaderPage.open(context, repaired, ...)` (126-137).
- Header docs: `pdf_reader_page.dart` line 5; `native_reader_service.dart` line 117; `lib/services/books/book_format_support.dart` lines 112-120.

---

## 2. Online book-source reader

**Main controller:** `lib/pages/reader/book_source/book_source_reader_page.dart` (528 lines). Part files (all `part of 'book_source_reader_page.dart'`, declared lines 79-88): `_vertical_paging`, `_pagination_rendering`, `_basic_turning`, `_curl_rendering`, `_catalog_loading`, `_chapter_loading`, `_navigation`, `_settings`, `_aloud_actions`, `_shell`.

The four turn modes are one enum: `typedef BookSourcePageMode = ReaderPageMode` (line 94). Switch values: `instantPage`, `horizontalSlide`, `coverSlide`, `pageCurl`, plus continuous `verticalScroll`.

### 2.1 Chapter parsing from online sources
- **Catalog** `_initialize()` (`_catalog_loading.dart` 4-93) runs `Future.wait` (11-26) of `_client.getChapters(source, book.id, sourceVariables)` (12-16) + saved progress + settings; sorts by `order` (27-28), cleans titles (`_withReplacedChapterTitles` 105-116 -> `_cleanChapterTitle` 95-103 via `ReplaceRuleService`); restores `initialIndex` from `saved.chapterIndex` or chapter id (38-47); calls `_loadChapter(initialIndex, restoreProgress: saved?.chapterProgress...)` (77-84).
- **Content** `_continuousContentFor(int)` (`_chapter_loading.dart` 145-217): dedupes via `_continuousContentLoads` (150-151); `_client.getChapterContent(source, bookId, chapterId, sourceVariables: {...})` injecting `chapterIndex/chapterTitle/bookName/bookAuthor/bookType` (155-167).
- **Text normalization** `readableBookSourceChapterTextAsync` (line 173; impl `lib/book_sources/services/book_source_chapter_text.dart`): probes payload (`_looksLikeHtml` regex, lines 15, 95) rather than trusting `contentType`; extracts paragraphs (`_extractHtmlParagraphs` 109-160, `_extractPlainTextParagraphs` 100-103); strips repeated remote `N/N` page markers (`removeRepeatedSourcePageMarkers`, `book_source_text_paginator.dart` 7-31); drops repeated leading title (`_removeRepeatedLeadingChapterTitle` 162-183).
- Applies replace rules: `ReplaceRuleService.instance.apply(readable, ...)` (177-182), stored in bounded `_readableChapterText` (limit 8; `_bookSourceReadableChapterTextLimit` page line 91; evicts head 183-186). Image-only chapters -> empty text (`isImageOnlyBookSourceChapter`, 171). Caches to `_prefetchedContent[index]` (187).

### 2.2 Pagination — reuses paginateReaderText / ReaderTextPage / NativeTextPaginator
Yes — online chapters are paginated by the **shared** flowing-text pipeline, not a book-source-specific engine.
- **Adapter** `lib/book_sources/services/book_source_text_paginator.dart`: `typedef BookSourceTextPage = ReaderTextPage` (line 5). `paginateBookSourceText(...)` (33-67) builds `NativeTextFlowStyle` (47-54) and delegates to `paginateReaderText(...)` (55-66) with `normalizeParagraphBreaks: true`, `includeChapterTitlePage`, first-line indent + paragraph spacing. `bookSourcePageIndexForOffset` -> `readerTextPageIndexForOffset` (69-71).
- **Shared pipeline** `lib/core/reader/reader_text_pagination.dart`: `ReaderTextPage` (28-134) carries `text`, `startOffset/endOffset`, `layout/layoutStart/layoutEnd/displayStart/displayEnd`, `isChapterTitle`; offset mapping `sourceOffsetForTextOffset` (80-94), `textOffsetForSourceOffset` (96-103); `buildSpan` (105-133). `paginateReaderText` (142-176) is the single entry for local + online chapters — prepends chapter-title page (`ReaderTextPage.chapterTitle` 49-58, used 193-195), builds `ReaderTextLayout`, calls `NativeTextPaginator.paginate` (249-258), wraps ranges into `ReaderTextPage` (259-272). Helpers `readerTextContentWidth` (15-19, clamped to `readerMaxTextContentWidth = 760`, line 13), `readerTextContentHeight` (21-25).
- **Measurement engine** `lib/core/reader/native_text_paginator.dart` — `NativeTextPaginator` (142-380). `paginate()` (157-262) walks left->right; `_lineEndCandidates` (264-332) probes growing line ranges with `flowStyle.createPainter(...).layout` and collects visual line ends via `getLineBoundary`; `_selectVerifiedCandidate`/`_verifiedRange` (334-379) confirm `painter.height <= pageMaxHeight`; runs at purely visual line boundaries; avoids short orphan lines (`avoidShortContinuingLine` 216-238).

### 2.3 Pagination orchestration & cache
- Per-chapter layout cache `_pagedLayouts` (page.dart 214, `Map<int, _BookSourcePagedLayout>`); `_BookSourcePagedLayout` (510-518) = `fingerprint` + `List<BookSourceTextPage> pages`. Vertical analog `_BookSourceVerticalLayout` (519-528) / `_verticalLayouts` (217).
- `_pagedLayoutFor(chapterIndex, content, viewport)` (`_pagination_rendering.dart` 4-56): builds `ReaderLayoutFingerprint` (content id, viewport, font, alignment, margins, text scaler, locale, page mode, indent/spacing, direction) -> `cacheKey('book-source-line-v5')` (15-32); returns cached layout if fingerprint matches, else `paginateBookSourceText` (35-52) and stores (53-55). Vertical uses `cacheKey('book-source-vertical-v2')` (vertical_paging 127-164).
- `_ensurePagination(viewport, content:)` (58-106): binds `_paginatedPages/_pageCount`; restores position from saved text offset (`_restoreTextOffset` via `bookSourcePageIndexForOffset`) -> `_restorePagedPosition` fraction -> re-mapped text offset; rounds into spread for two-page (73-86); post-frame updates `_scrollProgress` and repositions PageView for `horizontalSlide` (87-105).
- Adjacent chapter pages for preview/curl: `_adjacentPageData(...)` (214-239) reuses `_pagedLayoutFor` on `_prefetchedContent`.
- **Pre-warm** `_schedulePagedLayoutWarm` (`_chapter_loading.dart` 219-265): 32 ms debounce; warms next chapter layout (`_pagedLayoutFor` 262); defers while opening cover animates (248-259).

### 2.4 Chapter loading / prefetch
`_loadChapter(index, {restoreProgress, saveCurrent})` (`_chapter_loading.dart` 4-42): guards bounds + `_loadingContent` (9); bumps `_chapterLoadSerial` (13); fast-path prefetched content (14-21); else `_loadingContent = true`, await `_continuousContentFor`, apply (22-42).
`_applyLoadedChapter` (44-94): prepared layout + page index/progress; **prunes** stale paged-layout & warm caches to window `[index-1, index+2]` (62-67); writes `_chapterIndex/_content/_paginatedPages/_paginationKey`; for `horizontalSlide` swaps fresh `PageController` (`_replaceSlidePageController` 84-91, 119-123); then `_preloadAround(index)` (93, 125-133): eager `index+1` first, then opportunistic `index-1, index+2` via `_preloadChapter` (135-143).

### 2.5 Rendering per turn mode
Dispatch in `_buildBody` (`_shell.dart` 123-148) after `_ensurePagination` — `switch (_pageMode)`: instantPage->`_buildInstantReader`, horizontalSlide->`_buildSlideReader`, coverSlide->`_buildCoverReader`, pageCurl->`_buildCurlReader(usesTwoPageLayout)`, verticalScroll->handled earlier (108-121).

#### (a) Basic turning modes — instant & horizontalSlide (`_basic_turning.dart`)
- **instantPage** `_buildInstantReader` (88-102): `GestureDetector` around single `_buildPageLeaf(_paginatedPages[_pageIndex], ...)`; flip is instant (`_turnFromTap` short-circuit 36-44).
- **horizontalSlide** `_buildSlideReader` (104-200): `PageView.builder` (`_pageController`, page.dart 139); itemCount = `_pageViewLeading + _pageCount + trailing` (138) — **prepends previous chapter last pages and appends next chapter first pages** for seamless chapter cross-fade (leading via `_slideLeadingPageCount`, `_chapter_loading.dart` 107-117). Adjacent previews: `_buildAdjacentPreview` (`_pagination_rendering.dart` 241-269) or `_buildBoundaryLeaf` (271-312) when un-cached. Chapter boundary commits queued in `onPageChanged` (`_queueSlideChapterCommit` 139-167), applied after settle via `_schedulePendingSlideChapterCommit`->`_commitPendingSlideChapter` (`_navigation.dart` 148-187).
- Tap dispatch `_turnFromTap` (35-86); stepping `_turnForward`/`_turnBackward` (`_navigation.dart` 217-257) step by `pageStep` (1 or 2), cross chapters via `_loadChapter(restoreProgress: 0|1)`, show controls at book ends.

#### (b) curl / pageCurl rendering (`_curl_rendering.dart`)
- `_buildCurlReader({usesTwoPageLayout})` (4-5) -> single or spread.
- **Single curl** `_buildSingleCurlReader` (85-101) + `_singlePageTurnSnapshots(viewport)` (7-83): builds `current` + `forward` + `backward` **page snapshots**. Current = `_buildPageSnapshot(_paginatedPages[_pageIndex], ...)`. Forward/backward = intra-chapter neighbor (42-48 / 62-67) or, at chapter edge, the **adjacent chapter first/last paginated page** via `_adjacentPageData` with a `selectPageIndex` closure (16-33, 49-77); if un-cached, `_buildBoundarySnapshot`. Feed `ReaderShaderPageCurl(controller: _pageCurlController, currentPage / forwardPage / backwardPage, onTurnForward: _turnForward, onTurnBackward: _turnBackward)` (89-100).
- **How curl renders pages:** `ReaderShaderPageCurl` = `lib/widgets/reader_shader_page_curl.dart` (22-line imports + 16 parts under `lib/widgets/src/page_curl/`). Each snapshot is a `ReaderPageSnapshot` (`reader_page_curl_api.dart` line 8) whose `child` is a concrete `ReaderPaperPageLeaf`. Curl applies custom canvas painters (`page_curl_painters`), interactive drag geometry (`reader_page_turn_geometry.dart`), and a snapshot raster/texture cache (`page_curl_snapshot_cache.dart`). Turn driven by `ReaderPageCurlController.turnForward()/turnBackward()` (api 20-23).
- **coverSlide** `_buildCoverReader` (103-119): same triple-snapshot pattern with `ReaderCoverPageTurn` + `ReaderCoverPageTurnController` (`reader_cover_page_turn.dart` 22, turnForward 25).
- **Two-page (tablet) curl spread** `_buildCurlSpreadReader` (121-364), when `_shouldUseTwoPageLayout` (page.dart 316-319; requires `tabletTwoPageEnabled` + pageCurl + wide layout). Builds spread left/right from `_paginatedPages[spreadStart]`/`[spreadStart+1]` (174-193; right blank for odd final page); blends previous/next spreads across chapter boundaries (143-172, 195-328) with `_blankSourceSnapshot` / `_boundarySnapshot` fallbacks; instantiates **two** `ReaderShaderPageCurl` (left 330-344, right 345-359) bound to `_spreadBackwardPageCurlController`/`_spreadForwardPageCurlController` (page.dart 152-155) sharing `_spreadPageCurlCoordinator` (page.dart 156-157, gutter=24 line 90), each `edgeDragOnly` with `bindingEdge` right/left, and back/forward callbacks so left turns backward only, right turns forward only; hosted in `ReaderPageCurlSpread` (api 174) with `_buildSourceSpreadGutter` (413-423).
- **Snapshot building:** `_buildPageSnapshot` (`_pagination_rendering.dart` 173-212) / `_buildPageLeaf` (108-171) build `ReaderPageSnapshot` / `ReaderPaperPageLeaf` (`lib/widgets/reader_paper_page_leaf.dart`, key 12, leaf 69). Identity = `source:<sourceId>:<bookId>:<chapterId>:<pageIndex>:<startOffset>` + `layoutFingerprint` + `themeId` (186-197); content revision `_leafContentRevision` (page.dart 309-314) repaints dynamic clock/battery/annotations.
- **Body paint:** `_buildAnnotatedTextPage` (`_vertical_paging.dart` 346-392) -> `ReaderAnnotatedTextPage` with `renderer: ReaderRendererType.flutterNative`, `_bodyTextStyle` (`_shell.dart` 171-190), flow style 197-208.

---

## 3. PDF page-as-image conversion & pagination cache

### PDF page -> image conversion
- **Where:** `pdf_reader_page.dart` `_renderPage` (165-183): `PdfDocument.getPage(index+1)` -> `page.render(width, height, format: PdfPageImageFormat.png, backgroundColor:'#FFFFFF')` -> `image.bytes`. The pdfx `PdfPageImage` is unpacked to raw bytes; surfaces render at device pixel density (max 2160 px wide).
- **No disk persistence** — bytes live only in the in-memory 5-entry LRU `_pageCache` and go straight to `Image.memory` in `PagedImageReader._ZoomablePageView` (paged_image_reader.dart 759-791).
- Other PDF->image conversions exist only in the import pipeline for metadata/cover (`book_import_service.dart` 916-949, 1638-1668), not for reading.

### Pagination cache (book-source reader)
- Chapter layout cache `_pagedLayouts` (page.dart 214) — paginated `List<ReaderTextPage>` per chapter, keyed by `_BookSourcePagedLayout.fingerprint` (510-518); vertical `_verticalLayouts` (217). Invalidation on font change (`didChangeDependencies` 392-401) and pruning in `_applyLoadedChapter` (62-67).
- Pre-warmed layouts: `_warmedPagedLayoutIndexes` + `_queuedPagedLayoutWarms` (page.dart 215-216).
- Content caches: `_prefetchedContent` (211, chapter content) and `_readableChapterText` (212, normalized text bounded to 8); in-flight dedupe `_continuousContentLoads` (213).
- Rendered-page (curl) cache: internal snapshot cache in `ReaderShaderPageCurl` (`lib/widgets/src/page_curl/reader_page_curl_snapshot_cache.dart`) so current/forward/backward leaves are rasterized/textured, not re-laid-out, during a turn.
- Paged cache uses `cacheKey('book-source-line-v5')`, vertical `'book-source-vertical-v2'` with distinct signatures — re-pagination happens only when the fingerprint truly changes.
