import DesignSystem
import Foundation
import Testing
import UIKit
@testable import Loopr

/// LV-02 step 1: DEC-12.1 tab order and names, the contract's icons and DEC-12.2 accents, and the
/// build 21 saved selections landing on their new tabs.
@MainActor
struct LongevityShellTabsTests {
    @Test func tabsRunTodayFoodFitnessProtocolData() {
        #expect(MainTab.allCases.map(\.title) == ["Today", "Food", "Fitness", "Protocol", "Data"])
    }

    @Test func eachTabKeepsTheRawValueBuild21Saved() {
        // Changing one of these without migrating the stored value would strand a saved selection.
        #expect(MainTab.today.rawValue == "today")
        #expect(MainTab.food.rawValue == "food")
        #expect(MainTab.fitness.rawValue == "train")
        #expect(MainTab.protocol.rawValue == "journal")
        #expect(MainTab.data.rawValue == "health")
        #expect(MainTab.selectionKey == "loopr.shell.selected-tab.v1")
    }

    @Test func tabsUseTheContractIcons() {
        #expect(MainTab.today.symbol == "clock")
        #expect(MainTab.food.symbol == "fork.knife")
        #expect(MainTab.fitness.symbol == "dumbbell")
        #expect(MainTab.protocol.symbol == "ProtocolRosette")
        #expect(MainTab.data.symbol == "chart.bar")
        // Outline symbols, never the filled variants build 21 used.
        for tab in MainTab.allCases { #expect(!tab.symbol.hasSuffix(".fill"), "\(tab.title)") }
    }

    @Test func onlyProtocolDrawsItsIconFromTheAssetCatalog() {
        #expect(MainTab.allCases.filter(\.symbolIsAsset) == [.protocol])
        for tab in MainTab.allCases {
            if tab.symbolIsAsset {
                #expect(UIImage(named: tab.symbol, in: .main, with: nil) != nil, "\(tab.symbol) is missing from the asset catalog")
            } else {
                #expect(UIImage(systemName: tab.symbol) != nil, "\(tab.symbol) is not an SF Symbol")
            }
        }
    }

    @Test func tabsUseTheDEC12Accents() {
        #expect(MainTab.today.accent == .brand)
        #expect(MainTab.food.accent == .energy)
        #expect(MainTab.fitness.accent == .strain)
        #expect(MainTab.protocol.accent == .protocol)
        #expect(MainTab.data.accent == .brand)
    }

    @Test func everyBuild21RawValueRestoresToItsNewTab() {
        let expected: [(raw: String, tab: String, path: [AppHealthRoute])] = [
            ("today", "Today", []),
            ("food", "Food", []),
            ("train", "Fitness", []),
            ("journal", "Protocol", []),
            ("health", "Data", []),
            ("workouts", "Fitness", []),
            ("sleep", "Data", [.sleepHome]),
            ("heart", "Data", [.heartHome]),
            ("body", "Data", [.bodyHome]),
        ]
        for item in expected {
            let state = MainTabLaunchState.restoring(item.raw)
            #expect(state.tab.title == item.tab, "\(item.raw)")
            #expect(state.healthPath == item.path, "\(item.raw)")
        }
    }

    @Test func unknownAndMissingSelectionsOpenOnToday() {
        for raw in [nil, "", "settings", "Journal", "future-tab"] as [String?] {
            #expect(MainTabLaunchState.restoring(raw) == .init(tab: .today), "\(raw ?? "nil")")
        }
    }

    @Test func aSavedSelectionRoundTripsThroughItsKey() {
        for tab in MainTab.allCases {
            #expect(MainTabLaunchState.restoring(tab.rawValue) == .init(tab: tab))
        }
    }

    @Test func askChipsFollowTheRenamedScreens() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func chips(_ screen: String) -> [String] {
            AskPrompts.suggestions(for: AskOrigin(screen: screen, day: "2026-10-12", date: date))
        }
        #expect(chips("Protocol") == chips("Journal"))
        #expect(chips("Protocol").first == "What do my check-ins say about my sleep?")
        #expect(chips("Fitness") == chips("Train"))
        #expect(chips("Fitness").first == "Should I train hard today?")
    }
}
