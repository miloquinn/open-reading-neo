# Book-source regression fixtures

`4020_bybk.json` is the `4020🎃#bybk.cc` rule snapshot supplied on
2026-09-05 in `shuyuan.json`. Search, discovery, detail, catalog and content
rules, request headers and source URLs are preserved verbatim. Unused metadata
and discovery categories were omitted; the latest-books category is retained.

`source_runtime_real_rule_regression_test.dart` uses these rules with synthetic
HTML and original test prose. It runs the actual rule engine and QuickJS, and
asserts outgoing URLs across discovery → detail → catalog → chapter content,
including a redirected detail URL. It neither contacts the live site nor proves
that the site accepts requests from a physical device.

For future compatibility fixes, retain the failing imported rule and exercise
the subsequent reading steps as well as the parser. Check both synchronous and
asynchronous evaluation when they share rule semantics. When those semantics
change persisted catalog/content results, update the backend rule-engine cache
revision and verify that old disk entries are bypassed.

These tests use the existing `*_test.dart` discovery in PR checks; no local
source directory or network access is required in CI.
