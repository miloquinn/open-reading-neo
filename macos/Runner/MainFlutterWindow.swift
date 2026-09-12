import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var appDistributionBridge: AppDistributionBridge?
  private var sourceBrowserSessionBridge: SourceBrowserSessionBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    appDistributionBridge = AppDistributionBridge(
      messenger: flutterViewController.engine.binaryMessenger
    )
    sourceBrowserSessionBridge = SourceBrowserSessionBridge(
      messenger: flutterViewController.engine.binaryMessenger,
      parentWindow: self
    )
    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
