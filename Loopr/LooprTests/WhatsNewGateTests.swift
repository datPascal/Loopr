import Foundation
import SettingsKit
import Testing
@testable import Loopr

/// R1-UPG-2 and R1-UPG-3: "What's new" shows once after the update from build 21, never after a fresh install, and
/// the upgrade launch opens on Today.
@MainActor
struct WhatsNewGateTests {
    private func defaults() -> UserDefaults {
        let name = "whats-new-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func anUpgradeShowsTheSheetUntilContinue() {
        let gate = WhatsNewGate(defaults: defaults())
        // Onboarding never ran in this version: the person finished it on build 21.
        #expect(gate.shouldShow(isProduction: true, arguments: []))
        // A launch that ends before Continue shows it again.
        #expect(gate.shouldShow(isProduction: true, arguments: []))
        gate.markSeen(isProduction: true)
        #expect(!gate.shouldShow(isProduction: true, arguments: []))
        #expect(gate.state == .seen)
    }

    @Test func aFreshInstallNeverShowsIt() {
        let gate = WhatsNewGate(defaults: defaults())
        gate.markNotNeeded()
        #expect(!gate.shouldShow(isProduction: true, arguments: []))
        // Onboarding again later, after Delete all data for example, does not undo a seen sheet either.
        gate.markSeen(isProduction: true)
        gate.markNotNeeded()
        #expect(gate.state == .seen)
    }

    @Test func fixtureLaunchesShowItOnlyWhenAskedAndStoreNothing() {
        let gate = WhatsNewGate(defaults: defaults())
        #expect(!gate.shouldShow(isProduction: false, arguments: []))
        #expect(gate.shouldShow(isProduction: false, arguments: [WhatsNewGate.openArgument]))
        gate.markSeen(isProduction: false)
        #expect(gate.state == nil)
    }

    @Test func theUpgradeLaunchOpensOnTodayWhateverBuild21Saved() {
        for raw in ["today", "health", "food", "train", "journal", "sleep", nil] as [String?] {
            #expect(MainTabLaunchState.restoring(raw, afterUpdate: true) == .init(tab: .today), "\(raw ?? "nil")")
        }
        // Later launches restore the saved tab on its new name.
        #expect(MainTabLaunchState.restoring("journal", afterUpdate: false).tab == .protocol)
        #expect(MainTabLaunchState.restoring("health", afterUpdate: false).tab == .data)
        #expect(MainTabLaunchState.restoring("train", afterUpdate: false).tab == .fitness)
    }

    @Test func theSheetNamesWhereEveryOldTabWentAndKeepsTheAnswers() {
        let text = ([WhatsNewCopy.intro] + WhatsNewCopy.items.flatMap { [$0.title, $0.detail] }).joined(separator: " ")
        for moved in ["Health is now Data", "Train is now Fitness", "Journal is now Protocol", "Habits are now rules"] {
            #expect(text.contains(moved), "\(moved)")
        }
        #expect(text.contains("Every answer you gave came with it."))
        #expect(!text.contains("\u{2014}"), "No em dashes")
        #expect(!text.contains("!"))
        #expect(WhatsNewCopy.action == "Continue")
    }

    /// ICP R2-UPG-13: the sheet says where mood and notes went, names what the update added, and opens Protocol.
    @Test func theSheetNamesTheCheckInAndWhatIsNew() {
        let protocolRow = WhatsNewCopy.items.first { $0.id == "protocol" }
        #expect(protocolRow?.detail.contains("How you feel and your notes are in Protocol, under Check-in.") == true)
        #expect(WhatsNewCopy.added.map(\.id) == ["food", "labs", "age"])
        let text = WhatsNewCopy.added.flatMap { [$0.title, $0.detail] }.joined(separator: " ")
        #expect(!text.contains("\u{2014}") && !text.contains("!"))
        #expect(WhatsNewCopy.openProtocol == "Open Protocol")
    }
}
