# Book-source architecture

The book-source feature follows a one-way dependency flow:

1. Pages compose dependencies and own navigation, localization, dialogs, and
   widget lifecycle.
2. Controllers own immutable workflow state, request generations, pagination,
   filtering, and stale-result suppression. Controllers never receive a
   `BuildContext`.
3. `BookSourceClient` is the stable application facade. It routes calls through
   `BookSourceGateway` to the ORSP or reading-source backend.
4. Protocol backends translate protocol-specific data. ORSP owns HTTP/cache
   behavior; the reading-source backend adapts `SourceRuntime`.
5. Shared chapter/response/cover caches live in `caching/`. SSRF and pinned
   HTTP policy live in `networking/`. `services/` stays the application
   facade and composition root.
6. `SourceRuntime` is the composition root for request, login, catalog,
   reading, rule, script, interaction, cookie, and transport capabilities.

## Ownership

Injected clients, services, transports, and runtimes are borrowed. Dependencies
created by a page, service, or composition root are owned by that creator and
closed once, in child-before-parent order. Closing a runtime transport cancels
pending network work; disposal must not wait indefinitely for that work first.

## Compatibility boundaries

`source_engine/source_request.dart` and
`pages/book_sources/widgets/sourced_book_widgets.dart` are compatibility export
barrels for existing callers. Production modules import leaf files directly so
their dependencies remain explicit.

Root `source_engine/source_rule_*.dart` and `source_engine/source_script_*.dart`
files are export shims that preserve old package URIs for tests and tools.
Production modules must import the implementations under `rules/` and
`scripting/`.

## Architecture map

- `source_engine/rules/` — CSS, XPath, JSONPath, regex, and put/script-rule
  orchestration (`SourceRuleEngine` and selector modules).
- `source_engine/scripting/` — script contract, QuickJS host/bootstrap/APIs,
  and the native/web platform export (`source_script_engine_platform.dart`).
- Remaining `source_engine/*.dart` files stay at the package root until later
  transport/runtime splits.

## Extension points

- Add protocol behavior behind a `BookSourceGateway` backend.
- Add runtime behavior through a narrow capability/port and compose it in
  `SourceRuntime`.
- Add extraction syntax in the selector-specific rule modules; script/put
  orchestration belongs to `SourceRuleScript`.
- Add page workflows to controllers and keep widgets render-only.

## Verification

Focused tests cover facade routing, owned/borrowed resources, runtime ports,
request/response handling, rule/script parity, immutable controllers, page
ownership, and the HTTP end-to-end reading flow. The architecture guard in
`test/book_source_architecture_test.dart` prevents production files from
exceeding 800 lines, importing compatibility barrels or root rule/script
shims internally, or keeping cache/network-policy files on the old
`services/` paths.

## Reading-source compatibility contracts

Regression fixtures cover the reading-source compatibility contracts around
`AnalyzeUrl`, `RuleAnalyzer`, `AnalyzeByJSoup`, and `webBook/BookContent`.

- Split HTML rule chains with the shared balanced rule parser. Quoted attribute
  values and predicates can contain `@` without introducing another rule stage.
- Metadata URL extraction keeps the first nonblank attribute. Content evaluation
  with a nonempty `joinSeparator` collects distinct attribute values in source
  order. Keep the string path through script, put, and replacement stages so
  collecting multiple images never requires running a source script twice.
- Request options start at the first `,{` delimiter; nested JSON body arrays
  and quoted values may contain later delimiters. POST bodies may be JSON
  objects/arrays or strings. Preserve explicit content types and form encoding;
  structured JSON defaults to the JSON media type. GET/HEAD ignore body options.

- A single `nextContentUrl` follows a chain; multiple first-page URLs form a
  fixed list. Fetch fixed pages with at most four concurrent requests, consume
  content rules in page order, deduplicate redirects, stop before the next
  chapter, and retain the twenty-page limit. Capture prefetch errors immediately
  and surface them when consuming that page.
- `subContent` and `title` use the first response context after content pages.
  Text sources append local or fetched subcontent before chapter-wide regex
  replacement. Optional title errors preserve the original title and content,
  matching the reference; content and pagination errors still propagate.
- `html` returns outer tags with descendant script/style nodes removed from a
  clone. `all` preserves raw outer tags. A later rule sees the unchanged DOM.
- Synchronous script DOM helpers share string evaluation and replacement
  semantics with asynchronous rules. `java.htmlFormat` preserves paragraph
  indentation, image options, and entities; `Jsoup.text()` returns plain text.

The scripting bridge is split into encoding, Java-class adapters, DOM, text,
and crypto modules. Character conversion covers UTF-8, GBK/GB2312, UTF-16,
ASCII, and Latin-1; unsupported charset names fail explicitly. Supported Java
adapters include String, Base64, URL form encoding, ArrayList/Map convenience
methods, MessageDigest, and the existing cipher/HMAC operations. Class/package
imports are restored after each invocation, including failures and network
replay. The adapters implement tested method shapes, not a full JVM or Rhino.
Android UI, arbitrary Java reflection/bytecode, unrestricted filesystem APIs,
full Jsoup APIs, and all Java charset/collection overloads are not supplied.
Existing traditional/simplified conversion remains a limited character table.
Do not infer complete source compatibility from these individual fixtures or
compensate for unsupported APIs with broad raw-page scraping.

Image extraction lives in `source_content_images.dart`; shared cover/chapter
asset URL and request-option parsing lives in `source_remote_asset.dart`.
Neither helper depends on runtime orchestration. `source_text_replacement.dart`
retains page origins through chapter-wide text regex replacements, then reuses
the same image extractor. Literal replacement text belongs to the page where
the match starts; captured text moved across page boundaries uses that base
too. Evaluate chapter rules once and resolve assets against response URLs. Keep image
order while merging repeated URLs through one accumulator. Attach current
source/login headers and cookies after content scripts have finished.

Raw-page recovery is a bounded compatibility path for missing comic rules.
It must not replace a successful explicit selection or revive images removed
by `replaceRegex`. Normal successful extraction should not scan the raw page.
