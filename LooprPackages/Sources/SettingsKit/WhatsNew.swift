import DesignSystem
import Foundation
import SwiftUI

/// What changed in the longevity release for someone who used build 21: where each old tab went and what became of
/// their habits (R1-UPG-2). The shell shows it once on the first launch after the update; Settings, About, Versions
/// opens it again.
public enum WhatsNewCopy {
    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        public let symbol: String
        public let title: String
        public let detail: String
    }

    public static let title = "What's new in Loopr"
    public static let intro = "Loopr has five tabs now: Today, Food, Fitness, Protocol and Data. Nothing was deleted."
    public static let items: [Item] = [
        Item(id: "data", symbol: "chart.bar", title: "Health is now Data",
             detail: "Sleep, Heart, Body, Stress and your records open from Data."),
        Item(id: "fitness", symbol: "dumbbell", title: "Train is now Fitness",
             detail: "Workouts and training plans are there, next to fitness tests."),
        Item(id: "protocol", symbol: "checklist", title: "Journal is now Protocol",
             detail: "How you feel and your notes are in Protocol, under Check-in. Patterns are there too."),
        Item(id: "rules", symbol: "checkmark.circle", title: "Habits are now rules",
             detail: "Each habit question became a rule in your protocol. Every answer you gave came with it."),
        Item(id: "today", symbol: "clock", title: "Today ticks your rules",
             detail: "Food, Fitness, your band and Apple Health tick the rules they can check. Tap a rule to tick the rest.")
    ]
    /// What the update added, under the moves: the longevity side, which build 21 did not have (ICP R2-UPG-13).
    public static let addedTitle = "New in this version"
    public static let added: [Item] = [
        Item(id: "food", symbol: "fork.knife", title: "Food",
             detail: "Log meals, drinks and supplements. Food checks your food rules for you, such as when the kitchen closes."),
        Item(id: "labs", symbol: "testtube.2", title: "Blood tests",
             detail: "Scan a lab report or type it in, in Data. Each marker keeps its own history."),
        Item(id: "age", symbol: "ruler", title: "The age ruler",
             detail: "Data puts your real age next to a blood age and a cardio age, once you add a blood test and a fitness test.")
    ]
    public static let action = "Continue"
    /// The second button, which closes the sheet on the Protocol tab.
    public static let openProtocol = "Open Protocol"
    /// The row in Settings, About, Versions that opens the sheet again.
    public static let settingsRow = "What's new in this version"
}

/// One short sheet: a title, a line, the five moves, what is new, then Continue and Open Protocol.
public struct WhatsNewSheet: View {
    private let dismiss: () -> Void
    private let openProtocol: (() -> Void)?

    /// - Parameter openProtocol: closes the sheet on the Protocol tab. Nil leaves the button out, as in Settings.
    public init(openProtocol: (() -> Void)? = nil, dismiss: @escaping () -> Void) {
        self.openProtocol = openProtocol
        self.dismiss = dismiss
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    LooprText(WhatsNewCopy.title, style: .titleLarge)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("whats-new-title")
                    LooprText(WhatsNewCopy.intro, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rows(WhatsNewCopy.items)
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    LooprText(WhatsNewCopy.addedTitle, style: .cardTitle)
                        .accessibilityAddTraits(.isHeader)
                    rows(WhatsNewCopy.added)
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.xl)
            .padding(.bottom, LooprSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: LooprSpacing.xs) {
                Button(action: dismiss) {
                    Text(WhatsNewCopy.action)
                        .frame(maxWidth: .infinity, minHeight: LooprButtonStyle.minimumTargetHeight)
                }
                .buttonStyle(LooprButtonStyle())
                .accessibilityIdentifier("whats-new-continue")
                if let openProtocol {
                    Button(action: openProtocol) {
                        Text(WhatsNewCopy.openProtocol)
                            .frame(maxWidth: .infinity, minHeight: LooprButtonStyle.minimumTargetHeight)
                    }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol))
                    .accessibilityIdentifier("whats-new-open-protocol")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.vertical, LooprSpacing.sm)
            .background(Color.loopr(.background))
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .accessibilityIdentifier("whats-new-sheet")
    }

    private func rows(_ items: [WhatsNewCopy.Item]) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.md) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    Image(systemName: item.symbol)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.brand))
                        .frame(width: LooprSpacing.xxl)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        LooprText(item.title, style: .rowTitle)
                        LooprText(item.detail, style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("whats-new-\(item.id)")
            }
        }
    }
}
