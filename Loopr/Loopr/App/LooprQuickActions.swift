import UIKit

@MainActor
final class LooprQuickActions {
    static let shared = LooprQuickActions()
    static let notification = Notification.Name("com.loopr.quick-action")
    private var pending: ShellDeepLink?
    static var items: [UIApplicationShortcutItem] {
        [UIApplicationShortcutItem(type: "com.loopr.sync", localizedTitle: "Sync Band", localizedSubtitle: nil,
                                   icon: UIApplicationShortcutIcon(systemImageName: "arrow.triangle.2.circlepath")),
         UIApplicationShortcutItem(type: "com.loopr.breathe", localizedTitle: "Start Breathing", localizedSubtitle: nil,
                                   icon: UIApplicationShortcutIcon(systemImageName: "wind"))]
    }
    @discardableResult
    func receive(_ item: UIApplicationShortcutItem) -> Bool {
        switch item.type {
        case "com.loopr.sync": pending = .syncBand
        case "com.loopr.breathe": pending = .breathing(start: true, bandPacing: true)
        default: return false
        }
        NotificationCenter.default.post(name: Self.notification, object: nil)
        return true
    }
    @discardableResult
    func receive(url: URL) -> Bool {
        guard let link = ShellDeepLink(url: url) else { return false }
        pending = link
        NotificationCenter.default.post(name: Self.notification, object: nil)
        return true
    }
    func take() -> ShellDeepLink? { defer { pending = nil }; return pending }
}

/// SwiftUI continues to own the scene's window and content. UIKit forwards
/// home-screen shortcuts through the existing app delegate's scene setup.
final class LooprQuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem { LooprQuickActions.shared.receive(item) }
    }
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(LooprQuickActions.shared.receive(shortcutItem))
    }
}
