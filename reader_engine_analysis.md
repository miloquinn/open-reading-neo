# Open Reading — Flutter Native Reader Engine Analysis

Package `xxread`. Every text book is rendered through a NATIVE layout engine (TextPainter + visual-line
pagination + snapshot caching), never a WebView. This document analyzes the shared paging substrate, the
four page-turn modes, TTS, comic/image/PDF readers, fonts & themes, and the page-curl shader, then offers an
architecture critique. All class/file names and line numbers were verified against the source.

---
# 1. Native paging / layout architecture

### 1.1 Chapter parsing (upstream of pagination)

* **TXT** — `lib/services/books/enhanced_txt_import_service.dart` (encoding detection: BOM → UTF-8 strict → GBK → UTF-8 loose; metadata/stats) + `lib/core/reader/txt_chapter_parser.dart`. `parseTxtChapterSections(text,{fallbackTitle,prefaceTitle})` (line 44) returns `List<TxtChapterSection>`, each keeping `bodyStart/bodyEnd` UTF-16 ranges (lines 12–31) instead of copying the book. Reading uses `TxtChapterSection.bodyIn(source)` (line 31). Very large TXT files are indexed: `lib/core/reader/indexed_text_reader.dart` has `readIndexedUtf8Range(Sync)` — `File.open→setPosition(startOffset)→read(range)→utf8.decode` (those are BYTE offsets into the on-disk file).
* **EPUB** — `lib/services/books/epub_native_parser_io.dart` (`_stub.dart` on Web). `loadEpubNativeChapterWindow(map)` (line 392) runs in an isolate: opens the zip with `ZipDecoder`, parses XHTML via `package:html`, resolves CSS rules + `@font-face`, and produces per-chapter JSON `{id,title,depth,plainText,blocks,anchors}` (lines 1020–1026). It caches each chapter to disk (`_writeJsonAtomically` / `_readChapterCache`, keyed by `epubNativeCacheVersion`) and only materializes a bounded chapter WINDOW (`loadEpubNativeChapters` line 473 is a test-only "transfer all" helper).
* Both map into `_NativeChapter` (`lib/pages/reader/native/native_reader_chapter.dart` line 3), with lazy variants `_NativeChapter.lazyFileText` (byte-range, line 16) and `_NativeChapter.lazyEpub` (line 34). It exposes canonical `plainText` and styled `_NativeBlock`s (text/image, `startOffset/endOffset`, `fontScale`, bold/italic/fontFamily/colorHex) after `ReplaceRuleService` (replace rules) is applied.
* `BookReaderLauncher.openBook` (`lib/pages/reader/book_reader_launcher.dart`) uses `BookFormatRegistry` to route formats: comic containers → `ComicReaderPage`; `pdf` → `PdfReaderPage` (Linux blocked); unified text formats → `NativeReaderPage`.

### 1.2 TextPainter measurement and the visual-line paginator

* `NativeTextPaginator` (`lib/core/reader/native_text_paginator.dart` lines 142–380) is the measurement core.
* `NativeTextFlowStyle` (lines 105–142) packages every line-break input: `textDirection`, `textScaler` (`readerBodyTextScaler = TextScaler.noScaling`, so book font size is not double-scaled by Dynamic Type, line 42), `locale`, `strutStyle`, `textHeightBehavior` (lines 59–73; leading applied only between rows), `textAlign`. Its `createPainter(InlineSpan,{maxLines})` (line 131) is the SAME factory used for probe-measurement and final paint ⇒ wrapping parity.
* `paginate(text, spanBuilder, sourceOffset, firstPageHeight)` (lines 157–262) walks left→right:
  1. `_firstVisiblePageOffset` folds blank leading rows (line 375).
  2. `_lineEndCandidates` (lines 264–332) grows a probe (start 2048 chars, doubling), lays out `spanBuilder(start,end)`, and collects VISUAL line ends from `computeLineMetrics()` + `getPositionForOffset` + `getLineBoundary`. It deliberately does NOT hand-compute ascent/descent line boxes (EPUB mixed heading scales overestimate; comment at 176–181). Ink-bottom is a cheap early-out only.
  3. `_selectVerifiedCandidate`/`_verifiedRange` (334–379) re-layout and require `painter.height <= pageMaxHeight`.
  4. Optional `avoidShortContinuingLine` (216–238) backs off to avoid a final orphan line.
* Paragraph/line-break classification at code-unit level in `lib/core/reader/reader_text_characters.dart` (`isReaderLineBreakCodeUnit`, `readerLineBreakLengthAt` — CRLF=2). Output is contiguous `List<NativeTextPageRange>` (`start/end/visibleStart/visibleEnd/lineCount`), asserted to tile text (247–251).

### 1.3 Display projection: indent & paragraph spacing

* `ReaderTextLayout` (`lib/core/reader/reader_text_layout.dart`) is a display-only project of canonical text. `.build(sourceText,{firstLineIndent:0..4,paragraphSpacing:0..2,normalizeParagraphBreaks})` (line 29) emits a `text` display string, `_ReaderTextRun.source` (real chars) / `_ReaderTextRun.generated` (injected HANGUL-FILLER `\u3164` indent + extra newlines), and a monotonic `sourceBoundaries` mapping every display offset back to a canonical UTF-16 offset.
* `sourceOffsetForDisplayOffset` (line 130), `displayOffsetForSourceOffset` (binary search, 133), `sourceOffsetForVisibleStart` (right-biased for selection starts, 146), `buildSpan` (159) re-slices runs through a `ReaderSourceSpanBuilder`.

### 1.4 Single pagination entry point

* `paginateReaderText(...)` (`lib/core/reader/reader_text_pagination.dart` line 142) is used by local chapters AND online book-source chapters (wrapper: `lib/book_sources/services/book_source_text_paginator.dart` `paginateBookSourceText` line 33 → `paginateReaderText` with `normalizeParagraphBreaks:true`). It builds `ReaderTextLayout`, runs `NativeTextPaginator`, returns `List<ReaderTextPage>`. `ReaderTextPage` (line 28) carries `text/startOffset/endOffset/layout/layoutStart/layoutEnd/displayStart/displayEnd/isChapterTitle` + offset-mapping methods (80–103). Width is clamped to `readerMaxTextContentWidth = 760` (line 13).
* Local image interleaving: `_paginateChapter` (`lib/pages/reader/native/native_reader_pagination.dart` line 3) collects image offsets, paginates text segments with `paginateReaderText`, and stamps `imageBlockIndex` on the first page of an image run with a reduced text area (`_imagePage*Flex/_imagePageGap`) — canonical range stays contiguous (110–146).

### 1.5 Page caching (memory + disk)

* `lib/pages/reader/native/native_reader_page_cache.dart`: `_pagesFor` (line 13) computes a fingerprint key and returns cached pages. In-memory `_pageCache` LRU (`maxCachedLayouts`: 96 txt / 12 epub). `_paginationFingerprintFor` builds a `ReaderLayoutFingerprint` → `.cacheKey('native-line-v8')`.
* `ReaderLayoutFingerprint` (`lib/core/reader/reader_layout.dart` lines 48–101) models line-break-changing inputs: contentKey/viewport/fontSize/fontWeight/lineHeight/letterSpacing/textAlign/margins/textScaler/locale/pageMode/indent/spacing/direction/extra. `cacheKey(version)` serializes all; `TextScaler` is fingerprinted by `scale()` of probe sizes 12/24/48.
* Disk: `native_reader_pagination_cache.dart` + `reader_pagination_cache_codec.dart` + `services/books/pagination_cache_dao.dart`. `ReaderPaginationCacheCodec` (magic `0x4350524f`"ORPC", 10 int32/page) round-trips page ranges. `_restoreNativePagination` rebuilds `ReaderTextLayout` from canonical text and validates contiguous tiling (else discard). `PaginationCacheDao` stores per `(book_id, book_revision, layout_fingerprint)`, prunes to `maxLayoutsPerBook=128`, and rejects rows whose `book_revision` (sha1 of content hash + file mtime + encoding) changed.
* `_scheduleBookPaginationWarm` (page_cache 88+) pre-paginates neighbor chapters in post-frame callbacks for horizontal/curl/cover modes, yielding while the opening animation runs.

---
# 2. Canonical Locator & UTF-16 position tracking

* `lib/core/reader/canonical_locator.dart` (1380 lines) is the truth model:
* **`CanonicalLocator`** (line 335) is layout-INDEPENDENT and persisted: fields `version/format/href/chapterId/resourceHref/progression/positionHint/totalPositionsHint/fragments/textAnchor/contentSignature`. Href uses `text://chapter/{id}/offset/{n}/excerpt/{text}` (`_buildTextAnchorHref` line 1280); parsers `chapterIdFromHref/offsetFromHref/excerptFromHref` (370–430). `progression` is clamped 0..1 for percentage-only fallback. Factories `fromHref/fromComponents/fromCfi/fromProgression`.
* **`RenderedLocator`** (line 666) is layout-DEPENDENT (screen position/progression/title/textBefore/textAfter) — UI/short-cache only; docs: persist only `CanonicalLocator`.
* **`TextAnchor`** (line 226): fragile-resume anchor; `quote/prefix/suffix/chapterId/resourceHref/startOffsetUtf16/lengthUtf16`. Snippets normalized (`_normalizedSnippet` collapses whitespace, line 1300). `AnnotationAnchor` (844) and `ReaderSelection` (950) bind bookmarks/highlights/notes. `LocatorCodec` (1198) provides enable/disable JSON round-trips.

**Why progress stays stable across font/layout changes:** the saved/restored offset is a **UTF-16 code-unit offset into `chapter.plainText`** — format-independent, never a page index or a display offset.
* Native save: `_saveCanonicalProgress` (`native_reader_page.dart` ~line 525) → `CanonicalLocator.fromComponents(format, offset: page.startOffset, excerpt)`. On re-layout `_restoreAnchorAfterLayout=true`; the scaffold re-runs `pages.indexWhere((page)=> anchor in [page.startOffset,page.endOffset))` (scaffold ~158–175). Because page ranges tile the canonical text, re-layout lands on the same offset.
* `ReaderTextLayout.sourceBoundaries` guarantees injected indent/spacing never shift canonical offsets.

Note: TXT disk byte-offsets (`indexed_text_reader.dart`) are only a file-read optimization; they are converted to UTF-16 offsets in `plainText` for all canonical work.

---
# 3. The four page-turn modes & shared pagination

* `ReaderPageMode` (`lib/core/reader/reader_layout.dart` line 3): `verticalScroll | instantPage | horizontalSlide | coverSlide | pageCurl`. Mapping: 上下翻页=verticalScroll; 无动画=instantPage; 水平滑动=horizontalSlide (+coverSlide); 经典仿真折页=pageCurl.

**Shared-pagination invariant:** all modes consume the SAME `List<_ReaderPageData>` from `_pagesFor` (page_cache line 4; `_ReaderPageData extends ReaderTextPage`, chapter.dart line 315). In the scaffold (`native_reader_scaffold.dart` ~line 100):
* `verticalScroll` → `_continuousPartsFor(chapter,size)` re-paginates into `_ContinuousReaderPart`s for a two-axis `TwoDimensionalScrollView` (chapter + page axes) — `native_reader_vertical_paging.dart`.
* `horizontalSlide`/`coverSlide`/`pageCurl` → `_bookPagesFor(chapters, first, last, size, ...)` (horizontal_paging line 42) flattens a WINDOW of chapters into `_BookPageRef`s (pageData + chapter/page index + layoutFingerprint; blank padding for spreads). No re-pagination.
* `instantPage`/`verticalScroll` consume the list directly.

Surfaces: `_buildReaderContent` (`native_reader_shell.dart` line 62) dispatches; `instantPage` = single swapped leaf; `horizontalSlide` = `PageView.builder` over `_BookPageRef` window (`_buildHorizontalSlideSurface`, 332) with cross-chapter expansion/contraction and `HorizontalPageTurnTracker` (`lib/core/reader/horizontal_page_turn_tracker.dart`); `pageCurl` = `_buildPageCurlSpread` (`native_reader_rendering.dart` line 65) building `ReaderPageSnapshot`s → `ReaderShaderPageCurl` (single) or `ReaderPageCurlSpread` (tablet).
* Mode persisted in `ReaderSettings.pageMode` and reloaded in `_loadPageMode` (`native_reader_configuration.dart`). Fingerprint includes `pageMode`, so switching mode invalidates the pagination cache.

---
# 4. Reader-aloud / TTS architecture

* Core: `lib/core/reader/reader_aloud_controller.dart` (786 lines). Domain: `ReaderAloudPlaybackState` (13), `ReaderAloudControl` (15), `ReaderAloudPosition` (17), `ReaderAloudSegment` (47), `ReaderAloudHighlight` (66).
* Abstractions: `ReaderAloudEngine implements Listenable` (95: isPlaying/isPaused/currentPosition/speak/pause/stop); `ReaderAloudAdjustableEngine` adds rate/volume; `ReaderAloudSource` (111: currentPosition/loadChapter/revealPosition/persistPosition) with `CallbackReaderAloudSource` adapter (121). `ReaderAloudSegmenter.split` (217) chunks on sentence boundaries (`。！？!?；;：:\n`, ≤320 chars, surrogate-safe).
* `ReaderAloudController extends ChangeNotifier` (303): `start()` reads source position → `_loadChapterAt` → playing; `_playCurrent(generation)` (605) is the loop (reveal→persist→notify→`engine.speak(subtext)`→`_moveNext`), generation tokens cancel stale iterations (`_isCurrent`). `pause/resume/stop/refreshPlayback/previous/next`, sleep timer, debounced save + notification sink. `highlight` getter drives in-page text highlighting.
* System engine: `lib/services/tts_service.dart` `TtsService implements ReaderAloudAdjustableEngine` (line 149) wrapping `flutter_tts`; platform config (Android queueMode flush/awaitSynthCompletion; iOS shared audio session), voice/language persistence, `_currentPosition` from progress handler + `_utteranceBasePosition`.
* Cloud engine: `lib/services/reader_aloud_service.dart` `ReaderAloudService implements ReaderAloudEngine` (557) choosing system/cloud. Cloud = OpenAI-compatible `OpenAiCompatibleReaderAloudCloudClient` (250) + `ReaderAloudCloudAudioCache` (SHA-256 keyed LRU 20/32MB, 378) + `AudioplayersReaderAloudBytesPlayer` (440). Android notification: `lib/core/reader/android_reader_aloud_notification.dart`.

---
# 5. Comic & image readers

* Comic: `lib/pages/reader/comic/comic_reader_page.dart` (193 lines) + `lib/services/books/comic_book_parser.dart`. `compute(indexComicPages,...)` (parser line 163) sniffs container by magic (`detectComicContainer` line 40: PK→zip, Rar!→rar, 7z, ustar→tar), Zip/Tar decode; true RAR/7z throw `ComicArchiveUnsupportedException` → UI '转 CBZ'. Page entries filtered (`isComicPageEntry`) + numeric-aware natural sort (`compareComicEntries`). Bytes decoded per-page via `compute(extractComicPage,...)` (line 181; re-decode of directory is cheaper than copying archive bytes across isolate), behind LRU cap 8 + `_pendingPages` dedup. Progress = index + `(index+1)/pageCount` → `BookDao.updateBookProgress`.
* Image page: `lib/pages/reader/image/paged_image_reader.dart` (876 lines), shared by comics & PDFs (caller supplies `loadPage(index)`). `PageView.builder` full-page images; manga RTL via `reverse:_rtl` + mirrored tap zones; zoom/pan `InteractiveViewer` in `_ZoomablePageView` (line 702, min 1/max 5, BoxFit.contain); overscroll → onReachedStart/onReachedEnd; jump dialog; direction/background persisted via `PagedImageReaderSettingsStore` (`lib/core/reader/paged_image_reader_settings.dart`). NOT implemented: double-page spread, thumbnail grid, continuous vertical scroll, within-page offsets.

---
# 6. PDF reader (pdfx)

* `lib/pages/reader/pdf/pdf_reader_page.dart` (239 lines): full-page bitmap renderer (no text line boxes). `PdfDocument.openFile/openData` (Web) via `package:pdfx`. Rendering is STRICTLY serial — pdfx crashes on parallel Android renders — all jobs chained on `_renderChain = _renderChain.then(...)` (line 145). `_renderPage` (165): `getPage(index+1)` (1-based) → `scale = _renderWidth/page.width` → `page.render(width,height, PdfPageImageFormat.png, '#FFFFFF')` → `image.bytes`; `page.close()` in finally. Render width = screen width×DPR clamped [480,2160].
* LRU `_pageCacheLimit=5` (~10MB/A4@2x), tail-touch eviction, `_pendingPages` dedup. Navigation/zoom/progress delegated to `PagedImageReader`; progress → `BookDao`. Linux unsupported is intercepted by `BookReaderLauncher.openBook`. Waits for render chain before `document.close()`.

---
# 7. Custom fonts, reading themes, custom background images

* Fonts: `lib/services/core/custom_font_service(_io|_web).dart` — `importFontBytes` validates TTF/OTF magic (`_matchesFontSignature`), dedupes by SHA-256, inspects variable-weight axis (`font_variation_parser.dart`), assigns runtime family `OpenReadingCustom_<hash>`, registers bytes via `CustomFontRegistrar` (FontLoader), persists a manifest, `ensureLoaded` re-registers on demand. Online fonts: `online_font_service(_io|_web).dart`.
* Themes: `lib/utils/reader_themes.dart` — `ReaderThemePalette` (line 9: background/text/secondary/surface/controls/accent/.../backgroundImagePath/opacity) + `toThemeData` (53) builds Material3 theme. `ReaderThemes` (141) dispatches built-ins + custom. Custom themes persisted via `ReaderCustomTheme`/`ReaderCustomThemeStore` (`lib/core/reader/reader_custom_theme.dart`); ordering via `reader_theme_order.dart`. Palette `cacheKey` (44) feeds every page-snapshot key → theme change = distinct snapshot.
* Background images: `lib/services/core/reader_theme_background_service(_io|_web).dart` stores jpg/png/webp ≤20MB under `reader_theme_backgrounds` (path-traversal-guarded delete). `lib/widgets/reader_theme_background.dart` stacks color + `Opacity(0..0.75)` image + child. UI: `lib/pages/reader/themes/reader_custom_theme_page.dart` / `reader_custom_themes_page.dart`.

---
# 8. Page-curl shader (classic fold)

* Shader: `shaders/reader_classic_page_fold.frag`. Clean-room right-edge sheet, no LightInk source. Uniforms: `uSize/uPosA,uPosB (crease endpoints)/uBindingOnRight/uHasBackPage/uPaperColor/uPhoneBackInkOpacity/uSourcePage/uBackPage`.
* Per-pixel `main()`: canonicalPoint() mirrors X when binding is right so geometry is computed in a left-bound canonical frame (turn direction and binding are INDEPENDENT inputs — a deliberate fix over LightInk's derived `reverse`); intersects crease `uPosA-uPosB` with top/bottom edges (`lineLineIntersection`), clamps to canonical x=0 ('hard binding'); `isInsideQuad` ray-cast for inside tests; `curlTransform` maps a source pixel across the fold (translate→mirrorX→rotate→translate); `sampleFoldedBack` mirrors source (phone: blends paper color through front ink, `readerPhonePageCurlBackInkOpacity=0.36`) or reflects the authored back page; adjacency glow via `sdSegment`+smoothstep with terminal-pose fade. Degenerate crease falls back to sampling source.
* Dart bridge: `lib/widgets/reader_shader_page_curl.dart` + parts in `lib/widgets/src/page_curl/`:
  - `reader_page_curl_api.dart`: `ReaderPageSnapshot` (key/contentRevision/child), `ReaderPageCurlController`, `ReaderPageCurlCoordinator` (serializes the two leaves of a spread), `ReaderPageCurlSpread` (paint-order leaf layout), `ReaderShaderPageCurl` widget, `readerPageSnapshotPixelRatio` (budget-driven DPR ≤2.5).
  - `reader_page_curl_state.dart`: state machine pointerPending→dragging→settlingBack/Commit→awaitingPageUpdate; catch-up easing for middle-origin forward drags (`_onCatchUpTick`, 120ms, front-loaded ease-in-out); X-driven settle with Y coupled (`reader_page_curl_settle.dart`); commit/reject by projection (`_commitProjection=0.28` + velocity over `_predictionHorizonSeconds=0.14`); programmatic-turn FIFO (`_maxQueuedProgrammaticTurns=2`).
  - `reader_page_curl_painters.dart`: `_ReaderClassicFoldPainter` uploads uniforms + two image samplers to the `FragmentShader`; `_ReaderFallbackTurnPainter` = translation fallback (no-shader path, per design doc).
  - `reader_page_curl_snapshot_cache.dart`: LRU keyed by `ReaderPageSnapshotKey` (pageIdentity+layoutFingerprint+themeId) + `contentRevision` (clock/battery/annotation); byte budget 48MB/8MB; protected-key trim + `_SnapshotRequestKey` generation guard against async cross-page races.
  - Geometry: `lib/core/reader/reader_page_turn_geometry.dart` (`ReaderPageTurnGeometry.fromPointer`, outgoing/incoming crease drivers, progress, foldPoint/anchor/foldNormal/reflectedCorner).
  - `lib/widgets/reader_paper_page_leaf.dart`: `ReaderPaperPageLeaf` (body + footer in one leaf) and `ReaderPageSnapshotKey`.

---
# Critical assessment

### Strengths
* **Genuinely shared pagination core.** `paginateReaderText` is the single source of truth for local AND online chapters; the four turn modes are only views over one `_BookPageRef` stream. Clean plane — UI/animation never leaks into measurement.
* **Measurement/render parity.** `NativeTextFlowStyle.createPainter` drives both probe-layout and final paint; combined with `TextScaler.noScaling` + explicit strut/leading, pagination is bit-stable, making caching safe.
* **Layout fingerprint as first-class identity.** Width/font/line-height/align/margins/scaler/locale/mode/indent/spacing fold into a digest used for memory + SQLite caches AND every page-snapshot key; content-hash book revision invalidation prevents stale geometry.
* **Offsets, not pages, are canonical.** UTF-16 code-unit offsets + `CanonicalLocator` survive any layout change; `ReaderTextLayout` keeps the display projection disjoint so indent/spacing never corrupt offsets.
* **Clear TTS extensibility.** `ReaderAloudEngine`/`Source`/`Segmenter` interfaces; two engines (system flutter_tts + OpenAI-compatible cloud) plug in without touching the controller.

### Weaknesses / risks
* **High coupling in the widget layer.** `_ReaderPageData extends ReaderTextPage` but lives in private part-files; page-cache LRU, pagination cache, and curl snapshotting each re-implement 'which pages are current/neighbor'. The curl state machine (`reader_page_curl_state.dart`, ~1000 lines: gesture + snapshot + spring on ONE widget) is the hardest component to test, despite `@visibleForTesting` debug hooks.
* **Re-pagination burst + coarse invalidation.** Any fingerprint-triggering change (system text scale, margin slider) repaginates the whole chapter and rewrites the persisted payload. On very large TXT chapters this is a main-thread burst mitigated only by byte-range loads + post-frame warm. `_pageCache` eviction is FIFO-by-insert (`remove(_pageCache.keys.first)`), not true recency LRU.
* **UI-thread measurements.** EPUB chapter parsing runs in an isolate, but page MEASUREMENT (TextPainter) is unavoidably on the UI thread; the indexed TXT reader even does synchronous `File.openSync` + UTF-8 decode on the UI isolate (tens of ms for big chapters, acknowledged in `indexed_text_reader.dart`).
* **Serial PDF rendering throughput ceiling.** Platform-mandated; the 5-entry LRU + DPR clamp limit memory but fast-swiping still risks falling behind the PageView.
* **Offset stability depends on unchanged content.** If the source text changes (re-import/edit), UTF-16 offsets can mis-aim; `CanonicalLocator` relies on `excerpt/contentSignature` fuzzy re-anchoring, which is less exercised than the pure-offset path.
* **Pixel-path testability.** The `.frag` shader and snapshot texture lifecycle are hard to unit-test; only budget math (`readerPageSnapshotPixelRatio`, cache budgets) is unit-testable. Glyph-level fit needs goldens/device tests, as the design doc's validation matrix acknowledges.

---
# File map

* Core: `lib/core/reader/` (native_text_paginator.dart, reader_text_pagination.dart, reader_text_layout.dart, canonical_locator.dart, reader_aloud_controller.dart, reader_layout.dart, reader_text_characters.dart, txt_chapter_parser.dart, reader_page_turn_geometry.dart, reader_pagination_cache_codec.dart, reader_custom_theme.dart, paged_image_reader_settings.dart).
* Reader pages: `lib/pages/reader/book_reader_launcher.dart`; `lib/pages/reader/native/` (native_reader_page.dart + _pagination/_page_cache/_pagination_cache/_rendering/_scaffold/_session/_configuration/_horizontal_paging/_horizontal_window/_vertical_paging/_chapter/_controls/_shell/_parsers); `lib/pages/reader/book_source/`; `pdf/pdf_reader_page.dart`; `comic/comic_reader_page.dart`; `image/paged_image_reader.dart`; `themes/`.
* Services: `lib/services/books/` (epub_native_parser_io.dart, enhanced_txt_import_service.dart, comic_book_parser.dart, pagination_cache_dao.dart, book_format_support.dart, kindle_book_parser*); `lib/services/reader_aloud_service.dart`; `lib/services/tts_service.dart`; `lib/services/core/` (custom_font_service*, online_font_service*, reader_theme_background_service*).
* Shader/widgets: `shaders/reader_classic_page_fold.frag`; `lib/widgets/reader_shader_page_curl.dart`, `reader_paper_page_leaf.dart`, `reader_theme_background.dart`; `lib/widgets/src/page_curl/` (6 files).
* Docs: `docs/reader-paper-leaf-experience-plan.md`, `READING_SOURCE_ENGINE.md`, `structure.md`. Subagent reports also on disk: `docs/native_reader_widget_layer_analysis.md`, `reader_implementations_analysis.md`.
