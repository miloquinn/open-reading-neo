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
5. `SourceRuntime` is the composition root for request, login, catalog,
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
exceeding 800 lines or importing compatibility barrels internally.
