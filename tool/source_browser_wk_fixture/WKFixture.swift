import AppKit
import Foundation
import WebKit

final class Fixture: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  private let first = URL(string: "http://127.0.0.1:18765/")!
  private var webView: WKWebView!
  private var stage = 0
  private var captured: [String: [String: String]] = [:]
  private var failures: [String] = []
  private var hydrated = Set<String>()
  private var sawIframeRestore = false
  private var sawIframeWrite = false
  private var sawProtoKey = false
  private let initial: [String: [String: String]] = [
    "http://127.0.0.1:18765": ["seed": "one", "onlyA": "A", "__proto__": "literal"],
    "http://127.0.0.1:18766": ["seed": "two", "onlyB": "B"],
  ]

  func run() {
    let script = """
    (function() {
      function capture() {
        var all = Object.create(null); for (var i=0; i<localStorage.length; i++) { var k=localStorage.key(i); all[k]=localStorage.getItem(k); }
        webkit.messageHandlers.fixture.postMessage({origin: location.origin, values: all});
      }
      var original = Storage.prototype.setItem;
      Storage.prototype.setItem = function(k,v) { original.call(this,k,v); if (this === localStorage) capture(); };
      window.fixtureCapture = capture; capture();
    })();
    """
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    addScripts(to: configuration.userContentController, captureScript: script)
    webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
    configuration.userContentController.add(self, name: "fixture")
    webView.navigationDelegate = self

    let cookie = HTTPCookie(properties: [
      .name: "secret", .value: "http-only", .domain: "127.0.0.1", .path: "/",
      HTTPCookiePropertyKey("HttpOnly"): "TRUE",
    ])!
    configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
      guard let self else { return }
      self.webView.load(URLRequest(url: self.first))
    }
  }

  private func addScripts(to controller: WKUserContentController, captureScript: String? = nil) {
    controller.removeAllUserScripts()
    for (origin, values) in initial where !hydrated.contains(origin) {
      let data = try! JSONSerialization.data(withJSONObject: values)
      let json = String(data: data, encoding: .utf8)!
      let encodedData = try! JSONSerialization.data(withJSONObject: json, options: .fragmentsAllowed)
      let encodedJSON = String(data: encodedData, encoding: .utf8)!
      let restore = "if(location.origin==='\(origin)'){var v=JSON.parse(\(encodedJSON));Object.keys(v).forEach(function(k){localStorage.setItem(k,v[k]);});}"
      controller.addUserScript(WKUserScript(source: restore, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    let capture = captureScript ?? """
    (function(){function c(){var a=Object.create(null);for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);a[k]=localStorage.getItem(k);}webkit.messageHandlers.fixture.postMessage({origin:location.origin,values:a});}var s=Storage.prototype.setItem;Storage.prototype.setItem=function(k,v){s.call(this,k,v);if(this===localStorage)c();};window.fixtureCapture=c;c();})();
    """
    controller.addUserScript(WKUserScript(source: capture, injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    if let components = navigationAction.request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
       let scheme = components.scheme, let host = components.host, let port = components.port {
      _ = "\(scheme)://\(host):\(port)"
      addScripts(to: webView.configuration.userContentController)
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let expected = stage == 0 ? "one" : ""
    let forbidden = "onlyB"
    webView.evaluateJavaScript("[document.documentElement.dataset.seed, localStorage.getItem('\(forbidden)'), document.cookie]") { [weak self] value, error in
      guard let self else { return }
      if let error { self.failures.append("evaluate failed: \(error)") }
      let values = value as? [Any]
      if values?[0] as? String != expected { self.failures.append("document-start restoration was late for \(expected)") }
      if !(values?[1] is NSNull) { self.failures.append("cross-origin localStorage leaked \(forbidden)") }
      if (values?[2] as? String ?? "").contains("secret=") { self.failures.append("HttpOnly cookie was visible to JavaScript") }
      webView.evaluateJavaScript("window.fixtureCapture(); true") { [weak self] _, _ in
        guard let self else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
          guard let self else { return }
          if !cookies.contains(where: { $0.name == "secret" && $0.value == "http-only" && $0.isHTTPOnly }) {
            self.failures.append("HttpOnly cookie was not restored in WKHTTPCookieStore")
          }
          if self.stage == 0 {
            self.stage = 1
            webView.evaluateJavaScript("localStorage.clear(); sessionStorage.clear()") { _, error in
              if let error { print("clear error \(error)"); fflush(stdout) }
              webView.load(URLRequest(url: URL(string: "http://127.0.0.1:18765/?second=1")!))
            }
          } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.verifyCaptureAndCancellation() }
          }
        }
      }
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let payload = message.body as? [String: Any],
          let origin = payload["origin"] as? String,
          origin == "\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host):\(message.frameInfo.securityOrigin.port)",
          let rawValues = payload["values"] as? [String: Any] else { return }
    let values = rawValues.reduce(into: [String: String]()) { $0[$1.key] = "\($1.value)" }
    captured[origin] = values
    if origin == "http://127.0.0.1:18765", values["__proto__"] == "literal" { sawProtoKey = true }
    if !message.frameInfo.isMainFrame, origin == "http://127.0.0.1:18766" {
      if values["onlyA"] != nil { failures.append("main-frame localStorage leaked into iframe origin") }
      if values["frameObserved"] == "two" { sawIframeRestore = true }
      if values["frameWrite"] == "iframe" { sawIframeWrite = true }
    }
    if hydrated.insert(origin).inserted { addScripts(to: webView.configuration.userContentController) }
  }

  private func verifyCaptureAndCancellation() {
    if captured["http://127.0.0.1:18765"]?["pageWrite"] != "18765" { failures.append("first-origin change was not captured") }
    if !sawIframeRestore { failures.append("iframe did not observe restored localStorage at document start") }
    if !sawIframeWrite { failures.append("iframe localStorage change was not captured") }
    if !sawProtoKey { failures.append("__proto__ localStorage key was not restored and captured") }
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "fixture")
    webView.configuration.userContentController.removeAllUserScripts()
    webView = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self else { return }
      if self.failures.isEmpty {
        print("WK_FIXTURE_PASS cookie_http_only local_storage_document_start same_origin_no_rollback iframe_origin_restore iframe_origin_capture proto_key origin_isolation cancel_cleanup")
        fflush(stdout)
        exit(0)
      }
      self.failures.forEach { fputs("WK_FIXTURE_FAIL \($0)\n", stderr) }
      exit(1)
    }
  }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let fixture = Fixture()
fixture.run()
application.run()
