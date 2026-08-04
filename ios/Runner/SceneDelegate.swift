import Flutter
import UIKit

@objc(SceneDelegate)
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    let urls = connectionOptions.urlContexts.map(\.url)
    AuthCallbackBridge.shared.accept(urls: urls)
    IncomingBookInbox.shared.accept(
      urls: urls.filter { !AuthCallbackBridge.isCallback($0) },
      action: "open"
    )
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    let urls = URLContexts.map(\.url)
    AuthCallbackBridge.shared.accept(urls: urls)
    IncomingBookInbox.shared.accept(urls: urls.filter { !AuthCallbackBridge.isCallback($0) }, action: "open")
    super.scene(scene, openURLContexts: URLContexts)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    IncomingBookInbox.shared.consumeSharedExtensionInboxIfConfigured()
  }
}
