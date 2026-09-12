import Cocoa
import FlutterMacOS
import WebKit

final class SourceBrowserSessionBridge: NSObject {
  private static let channelName = "com.niki.xxread/source_browser_session"

  private let channel: FlutterMethodChannel
  private weak var parentWindow: NSWindow?
  private var operations: [String: MacSourceBrowserOperation] = [:]
  private var interactiveOperation: MacSourceBrowserOperation?
  private var loginWindowController: NSWindowController?

  init(messenger: FlutterBinaryMessenger, parentWindow: NSWindow?) {
    self.parentWindow = parentWindow
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async { self?.handle(call, result: result) }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open": open(call.arguments, result: result)
    case "load": load(call.arguments, result: result)
    case "cancel":
      guard let requestId = (call.arguments as? [String: Any])?["requestId"] as? String,
            let operation = operations[requestId] else { result(false); return }
      operation.cancel()
      result(true)
    case "clear":
      let sourceId = (call.arguments as? [String: Any])?["sourceId"] as? String
      operations.values.filter { sourceId == nil || $0.sourceId == sourceId }.forEach { $0.cancel() }
      if sourceId == nil || interactiveOperation?.sourceId == sourceId { interactiveOperation?.cancel() }
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ raw: Any?, result: @escaping FlutterResult) {
    guard interactiveOperation == nil else {
      result(FlutterError(code: "busy", message: "Another website login is already open.", details: nil)); return
    }
    guard let arguments = raw as? [String: Any], let request = MacSourceBrowserRequest(arguments: arguments) else {
      result(FlutterError(code: "invalid_args", message: "A source ID and HTTP(S) URL are required.", details: nil)); return
    }
    let operation = MacSourceBrowserOperation(request: request, result: result)
    interactiveOperation = operation
    let controller = MacSourceBrowserViewController(
      operation: operation,
      title: arguments["title"] as? String,
      doneLabel: arguments["doneLabel"] as? String,
      cancelLabel: arguments["cancelLabel"] as? String
    )
    let window = NSWindow(contentViewController: controller)
    window.title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? arguments["title"] as! String : MacSourceBrowserLocalization.websiteLogin
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(width: 960, height: 720))
    window.minSize = NSSize(width: 520, height: 400)
    window.center()
    window.delegate = controller
    let windowController = NSWindowController(window: window)
    loginWindowController = windowController
    let closeWindow = { [weak window] in
      guard let window else { return }
      if let sheetParent = window.sheetParent {
        sheetParent.endSheet(window)
      } else {
        window.close()
      }
    }
    operation.onCancelPresentation = closeWindow
    operation.onFinishedPresentation = closeWindow
    operation.onDisposed = { [weak self, weak operation] in
      guard self?.interactiveOperation === operation else { return }
      self?.interactiveOperation = nil
      self?.loginWindowController = nil
    }
    if let parentWindow {
      parentWindow.beginSheet(window)
    } else {
      windowController.showWindow(nil)
      window.makeKeyAndOrderFront(nil)
    }
    operation.start(interactive: true)
  }

  private func load(_ raw: Any?, result: @escaping FlutterResult) {
    guard let arguments = raw as? [String: Any], let request = MacSourceBrowserRequest(arguments: arguments),
          let requestId = arguments["requestId"] as? String, !requestId.isEmpty else {
      result(FlutterError(code: "invalid_args", message: "A request ID, source ID and HTTP(S) URL are required.", details: nil)); return
    }
    guard operations[requestId] == nil else {
      result(FlutterError(code: "duplicate_request", message: "This browser request is already active.", details: nil)); return
    }
    let operation = MacSourceBrowserOperation(request: request, result: result)
    operations[requestId] = operation
    operation.onDisposed = { [weak self, weak operation] in
      guard self?.operations[requestId] === operation else { return }
      self?.operations.removeValue(forKey: requestId)
    }
    operation.start(interactive: false)
  }
}

private struct MacSourceBrowserRequest {
  let sourceId: String
  let url: URL
  let headers: [String: String]
  let session: MacSourceBrowserSession
  let method: String
  let body: String?
  let webJavaScript: String?
  let html: String?
  let timeout: TimeInterval

  init?(arguments: [String: Any]) {
    guard let sourceId = arguments["sourceId"] as? String, !sourceId.isEmpty,
          let rawURL = arguments["url"] as? String, let url = URL(string: rawURL),
          MacSourceBrowserSession.isWebURL(url) else { return nil }
    self.sourceId = sourceId
    self.url = url
    headers = (arguments["headers"] as? [String: Any] ?? [:]).reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
    session = MacSourceBrowserSession(raw: arguments["session"])
    method = (arguments["method"] as? String ?? "GET").uppercased()
    body = arguments["body"] as? String
    webJavaScript = arguments["webJs"] as? String
    html = arguments["html"] as? String
    let milliseconds = (arguments["timeoutMs"] as? NSNumber)?.doubleValue ?? 15_000
    timeout = min(max(milliseconds / 1000, 2), 30)
  }
}

private final class MacSourceBrowserSession {
  private(set) var localStorage: [String: [String: String]] = [:]
  let cookies: [[String: Any]]

  init(raw: Any?) {
    var map = raw as? [String: Any]
    if let string = raw as? String, let data = string.data(using: .utf8),
       let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { map = decoded }
    cookies = (map?["cookies"] as? [[String: Any]]) ?? []
    if let origins = map?["localStorage"] as? [String: Any] {
      for (origin, rawValues) in origins {
        guard let normalized = Self.normalizedOrigin(origin), let values = rawValues as? [String: Any] else { continue }
        localStorage[normalized] = values.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
      }
    }
  }

  func mergeStorage(origin: String, values: [String: Any]) {
    guard let normalized = Self.normalizedOrigin(origin) else { return }
    localStorage[normalized] = values.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
  }

  var restorableOrigins: [String] { localStorage.keys.sorted() }

  func restoreCookies(into store: WKHTTPCookieStore, completion: @escaping () -> Void) {
    let values = cookies.compactMap(Self.httpCookie)
    guard !values.isEmpty else { completion(); return }
    let group = DispatchGroup()
    values.forEach { cookie in group.enter(); store.setCookie(cookie) { group.leave() } }
    group.notify(queue: .main, execute: completion)
  }

  func platformMap(cookies: [HTTPCookie]) -> [String: Any] {
    ["cookies": cookies.map(Self.cookieMap), "localStorage": localStorage]
  }

  func restorationScript(for origin: String) -> String? {
    guard let values = localStorage[origin] else { return nil }
    let encodedOrigin = Self.jsonFragment(origin)
    let encodedValuesJSON = Self.jsonFragment(Self.jsonObject(values))
    return """
    (function() {
      'use strict';
      try {
        if (window.location.origin === \(encodedOrigin)) {
          var values = JSON.parse(\(encodedValuesJSON));
          Object.keys(values).forEach(function(key) { localStorage.setItem(key, String(values[key])); });
        }
      } catch (_) {}
    })();
    """
  }

  func captureScript() -> String {
    return """
    (function() {
      'use strict';
      function origin() { try { return window.location.origin; } catch (_) { return ''; } }
      function snapshot() {
        var values = Object.create(null);
        try { for (var i = 0; i < localStorage.length; i++) { var key = localStorage.key(i); values[key] = localStorage.getItem(key); } } catch (_) {}
        try { window.webkit.messageHandlers.xxreadSourceStorage.postMessage({origin: origin(), values: values}); } catch (_) {}
      }
      try {
        var setItem = Storage.prototype.setItem, removeItem = Storage.prototype.removeItem, clear = Storage.prototype.clear;
        Storage.prototype.setItem = function(k, v) { setItem.call(this, k, v); if (this === localStorage) snapshot(); };
        Storage.prototype.removeItem = function(k) { removeItem.call(this, k); if (this === localStorage) snapshot(); };
        Storage.prototype.clear = function() { clear.call(this); if (this === localStorage) snapshot(); };
      } catch (_) {}
      window.addEventListener('pagehide', snapshot);
      window.addEventListener('storage', snapshot);
      document.addEventListener('visibilitychange', function() { if (document.visibilityState === 'hidden') snapshot(); });
      window.__xxreadCaptureLocalStorage = snapshot;
      snapshot();
    })();
    """
  }

  static func isWebURL(_ url: URL) -> Bool {
    guard url.user == nil, url.password == nil, let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
    return scheme == "http" || scheme == "https"
  }

  static func normalizedOrigin(_ raw: String) -> String? {
    guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"), let host = components.host, !host.isEmpty else { return nil }
    let port = components.port.flatMap { (scheme == "http" && $0 == 80) || (scheme == "https" && $0 == 443) ? nil : $0 }
    return "\(scheme)://\(host.lowercased())\(port.map { ":\($0)" } ?? "")"
  }

  private static func httpCookie(_ value: [String: Any]) -> HTTPCookie? {
    guard let name = value["name"] as? String, !name.isEmpty, let cookieValue = value["value"] as? String,
          let rawDomain = value["domain"] as? String, !rawDomain.isEmpty else { return nil }
    let hostOnly = value["hostOnly"] as? Bool ?? !rawDomain.hasPrefix(".")
    let domain = hostOnly ? rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) : (rawDomain.hasPrefix(".") ? rawDomain : ".\(rawDomain)")
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: cookieValue, .domain: domain,
      .path: (value["path"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/",
      .secure: (value["secure"] as? Bool ?? false) ? "TRUE" : "FALSE",
    ]
    if value["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    if let milliseconds = value["expiresAt"] as? NSNumber { properties[.expires] = Date(timeIntervalSince1970: milliseconds.doubleValue / 1000) }
    if let sameSite = value["sameSite"] as? String, !sameSite.isEmpty { properties[.sameSitePolicy] = sameSite }
    return HTTPCookie(properties: properties)
  }

  private static func cookieMap(_ cookie: HTTPCookie) -> [String: Any] {
    var result: [String: Any] = [
      "name": cookie.name, "value": cookie.value, "domain": cookie.domain, "path": cookie.path,
      "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly, "hostOnly": !cookie.domain.hasPrefix("."),
      "expiresAt": cookie.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull(),
    ]
    if let sameSite = cookie.sameSitePolicy { result["sameSite"] = sameSite }
    return result
  }

  private static func jsonObject(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string.replacingOccurrences(of: "</", with: "<\\/")
  }

  private static func jsonFragment(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
          let string = String(data: data, encoding: .utf8) else { return "null" }
    return string.replacingOccurrences(of: "</", with: "<\\/")
  }
}

private final class MacSourceBrowserOperation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let sourceId: String
  let webView: WKWebView
  var onDisposed: (() -> Void)?
  var onCancelPresentation: (() -> Void)?
  var onFinishedPresentation: (() -> Void)?

  private let request: MacSourceBrowserRequest
  private let result: FlutterResult
  private var timeoutWorkItem: DispatchWorkItem?
  private var finishWorkItem: DispatchWorkItem?
  private var completed = false
  private var interactive = false
  private var hydratedOrigins = Set<String>()

  init(request: MacSourceBrowserRequest, result: @escaping FlutterResult) {
    self.request = request
    self.result = result
    sourceId = request.sourceId
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    Self.configureScripts(configuration.userContentController, request: request, hydratedOrigins: [])
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    configuration.userContentController.add(self, name: "xxreadSourceStorage")
    webView.navigationDelegate = self
    if let agent = request.headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value { webView.customUserAgent = agent }
  }

  func start(interactive: Bool) {
    self.interactive = interactive
    request.session.restoreCookies(into: webView.configuration.websiteDataStore.httpCookieStore) { [weak self] in self?.beginLoad() }
    if !interactive {
      let item = DispatchWorkItem { [weak self] in self?.fail(code: "timeout", message: "Background browser timed out while loading this source.") }
      timeoutWorkItem = item
      DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: item)
    }
  }

  func finishInteractive() { if interactive { captureAndComplete() } }

  func cancel() {
    guard !completed else { return }
    completed = true
    result(FlutterError(code: "cancelled", message: "Website login was cancelled.", details: nil))
    onCancelPresentation?()
    dispose()
  }

  private func beginLoad() {
    guard !completed else { return }
    if let html = request.html, !html.isEmpty { webView.loadHTMLString(html, baseURL: request.url); return }
    var navigationRequest = URLRequest(url: request.url)
    navigationRequest.httpMethod = request.method
    if let body = request.body, !body.isEmpty { navigationRequest.httpBody = body.data(using: .utf8) }
    request.headers.forEach { name, value in
      if name.caseInsensitiveCompare("User-Agent") != .orderedSame { navigationRequest.setValue(value, forHTTPHeaderField: name) }
    }
    webView.load(navigationRequest)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    finishWorkItem?.cancel(); finishWorkItem = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !interactive, !completed else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.completed else { return }
      if let script = self.request.webJavaScript, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        self.webView.evaluateJavaScript(script) { [weak self] _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.captureAndComplete() } }
      } else { self.captureAndComplete() }
    }
    finishWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(code: "load_failed", message: error.localizedDescription) }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(code: "load_failed", message: error.localizedDescription) }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
    if !MacSourceBrowserSession.isWebURL(url) {
      let internalSchemes = Set(["about", "blob", "data", "javascript"])
      if let scheme = url.scheme?.lowercased(), internalSchemes.contains(scheme) {
        decisionHandler(.allow)
      } else if interactive && navigationAction.targetFrame?.isMainFrame != false {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      } else {
        decisionHandler(.cancel)
      }
      return
    }
    if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
    configureScripts()
    if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel) } else { decisionHandler(.allow) }
  }

  private func configureScripts() {
    Self.configureScripts(webView.configuration.userContentController, request: request, hydratedOrigins: hydratedOrigins)
  }

  private static func configureScripts(
    _ controller: WKUserContentController,
    request: MacSourceBrowserRequest,
    hydratedOrigins: Set<String>
  ) {
    controller.removeAllUserScripts()
    for origin in request.session.restorableOrigins where !hydratedOrigins.contains(origin) {
      if let source = request.session.restorationScript(for: origin) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
      }
    }
    controller.addUserScript(WKUserScript(source: request.session.captureScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "xxreadSourceStorage",
          let payload = message.body as? [String: Any], let claimedOrigin = payload["origin"] as? String,
          let origin = Self.origin(for: message.frameInfo.securityOrigin),
          MacSourceBrowserSession.normalizedOrigin(claimedOrigin) == origin,
          let values = payload["values"] as? [String: Any] else { return }
    request.session.mergeStorage(origin: origin, values: values)
    if hydratedOrigins.insert(origin).inserted { configureScripts() }
  }

  private static func origin(for securityOrigin: WKSecurityOrigin) -> String? {
    let scheme = securityOrigin.protocol.lowercased()
    guard scheme == "http" || scheme == "https", !securityOrigin.host.isEmpty else { return nil }
    let port = securityOrigin.port
    let suffix = port == 0 || (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
      ? "" : ":\(port)"
    return "\(scheme)://\(securityOrigin.host.lowercased())\(suffix)"
  }

  private func captureAndComplete() {
    guard !completed else { return }
    webView.evaluateJavaScript("window.__xxreadCaptureLocalStorage && window.__xxreadCaptureLocalStorage(); document.documentElement ? document.documentElement.outerHTML : (document.body ? document.body.innerHTML : '');") { [weak self] value, error in
      guard let self, !self.completed else { return }
      guard error == nil, let body = value as? String, !body.isEmpty else {
        self.fail(code: "empty_page", message: error?.localizedDescription ?? "The website returned an empty page."); return
      }
      self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        guard let self, !self.completed else { return }
        self.completed = true
        self.result(["body": body, "finalUrl": self.webView.url?.absoluteString ?? self.request.url.absoluteString,
                     "session": self.request.session.platformMap(cookies: cookies)])
        self.onFinishedPresentation?()
        self.dispose()
      }
    }
  }

  private func fail(code: String, message: String) {
    guard !completed else { return }
    completed = true
    result(FlutterError(code: code, message: message, details: nil))
    if interactive { onCancelPresentation?() }
    dispose()
  }

  private func dispose() {
    timeoutWorkItem?.cancel(); finishWorkItem?.cancel(); webView.stopLoading(); webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "xxreadSourceStorage")
    webView.configuration.userContentController.removeAllUserScripts()
    onDisposed?(); onDisposed = nil
  }
}

private final class MacSourceBrowserViewController: NSViewController, NSWindowDelegate {
  private let operation: MacSourceBrowserOperation
  private let pageTitle: String?
  private let doneLabel: String?
  private let cancelLabel: String?
  private let doneButton = NSButton()

  init(operation: MacSourceBrowserOperation, title: String?, doneLabel: String?, cancelLabel: String?) {
    self.operation = operation; pageTitle = title; self.doneLabel = doneLabel; self.cancelLabel = cancelLabel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    let root = NSView()
    let header = NSView()
    let titleLabel = NSTextField(labelWithString: pageTitle ?? MacSourceBrowserLocalization.websiteLogin)
    let cancelButton = NSButton(title: cancelLabel ?? MacSourceBrowserLocalization.cancel, target: self, action: #selector(cancel))
    doneButton.title = doneLabel ?? MacSourceBrowserLocalization.done
    doneButton.target = self
    doneButton.action = #selector(done)
    doneButton.keyEquivalent = "\r"
    [header, titleLabel, cancelButton, doneButton, operation.webView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
    root.addSubview(header); root.addSubview(operation.webView)
    header.addSubview(cancelButton); header.addSubview(titleLabel); header.addSubview(doneButton)
    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 52),
      cancelButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16), cancelButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      doneButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16), doneButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor), titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      operation.webView.topAnchor.constraint(equalTo: header.bottomAnchor), operation.webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      operation.webView.trailingAnchor.constraint(equalTo: root.trailingAnchor), operation.webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    view = root
  }

  @objc private func cancel() { operation.cancel() }
  @objc private func done() { doneButton.isEnabled = false; operation.finishInteractive() }
  func windowWillClose(_ notification: Notification) { operation.cancel() }
}

private enum MacSourceBrowserLocalization {
  private static var language: String { Locale.preferredLanguages.first?.lowercased() ?? "en" }
  static var websiteLogin: String {
    if language.hasPrefix("zh") { return "网站登录" }
    if language.hasPrefix("ja") { return "ウェブサイトにログイン" }
    return "Website Login"
  }
  static var cancel: String {
    if language.hasPrefix("zh") { return "取消" }
    if language.hasPrefix("ja") { return "キャンセル" }
    return "Cancel"
  }
  static var done: String {
    if language.hasPrefix("zh") { return "完成" }
    if language.hasPrefix("ja") { return "完了" }
    return "Done"
  }
}
