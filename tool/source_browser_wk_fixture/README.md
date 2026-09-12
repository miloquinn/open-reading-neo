# Source browser WKWebView fixture

Run `./tool/source_browser_wk_fixture/run.sh` on macOS with Xcode installed.

The fixture uses two local HTTP origins and a real non-persistent `WKWebView` to verify HttpOnly cookie restoration, document-start localStorage restoration, same-origin logout without stale-session resurrection, cross-origin iframe restoration and capture, origin isolation, the `__proto__` key, and cancellation cleanup.

This fixture verifies the browser semantics and JavaScript message protocol used by the source-browser session. It does not compile or invoke the product `SourceBrowserSessionBridge` classes directly; the iOS and macOS bridge files require separate Swift typechecks and Runner project build verification.
