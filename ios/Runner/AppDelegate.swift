import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let vpn = NativeVPNController()
  private let haptics = NativeHaptics()
  private var launchChannel: FlutterMethodChannel?
  private var deviceChannel: FlutterMethodChannel?
  private var pendingLaunchURI: String?
  private var launchListenerReady = false

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let url = launchOptions?[.url] as? URL, accepts(url) {
      pendingLaunchURI = url.absoluteString
    }
    if let controller = window?.rootViewController as? FlutterViewController {
      vpn.register(with: controller.binaryMessenger)
      haptics.register(with: controller.binaryMessenger)
      registerDeviceInfo(controller.binaryMessenger)
      // Preserve the existing Android-named Dart contract on both platforms.
      let channel = FlutterMethodChannel(name: "neuravpn/android_launch",
                                         binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else { result(nil); return }
        guard call.method == "getInitialLaunchUri" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.launchListenerReady = true
        result(self.pendingLaunchURI)
        self.pendingLaunchURI = nil
      }
      launchChannel = channel
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ app: UIApplication, open url: URL,
                            options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    guard accepts(url) else { return super.application(app, open: url, options: options) }
    deliver(url)
    return true
  }

  override func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL, accepts(url) {
      deliver(url)
      return true
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }

  private func deliver(_ url: URL) {
    if launchListenerReady {
      launchChannel?.invokeMethod("handleLaunchUri", arguments: url.absoluteString)
    } else { pendingLaunchURI = url.absoluteString }
  }

  private func accepts(_ url: URL) -> Bool {
    let scheme = url.scheme?.lowercased() ?? ""
    if ["neuravpn", "vless", "hysteria2", "hy2"].contains(scheme) { return true }
    guard scheme == "https" || scheme == "http" else { return false }
    return (url.host?.lowercased() == "asort97.github.io" && url.path.hasPrefix("/neuravpn-site")) ||
      (url.host?.lowercased() == "webhook.staticdeliverycdn.com" && url.path.hasPrefix("/merged-sub/"))
  }

  private func registerDeviceInfo(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "neuravpn/device_info", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "getDeviceInfo" else { result(FlutterMethodNotImplemented); return }
      do {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory,
          in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("NoBackup")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        result(["os": "iOS", "model": UIDevice.current.model, "noBackupDirectory": directory.path])
      } catch {
        result(FlutterError(code: "DEVICE_INFO_FAILED", message: "Could not create app storage.", details: nil))
      }
    }
    deviceChannel = channel
  }
}
