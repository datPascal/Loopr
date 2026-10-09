import Foundation
import NotificationKit

/// Holds the deep link of a notification tap until the shell can apply it.
///
/// When a tap cold-launches Loopr the delegate answers before `MainTabShell`
/// exists, and a `NotificationCenter` post with nobody listening is lost. The
/// shell takes the parked link when it appears.
@MainActor
final class LooprNotificationLaunchRoute {
    static let shared = LooprNotificationLaunchRoute()

    private var parked: NotificationDeepLink?
    /// The heart alert the Heart alerts screen should open, if any.
    private(set) var requestedHeartAlertID: String?

    func park(_ link: NotificationDeepLink) {
        parked = link
        if case .heartAlert(let id) = link { requestedHeartAlertID = id }
    }

    func take() -> NotificationDeepLink? {
        defer { parked = nil }
        return parked
    }

    /// The Heart alerts screen reads this once, then it is gone.
    func takeRequestedHeartAlert() -> String? {
        defer { requestedHeartAlertID = nil }
        return requestedHeartAlertID
    }
}
