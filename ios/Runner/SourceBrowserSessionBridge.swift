import Flutter
import UIKit
import WebKit

final class SourceBrowserSessionBridge: NSObject {
  private static let channelName = "com.niki.xxread/source_browser_session"

  private let channel: FlutterMethodChannel
  private weak var presenter: UIViewController?
  private var operations: [String: AppleSourceBrowserOperation] = [:]
  private var interactiveOperation: AppleSourceBrowserOperation?

  init(messenger: FlutterBinaryMessenger, presenter: UIViewController?) {
    self.presenter = presenter
    channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async { self?.handle(call, result: result) }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "open":
      open(call.arguments, result: result)
    case "load":
      load(call.arguments, result: result)
    case "cancel":
      guard let requestId = Self.arguments(call.arguments)?["requestId"] as? String,
            let operation = operations[requestId] else {
        result(false)
        return
      }
      operation.cancel()
      result(true)
    case "clear":
      let sourceId = Self.arguments(call.arguments)?["sourceId"] as? String
      operations.values.filter { sourceId == nil || $0.sourceId == sourceId }.forEach { $0.cancel() }
      if sourceId == nil || interactiveOperation?.sourceId == sourceId {
        interactiveOperation?.cancel()
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func open(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard interactiveOperation == nil else {
      result(FlutterError(code: "busy", message: "Another website login is already open.", details: nil))
      return
    }
    guard let arguments = Self.arguments(rawArguments),
          let request = AppleSourceBrowserRequest(arguments: arguments) else {
      result(FlutterError(code: "invalid_args", message: "A source ID and HTTP(S) URL are required.", details: nil))
      return
    }
    guard let presentingController = topViewController(from: presenter ?? activeRootViewController()) else {
      result(FlutterError(code: "unavailable", message: "No active view controller can present website login.", details: nil))
      return
    }

    let operation = AppleSourceBrowserOperation(request: request, result: result)
    interactiveOperation = operation
    operation.onDisposed = { [weak self, weak operation] in
      guard self?.interactiveOperation === operation else { return }
      self?.interactiveOperation = nil
    }
    let controller = IOSSourceBrowserViewController(
      operation: operation,
      title: arguments["title"] as? String,
      doneLabel: arguments["doneLabel"] as? String,
      cancelLabel: arguments["cancelLabel"] as? String
    )
    operation.onCancelPresentation = { [weak controller] in
      controller?.dismiss(animated: true)
    }
    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .fullScreen
    presentingController.present(navigationController, animated: true) {
      operation.start(interactive: true)
    }
  }

  private func load(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard let arguments = Self.arguments(rawArguments),
          let request = AppleSourceBrowserRequest(arguments: arguments),
          let requestId = arguments["requestId"] as? String,
          !requestId.isEmpty else {
      result(FlutterError(code: "invalid_args", message: "A request ID, source ID and HTTP(S) URL are required.", details: nil))
      return
    }
    guard operations[requestId] == nil else {
      result(FlutterError(code: "duplicate_request", message: "This browser request is already active.", details: nil))
      return
    }
    let operation = AppleSourceBrowserOperation(request: request, result: result)
    operations[requestId] = operation
    operation.onDisposed = { [weak self, weak operation] in
      guard self?.operations[requestId] === operation else { return }
      self?.operations.removeValue(forKey: requestId)
    }
    operation.start(interactive: false)
  }

  private static func arguments(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    guard let controller else { return nil }
    if let presented = controller.presentedViewController { return topViewController(from: presented) }
    if let navigation = controller as? UINavigationController { return topViewController(from: navigation.visibleViewController) }
    if let tabs = controller as? UITabBarController { return topViewController(from: tabs.selectedViewController) }
    return controller
  }

  private func activeRootViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let foregroundScene = scenes.first(where: { $0.activationState == .foregroundActive })
    let orderedScenes = [foregroundScene].compactMap { $0 } + scenes.filter { $0 !== foregroundScene }
    for scene in orderedScenes {
      if let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first(where: { !$0.isHidden }) {
        return window.rootViewController
      }
    }
    return nil
  }
}

private struct AppleSourceBrowserRequest {
  let sourceId: String
  let url: URL
  let headers: [String: String]
  let session: AppleSourceBrowserSession
  let method: String
  let body: String?
  let webJavaScript: String?
  let html: String?
  let timeout: TimeInterval

  init?(arguments: [String: Any]) {
    guard let sourceId = arguments["sourceId"] as? String, !sourceId.isEmpty,
          let rawURL = arguments["url"] as? String,
          let url = URL(string: rawURL), AppleSourceBrowserSession.isWebURL(url) else { return nil }
    self.sourceId = sourceId
    self.url = url
    headers = (arguments["headers"] as? [String: Any] ?? [:]).reduce(into: [:]) { result, item in
      result[item.key] = String(describing: item.value)
    }
    session = AppleSourceBrowserSession(raw: arguments["session"])
    method = (arguments["method"] as? String ?? "GET").uppercased()
    body = arguments["body"] as? String
    webJavaScript = arguments["webJs"] as? String
    html = arguments["html"] as? String
    let milliseconds = (arguments["timeoutMs"] as? NSNumber)?.doubleValue ?? 15_000
    timeout = min(max(milliseconds / 1000, 2), 30)
  }
}

private final class AppleSourceBrowserSession {
  private(set) var localStorage: [String: [String: String]] = [:]
  let cookies: [[String: Any]]

  init(raw: Any?) {
    var map = raw as? [String: Any]
    if let string = raw as? String,
       let data = string.data(using: .utf8),
       let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      map = decoded
    }
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
    values.forEach { cookie in
      group.enter()
      store.setCookie(cookie) { group.leave() }
    }
    group.notify(queue: .main, execute: completion)
  }

  func platformMap(cookies: [HTTPCookie]) -> [String: Any] {
    [
      "cookies": cookies.map(Self.cookieMap),
      "localStorage": localStorage,
    ]
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
        var setItem = Storage.prototype.setItem;
        var removeItem = Storage.prototype.removeItem;
        var clear = Storage.prototype.clear;
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
    guard let components = URLComponents(string: raw),
          let scheme = components.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          let host = components.host, !host.isEmpty else { return nil }
    let port = components.port.flatMap { (scheme == "http" && $0 == 80) || (scheme == "https" && $0 == 443) ? nil : $0 }
    return "\(scheme)://\(host.lowercased())\(port.map { ":\($0)" } ?? "")"
  }

  private static func httpCookie(_ value: [String: Any]) -> HTTPCookie? {
    guard let name = value["name"] as? String, !name.isEmpty,
          let cookieValue = value["value"] as? String,
          let rawDomain = value["domain"] as? String, !rawDomain.isEmpty else { return nil }
    let hostOnly = value["hostOnly"] as? Bool ?? !rawDomain.hasPrefix(".")
    let domain = hostOnly ? rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) : (rawDomain.hasPrefix(".") ? rawDomain : ".\(rawDomain)")
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: cookieValue,
      .domain: domain,
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
      "name": cookie.name,
      "value": cookie.value,
      "domain": cookie.domain,
      "path": cookie.path,
      "secure": cookie.isSecure,
      "httpOnly": cookie.isHTTPOnly,
      "hostOnly": !cookie.domain.hasPrefix("."),
      "expiresAt": cookie.expiresDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull(),
    ]
    if let sameSite = cookie.sameSitePolicy { result["sameSite"] = sameSite }
    return result
  }

  private static func jsonObject(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let string = String(data: data, encoding: .utf8) else { return "{}" }
    return string.replacingOccurrences(of: "</", with: "<\\/")
  }

  private static func jsonFragment(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
          let string = String(data: data, encoding: .utf8) else { return "null" }
    return string.replacingOccurrences(of: "</", with: "<\\/")
  }
}

private final class AppleSourceBrowserOperation: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  let sourceId: String
  let webView: WKWebView
  var onDisposed: (() -> Void)?
  var onCancelPresentation: (() -> Void)?

  private let request: AppleSourceBrowserRequest
  private let result: FlutterResult
  private var timeoutWorkItem: DispatchWorkItem?
  private var finishWorkItem: DispatchWorkItem?
  private var completed = false
  private var interactive = false
  private var hydratedOrigins = Set<String>()

  init(request: AppleSourceBrowserRequest, result: @escaping FlutterResult) {
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
    if let agent = request.headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
      webView.customUserAgent = agent
    }
  }

  func start(interactive: Bool) {
    self.interactive = interactive
    request.session.restoreCookies(into: webView.configuration.websiteDataStore.httpCookieStore) { [weak self] in
      self?.beginLoad()
    }
    if !interactive {
      let item = DispatchWorkItem { [weak self] in self?.fail(code: "timeout", message: "Background browser timed out while loading this source.") }
      timeoutWorkItem = item
      DispatchQueue.main.asyncAfter(deadline: .now() + request.timeout, execute: item)
    }
  }

  func finishInteractive() {
    guard interactive else { return }
    captureAndComplete()
  }

  func cancel() {
    guard !completed else { return }
    completed = true
    result(FlutterError(code: "cancelled", message: "Website login was cancelled.", details: nil))
    onCancelPresentation?()
    dispose()
  }

  private func beginLoad() {
    guard !completed else { return }
    if let html = request.html, !html.isEmpty {
      webView.loadHTMLString(html, baseURL: request.url)
      return
    }
    var navigationRequest = URLRequest(url: request.url)
    navigationRequest.httpMethod = request.method
    if let body = request.body, !body.isEmpty { navigationRequest.httpBody = body.data(using: .utf8) }
    request.headers.forEach { name, value in
      guard name.caseInsensitiveCompare("User-Agent") != .orderedSame else { return }
      navigationRequest.setValue(value, forHTTPHeaderField: name)
    }
    webView.load(navigationRequest)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    finishWorkItem?.cancel()
    finishWorkItem = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !interactive, !completed else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self, !self.completed else { return }
      if let script = self.request.webJavaScript, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        self.webView.evaluateJavaScript(script) { [weak self] _, _ in
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.captureAndComplete() }
        }
      } else {
        self.captureAndComplete()
      }
    }
    finishWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    fail(code: "load_failed", message: error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(code: "load_failed", message: error.localizedDescription)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if !AppleSourceBrowserSession.isWebURL(url) {
      let internalSchemes = Set(["about", "blob", "data", "javascript"])
      if let scheme = url.scheme?.lowercased(), internalSchemes.contains(scheme) {
        decisionHandler(.allow)
      } else if interactive && navigationAction.targetFrame?.isMainFrame != false {
        UIApplication.shared.open(url, options: [:])
        decisionHandler(.cancel)
      } else {
        decisionHandler(.cancel)
      }
      return
    }
    if navigationAction.targetFrame?.isMainFrame == false {
      decisionHandler(.allow)
      return
    }
    configureScripts()
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
      decisionHandler(.cancel)
    } else {
      decisionHandler(.allow)
    }
  }

  private func configureScripts() {
    Self.configureScripts(
      webView.configuration.userContentController,
      request: request,
      hydratedOrigins: hydratedOrigins
    )
  }

  private static func configureScripts(
    _ controller: WKUserContentController,
    request: AppleSourceBrowserRequest,
    hydratedOrigins: Set<String>
  ) {
    controller.removeAllUserScripts()
    for origin in request.session.restorableOrigins where !hydratedOrigins.contains(origin) {
      if let source = request.session.restorationScript(for: origin) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
      }
    }
    controller.addUserScript(WKUserScript(
      source: request.session.captureScript(),
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false
    ))
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.name == "xxreadSourceStorage",
          let payload = message.body as? [String: Any],
          let claimedOrigin = payload["origin"] as? String,
          let origin = Self.origin(for: message.frameInfo.securityOrigin),
          AppleSourceBrowserSession.normalizedOrigin(claimedOrigin) == origin,
          let values = payload["values"] as? [String: Any] else { return }
    request.session.mergeStorage(origin: origin, values: values)
    if hydratedOrigins.insert(origin).inserted {
      configureScripts()
    }
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
        self.fail(code: "empty_page", message: error?.localizedDescription ?? "The website returned an empty page.")
        return
      }
      self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        guard let self, !self.completed else { return }
        self.completed = true
        self.result([
          "body": body,
          "finalUrl": self.webView.url?.absoluteString ?? self.request.url.absoluteString,
          "session": self.request.session.platformMap(cookies: cookies),
        ])
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
    timeoutWorkItem?.cancel()
    finishWorkItem?.cancel()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "xxreadSourceStorage")
    webView.configuration.userContentController.removeAllUserScripts()
    onDisposed?()
    onDisposed = nil
  }
}

private final class IOSSourceBrowserViewController: UIViewController {
  private let operation: AppleSourceBrowserOperation
  private let pageTitle: String?
  private let doneLabel: String?
  private let cancelLabel: String?

  init(operation: AppleSourceBrowserOperation, title: String?, doneLabel: String?, cancelLabel: String?) {
    self.operation = operation
    pageTitle = title
    self.doneLabel = doneLabel
    self.cancelLabel = cancelLabel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    view = operation.webView
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = pageTitle ?? "Website Login"
    navigationItem.leftBarButtonItem = cancelLabel.map {
      UIBarButtonItem(title: $0, style: .plain, target: self, action: #selector(cancel))
    } ?? UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
    navigationItem.rightBarButtonItem = doneLabel.map {
      UIBarButtonItem(title: $0, style: .done, target: self, action: #selector(done))
    } ?? UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
  }

  @objc private func cancel() { operation.cancel() }

  @objc private func done() {
    navigationItem.rightBarButtonItem?.isEnabled = false
    operation.finishInteractive()
    dismiss(animated: true)
  }
}
