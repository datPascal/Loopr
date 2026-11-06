import DesignSystem
import DomainKit
import SwiftUI

private struct JournalInsightSelection: Identifiable, Hashable {
    let id: HabitID
    let target: JournalInsightTarget
}

public struct JournalInsightsSection: View {
    @Environment(\.looprAsk) private var ask
    @ObservedObject private var model: HabitViewModel
    private let day: DayIdentity
    @State private var target: JournalInsightTarget = .recovery
    @State private var choosingTarget = false
    @State private var selection: JournalInsightSelection?

    public init(model: HabitViewModel, day: DayIdentity) { self.model = model; self.day = day }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("What moves your \(target.rawValue.lowercased())",
                    detail: Self.needsText, actionTitle: target.rawValue,
                    identifier: "journal-insight-target") { choosingTarget = true }
                if model.isRefreshingInsights && !rows.isEmpty && rows.allSatisfy({ $0.sample == nil }) {
                    // Only the first comparison ever waits here; after that the stored ones show at once while they
                    // update in the background (ICP R3-HAB-04, R3-VET-07).
                    LooprCard {
                        HStack(alignment: .top, spacing: LooprSpacing.sm) {
                            ProgressView()
                                .tint(Color.loopr(.cyclePlum))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                                LooprText(Self.comparingTitle(days: model.comparedDays(endingOn: day)), style: .rowTitle)
                                    .fixedSize(horizontal: false, vertical: true)
                                LooprText(Self.comparingText, style: .prose, color: .inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("journal-insights-comparing")
                    }
                } else if rows.isEmpty {
                    LooprCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StateMessage(.noRecords, compact: true)
                            LooprText("Answer your check-in questions to build a comparison.", style: .prose, color: .inkSecondary)
                        }
                    }
                } else {
                    let scale = rows.compactMap(\.difference).map(abs).max() ?? 1
                    LooprCard {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                LooprAssociationRow(title: row.definition.checkInTitle,
                                    detail: index == 0 && row.status != .collecting ? row.detail : row.summary,
                                    evidence: row.status == .collecting ? nil : row.evidence,
                                    share: row.difference.map { scale > 0 ? $0 / scale : 0 },
                                    accent: .cyclePlum, identifier: "journal-insight-\(row.id.rawValue.uuidString)",
                                    titleColor: row.status == .collecting ? .inkSecondary : .ink) {
                                        selection = .init(id: row.id, target: target)
                                    }
                                if index < rows.count - 1 { LooprHairline() }
                            }
                        }
                    }
                }
                LooprText("These are links in your own data, not proof of cause.", style: .prose, color: .inkSecondary)
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Mood", detail: "Last 12 weeks")
                LooprCard {
                    LooprRatingCalendar(model: calendarModel, title: "Mood", accent: .cyclePlum,
                        identifier: "journal-mood-calendar")
                }
            }
            if let error = model.errorMessage {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        StateMessage(.recoverableError, compact: true)
                        LooprText(error, style: .prose, color: .inkSecondary)
                    }
                }
            }
            if let ask {
                Button { ask.run("Journal insights · \(target.rawValue)") } label: {
                    Label("What should I change first?", systemImage: "sparkles")
                }
                .buttonStyle(LooprButtonStyle(prominent: false))
                .accessibilityIdentifier("journal-insights-ask")
            }
            Color.clear.frame(height: LooprSpacing.hairline)
                .accessibilityIdentifier("journal-insights-end")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal-insights-section")
        .task { await model.refreshInsights() }
        .sheet(isPresented: $choosingTarget) { targetPicker }
        .navigationDestination(item: $selection) { selection in
            HabitDetailScreen(viewModel: model, habitID: selection.id, target: selection.target)
                .looprAskToolbar(origin: "Journal comparison · \(selection.target.rawValue)")
        }
    }

    /// "Needs 10 days with and 10 without": the same minimum the check-in's pattern line and Patterns use
    /// (`PatternPolicy.matureGate`, ICP R3-VET-07).
    static var needsText: String {
        let gate = PatternPolicy.default.matureGate
        return "Needs \(gate) days with and \(gate) without"
    }

    /// "Comparing 87 days", while the first comparison ever runs.
    static func comparingTitle(days: Int) -> String {
        days > 0 ? "Comparing \(days) \(days == 1 ? "day" : "days")" : "Comparing your days"
    }

    static let comparingText = "Loopr compares the days you answered Yes with the days you answered No. The first time takes a few seconds."

    private var rows: [JournalInsightRow] {
        model.activeDefinitions.map { definition in
            let estimate = model.estimate(for: definition.id)
            return JournalInsightRow(definition: definition, target: target,
                estimate: estimate.flatMap { $0.windowEnd.habitKey <= day.habitKey ? $0 : nil })
        }
    }

    private var calendarModel: LooprRatingCalendarModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: model.checkInTimeZone(for: day)) ?? TimeZone(secondsFromGMT: 0)!
        func date(_ day: DayIdentity) -> Date? {
            calendar.date(from: DateComponents(era: day.era, year: day.year, month: day.month, day: day.day))
        }
        let values = Dictionary(uniqueKeysWithValues: model.records.compactMap { record -> (Date, Int)? in
            guard let value = record.wellbeing?.mood, let date = date(record.behaviorDay) else { return nil }
            return (date, value.rawValue)
        })
        return .init(values: values, endingOn: date(day) ?? Date(timeIntervalSince1970: 0), calendar: calendar)
    }

    private var targetPicker: some View {
        NavigationStack {
            LooprDetailScaffold {
                LooprCard {
                    VStack(spacing: LooprSpacing.none) {
                        ForEach(Array(JournalInsightTarget.allCases.enumerated()), id: \.element) { index, option in
                            Button {
                                target = option
                                choosingTarget = false
                            } label: {
                                HStack(spacing: LooprSpacing.sm) {
                                    LooprText(option.rawValue, style: .rowTitle)
                                    Spacer(minLength: LooprSpacing.xs)
                                    if target == option {
                                        Image(systemName: "checkmark")
                                            .looprTypography(.label)
                                            .foregroundStyle(Color.loopr(.cyclePlumChip))
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.looprPressableRow)
                            .accessibilityAddTraits(target == option ? .isSelected : [])
                            .accessibilityIdentifier("journal-target-\(option.metric.rawValue)")
                            if index < JournalInsightTarget.allCases.count - 1 { LooprHairline() }
                        }
                    }
                }
            }
            .navigationTitle("Comparison target")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
