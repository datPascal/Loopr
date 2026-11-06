import DesignSystem
import DomainKit
import RoutineKit
import SwiftUI

/// The top found patterns, each with its strength as one to three bars.
struct ProtocolPatternsSection: View {
    let patterns: ProtocolPatternsState
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Patterns", detail: "Your own nights, with and without each habit",
                               actionTitle: patterns.total > 0 ? "All \(patterns.total)" : "Open", accent: .protocol,
                               identifier: "protocol-patterns-header", actionIdentifier: "protocol-patterns-all", action: open)
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    if patterns.lines.isEmpty {
                        LooprText("No patterns yet. Loopr compares your own nights once a habit has enough nights with and without it.",
                                  style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                            .padding(.vertical, LooprSpacing.sm)
                            .accessibilityIdentifier("protocol-patterns-empty")
                    }
                    ForEach(Array(patterns.lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { LooprHairline() }
                        row(line, index: index)
                    }
                }
            }
            if !patterns.lines.isEmpty {
                ProvenanceChip(.onThisPhone, qualifier: "your own nights")
            }
        }
    }

    private func row(_ line: ProtocolPatternLine, index: Int) -> some View {
        Button(action: open) {
            HStack(spacing: LooprSpacing.sm) {
                ProtocolStrengthBars(bars: line.bars)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                    LooprText(line.title, style: .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    if !line.detail.isEmpty {
                        LooprText(line.detail, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.sm)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.bars == 3 ? "Strong" : "Clear") pattern. \(line.text)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("protocol-pattern-\(index)")
    }
}

/// Three rising bars, the contract's `.str`: three lit for Strong, two for Clear.
struct ProtocolStrengthBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.loopr(index < bars ? .protocol : .divider))
                    .frame(width: 6, height: [9, 15, 22][index])
            }
        }
        .frame(width: 26, height: 22, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The weekly review's row on the Check-in segment (LV-09.2). The app passes the words and opens the review as a sheet.
public struct ProtocolWeeklyReviewEntry {
    /// "This week's review".
    public let title: String
    /// "The week of 19 Oct, written on this iPhone".
    public let detail: String
    /// The Monday of the week the review covers. With it the row names the week by its dates, "Last week, 6 to 12 Nov",
    /// and leads the check-in only on Sunday evening and Monday (ICP R1-VET-01, R1-DES-18). Nil keeps `title`.
    public let monday: DayIdentity?
    public let open: @MainActor () -> Void

    public init(title: String, detail: String, monday: DayIdentity? = nil, open: @escaping @MainActor () -> Void) {
        self.title = title
        self.detail = detail
        self.monday = monday
        self.open = open
    }
}

/// The weekly review's row. Prominent, it is a card with the coach's orb at the top of the check-in; otherwise it is a
/// quiet row under the deck. A tap opens the five pages.
struct ProtocolWeeklyReviewRow: View {
    let entry: ProtocolWeeklyReviewEntry
    var title: String?
    var prominent = true

    static let detail = "Five short pages, written on this iPhone"

    var body: some View {
        Group {
            if prominent {
                button.padding(.horizontal, LooprSpacing.cardHorizontal).looprCardBackground(.standard)
            } else {
                button.padding(.horizontal, LooprSpacing.xxs)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prominent ? "\(shownTitle). \(shownDetail)" : shownTitle)
        .accessibilityHint("Opens the weekly review.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("protocol-weekly-review")
    }

    private var shownTitle: String { title ?? entry.title }
    private var shownDetail: String { title == nil ? entry.detail : Self.detail }

    private var button: some View {
        let title = shownTitle
        let detail = shownDetail
        return Button { entry.open() } label: {
            HStack(spacing: LooprSpacing.sm) {
                if prominent {
                    LooprCoachOrb(size: .regular)
                        .frame(width: 28)
                }
                VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                    LooprText(title, style: prominent ? .rowTitle : .label, color: prominent ? .ink : .protocolChip)
                        .fixedSize(horizontal: false, vertical: true)
                    if prominent {
                        LooprText(detail, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
    }
}

/// The store could not be read. The rosette keeps its shape and the card says how it comes back.
struct ProtocolUnavailableCard: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(spacing: LooprSpacing.md) {
                    ProtocolRosetteOutline(size: 56)
                        .opacity(0.5)
                    LooprText(message, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try again", action: retry)
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol))
                    .accessibilityIdentifier("protocol-retry")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-unavailable")
    }
}

/// The tests Patterns runs, under the designed experiments, and the way into Patterns.
struct ProtocolExperimentsList: View {
    let rows: [ProtocolExperimentRow]?
    /// An experiment of the person's own is running above. Then "No test is running" under it reads as a contradiction,
    /// so the empty list says nothing and only offers Patterns (ICP R2-UPG-17).
    var designedIsRunning = false
    let open: () -> Void

    var body: some View {
        // Without Patterns (rows nil) the section is gone. "Patterns is off in this build" was engineering language next
        // to a working Patterns screen (UX R1-DES-28, R1-VET-22, R1-NEW-22).
        if rows != nil { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Pattern tests", detail: "Each one compares nights you kept a habit with nights you did not")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    if let rows {
                        if rows.isEmpty, !designedIsRunning {
                            message("No test is running. Patterns can start one from a pattern it found in your nights.")
                        }
                        ForEach(rows) { row in
                            Button(action: open) {
                                HStack(spacing: LooprSpacing.sm) {
                                    Circle()
                                        .fill(Color.loopr(row.isRunning ? .protocol : .inkMuted))
                                        .frame(width: 8, height: 8)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                                        LooprText(row.title, style: .rowTitle)
                                            .fixedSize(horizontal: false, vertical: true)
                                        LooprText(row.detail, style: .caption, color: .inkSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    LooprChevron()
                                }
                                .padding(.horizontal, LooprSpacing.cardHorizontal)
                                .padding(.vertical, LooprSpacing.xs)
                                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.looprPressableRow)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("protocol-experiment-\(row.id)")
                            LooprHairline()
                        }
                        Button(action: open) {
                            HStack {
                                LooprText("Open Patterns", style: .label, color: .protocolChip)
                                Spacer()
                                LooprChevron()
                            }
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityIdentifier("protocol-experiments-open")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-experiments-list")
        }
    }

    private func message(_ text: String) -> some View {
        LooprText(text, style: .prose, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.xs)
    }
}
