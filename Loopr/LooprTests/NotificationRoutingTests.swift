import NotificationKit
import SettingsKit
import XCTest
@testable import Loopr

final class NotificationRoutingTests: XCTestCase {
    func testEveryNotificationFamilyUsesTheExistingTypedShellRoute() {
        let expected: [(NotificationDeepLink, ShellDeepLink)] = [
            (.today("day"), .todayDetail),
            (.heart("sample"), .heartDetail),
            (.goals("goal"), .goals),
            (.workout("00000000-0000-0000-0000-000000000701"), .workout(UUID(uuidString: "00000000-0000-0000-0000-000000000701"))),
            (.journal("2026-08-29"), .habitCheckIn("2026-08-29")),
            (.coach("briefing"), .coach),
            (.sleep("day"), .sleepDetail),
            (.hydration("day"), .todayDetail),
            (.device("strap"), .settings(.deviceCenter)),
            (.stress("session"), .stress),
            (.cycle("day"), .settings(.cycle))
        ]
        for (input, route) in expected {
            XCTAssertEqual(ShellDeepLink(notification: input), route)
        }
    }
}
