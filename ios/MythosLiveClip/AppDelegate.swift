import Flutter
import StoreKit
import UIKit

/// The App Clip's app delegate. Same Flutter engine, same Dart code as the full
/// app: the Clip and the app are two targets built from one `App.framework`,
/// and the Dart side finds out which one it is running in by asking the
/// `mythoslive/app_clip` channel, which exists only here.
///
/// Two jobs beyond what `Runner/AppDelegate.swift` does:
///  1. Capture the invocation URL (https://chat.deeploveechoes.com/c/odysseus)
///     so Dart can open that character's chat. `ClipSceneDelegate` records it;
///     this class hands it over on request.
///  2. Show the App Store overlay for the full app when Dart asks (SKOverlay
///     with `AppClipConfiguration`, the sanctioned way for a Clip to promote
///     its parent).
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Pre-scene fallback: on a device that routes the activity to the app
  // delegate rather than the scene delegate, still record the URL.
  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    AppClipInvocation.record(userActivity)
    return super.application(
      application, continue: userActivity, restorationHandler: restorationHandler)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppClipBridge")
    else { return }
    let channel = FlutterMethodChannel(
      name: "mythoslive/app_clip", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "invocationUrl":
        // nil when launched from the Clip card without a URL (or from Xcode
        // without _XCAppClipURL). Dart then falls back to the dashboard.
        result(AppClipInvocation.url?.absoluteString)
      case "showAppStoreOverlay":
        self?.showAppStoreOverlay()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func showAppStoreOverlay() {
    guard
      let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })
        ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
    else { return }
    let config = SKOverlay.AppClipConfiguration(position: .bottom)
    SKOverlay(configuration: config).present(in: scene)
  }
}

/// The URL the Clip was invoked with, kept across the scene connect so Dart
/// can read it once the engine is up.
enum AppClipInvocation {
  static private(set) var url: URL?

  static func record(_ activity: NSUserActivity?) {
    guard let activity = activity,
      activity.activityType == NSUserActivityTypeBrowsingWeb,
      let webpageURL = activity.webpageURL
    else { return }
    url = webpageURL
  }
}
