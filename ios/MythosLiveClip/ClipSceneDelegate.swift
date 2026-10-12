import Flutter
import UIKit

/// Flutter's scene delegate, plus one thing: App Clip invocations arrive as an
/// `NSUserActivity` on the scene, not on the app delegate, so this is where
/// the invocation URL can be caught. Everything else is `super`.
///
/// Named in `MythosLiveClip/Info.plist` as `UISceneDelegateClassName`.
@objc(ClipSceneDelegate)
class ClipSceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    AppClipInvocation.record(connectionOptions.userActivities.first)
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    AppClipInvocation.record(userActivity)
    super.scene(scene, continue: userActivity)
  }
}
