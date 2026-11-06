import DesignSystem
import DomainKit
import RoutineKit
import SwiftUI

/// The entrance keys for the experiment strips. They are separate from the tab's own "protocol" entrance, so the
/// rosettes and the strip each play once a day.
enum ProtocolExperimentEntrance {
    static let card = "protocol-experiments"
    static let result = "protocol-experiment-result"
}

// MARK: - Segment

/// The Experiments segment. It opens with one sentence on what an experiment is, then what is running, the finished
/// ones and the ways to start one. An experiment started from a pattern sits in the same running and finished lists,
/// so there is one list and one rule: one experiment at a time (ICP R1-DES-10, R1-NEW-13). A person with no protocol
/// sees one line and one button (ICP R1-DES-19, R1-SEN-23).
struct ProtocolExperimentsSegment: View {
    let content: ProtocolTabContent?
    let open: (ExperimentID) -> Void
    let openPatterns: () -> Void
    var openGitHub: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            if content == nil {
                LooprSkeleton(height: 220)
                    .accessibilityLabel("Loading your experiments")
                    .accessibilityIdentifier("protocol-experiments-loading")
            } else if isEmpty {
                ProtocolExperimentEmptyCard(find: openPatterns)
            } else {
                LooprText(ProtocolExperimentText.intro, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("protocol-experiments-intro")
                running
                if !finished.isEmpty || !finishedPatternTests.isEmpty {
                    ProtocolExperimentFinishedList(items: finished, patternTests: finishedPatternTests, open: open,
                                                   openPatterns: openPatterns)
                }
                ProtocolExperimentStartSection(pattern: content?.patterns.lines.first, openPatterns: openPatterns,
                                               openGitHub: openGitHub)
            }
        }
    }

    /// Experiments started from a pattern. A person with no protocol has none on this tab: they live in Patterns
    /// (ICP R1-SEN-23).
    private var patternTests: [ProtocolExperimentRow] {
        if case .noProtocol? = content?.routine { return [] }
        return content?.experiments ?? []
    }

    private var finishedPatternTests: [ProtocolExperimentRow] { patternTests.filter { !$0.isRunning } }

    private var data: ProtocolExperimentsData? { content?.experimentData }
    private var finished: [ProtocolExperimentItem] { data?.finished ?? [] }

    private var isEmpty: Bool {
        if case .unavailable? = content?.designedExperiments { return false }
        if case .noProtocol? = content?.routine { return true }
        return (data?.isEmpty ?? true) && patternTests.isEmpty
    }

    @ViewBuilder
    private var running: some View {
        if case .unavailable(let message)? = content?.designedExperiments {
            LooprInlineMessage(message, tone: .warning)
                .accessibilityIdentifier("protocol-experiments-unavailable")
        }
        let tests = patternTests.filter(\.isRunning)
        if let item = data?.running {
            ProtocolExperimentRunningCard(item: item)
        }
        ForEach(tests) { row in
            ProtocolPatternTestCard(row: row, open: openPatterns)
        }
        if data?.running == nil, tests.isEmpty {
            LooprText(ProtocolExperimentText.noneRunning, style: .prose, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("protocol-experiment-none-running")
        }
    }
}

/// Nothing to show yet: what an experiment is, in one line, and one way to find something to test.
struct ProtocolExperimentEmptyCard: View {
    let find: () -> Void

    var body: some View {
        LooprCard(style: .hero(.protocol)) {
            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                LooprText(ProtocolExperimentText.intro, style: .prose, color: .ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button(ProtocolExperimentText.findSomething, action: find)
                    .buttonStyle(LooprButtonStyle(accent: .protocol))
                    .accessibilityHint("Opens Patterns, the habits Loopr found linked to your sleep.")
                    .accessibilityIdentifier("protocol-experiment-find")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-experiment-empty")
    }
}

// MARK: - Running card

/// The running experiment: its name, the verdict in plain words, what the strip measures, the strip, who started it
/// and when. The statistics sit behind "How this works" (ICP R1-NEW-12, R1-SEN-19, R1-DES-19 card).
struct ProtocolExperimentRunningCard: View {
    let item: ProtocolExperimentItem
    @State private var revealed: Int?

    var body: some View {
        let presentation = ProtocolExperimentPresentation.make(item)
        let strip = ProtocolExperimentStrip.make(item, showsRange: false)
        LooprCard(style: .hero(.protocol)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(presentation.title, style: .title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("protocol-experiment-title")
                    // Names the rule, so "Magnesium glycinate, 300 mg" reads as a test of "Magnesium, 300 mg" (ICP R2-VET-08).
                    if let testsRule = presentation.testsRule {
                        LooprText(testsRule, style: .label, color: .protocolChip)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("protocol-experiment-tests-rule")
                    }
                }
                Text(verbatim: presentation.verdict)
                    .looprTypography(.prose)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.loopr(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(LooprSignedNumber.spoken(text: presentation.verdict))
                    .accessibilityIdentifier("protocol-experiment-call")
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(presentation.measuresLine, style: .label, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("protocol-experiment-measures")
                    ProtocolExperimentStripView(strip: strip, entranceKey: ProtocolExperimentEntrance.card, revealed: $revealed)
                        .accessibilityIdentifier("protocol-experiment-strip")
                }
                LooprText(presentation.startedLine, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("protocol-experiment-started")
                ProvenanceChip(.onThisPhone, qualifier: "your own nights", identifier: "protocol-experiment-source")
                ProtocolExperimentHowItWorks(lines: presentation.howItWorks, identifier: "protocol-experiment-how")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-experiment-running")
    }
}

/// An experiment started from a pattern, while it runs. Patterns holds its day-by-day ticks, so the card opens it.
struct ProtocolPatternTestCard: View {
    let row: ProtocolExperimentRow
    let open: () -> Void

    var body: some View {
        LooprCard(style: .hero(.protocol)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText(ProtocolExperimentText.patternTestHeader, style: .label, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LooprText(row.title, style: .title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                LooprText(row.detail, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if ProtocolExperimentText.mentionsHRV(row.title + " " + row.detail) {
                    LooprText(ProtocolExperimentText.hrvGloss, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(ProtocolExperimentText.openInPatterns, action: open)
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol))
                    .accessibilityHint("Opens Patterns, where you mark each day you kept it.")
                    .accessibilityIdentifier("protocol-experiment-\(row.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-pattern-test-running")
    }
}

/// "How this works": the statistical detail, closed until the person asks for it.
struct ProtocolExperimentHowItWorks: View {
    let lines: [String]
    let identifier: String
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Button {
                withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) { isOpen.toggle() }
            } label: {
                HStack(spacing: LooprSpacing.xs) {
                    LooprText(ProtocolExperimentText.howItWorks, style: .label, color: .protocolChip)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: LooprSpacing.xs)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.loopr(.protocolChip))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isOpen ? "Open" : "Closed")
            .accessibilityIdentifier(identifier)
            if isOpen {
                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        LooprText(line, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(LooprSignedNumber.spoken(text: line))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier + "-detail")
                .transition(.opacity)
            }
        }
    }
}

/// The call with its bold lead, and the nights each side still needs.
struct ProtocolExperimentCallText: View {
    let call: ProtocolExperimentCall

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
            Group {
                if let lead = call.lead {
                    Text("\(Text(lead).fontWeight(.semibold).foregroundStyle(Color.loopr(.ink))) \(call.sentence)")
                } else {
                    Text(verbatim: call.sentence)
                }
            }
            .looprTypography(.prose)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .fixedSize(horizontal: false, vertical: true)
            if let needed = call.stillNeeded {
                LooprText(needed, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LooprSignedNumber.spoken(text: call.text))
    }
}

// MARK: - Finished list

/// Finished experiments, newest first, then finished ones started from a pattern.
struct ProtocolExperimentFinishedList: View {
    let items: [ProtocolExperimentItem]
    var patternTests: [ProtocolExperimentRow] = []
    let open: (ExperimentID) -> Void
    var openPatterns: () -> Void = {}
    /// The widest chip in the list, so every chip sits in one column and every title starts at the same edge
    /// (ICP R2-DES-14).
    @State private var chipColumn: CGFloat?

    var body: some View {
        let presentations = items.map { ProtocolExperimentPresentation.make($0) }
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Finished", identifier: "protocol-experiments-finished-header")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(presentations.enumerated()), id: \.element.id) { index, presentation in
                        if index > 0 { LooprHairline() }
                        ProtocolExperimentFinishedRow(presentation: presentation, chipColumn: chipColumn,
                                                      measuredChip: { width in chipColumn = max(chipColumn ?? 0, width) }) {
                            open(presentation.id)
                        }
                    }
                    ForEach(Array(patternTests.enumerated()), id: \.element.id) { index, row in
                        if index > 0 || !presentations.isEmpty { LooprHairline() }
                        ProtocolPatternTestRow(row: row, action: openPatterns)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-experiments-finished")
            let text = (presentations.map { $0.title + " " + $0.rowSubtitle } + patternTests.map { $0.title + " " + $0.detail })
                .joined(separator: " ")
            if ProtocolExperimentText.mentionsHRV(text) {
                LooprText(ProtocolExperimentText.hrvGloss, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xxs)
                    .accessibilityIdentifier("protocol-experiments-hrv-gloss")
            }
        }
    }
}

struct ProtocolExperimentFinishedRow: View {
    let presentation: ProtocolExperimentPresentation
    /// The width of the list's chip column. Nil until the chips are measured, and unused at accessibility sizes, where
    /// the chip sits above the title.
    var chipColumn: CGFloat? = nil
    var measuredChip: (CGFloat) -> Void = { _ in }
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
                : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.sm))
            HStack(spacing: LooprSpacing.sm) {
                layout {
                    ProtocolExperimentLabelChip(presentation: presentation)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredChip($0) }
                        .frame(width: typeSize.isAccessibilitySize ? nil : chipColumn, alignment: .leading)
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                        LooprText(presentation.title, style: .rowTitle)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprText(presentation.rowSubtitle, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .padding(.vertical, LooprSpacing.xs)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LooprSignedNumber.spoken(text: "\(presentation.chip). \(presentation.title). \(presentation.rowSubtitle)"))
        .accessibilityHint("Opens the result.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("protocol-experiment-finished-\(presentation.identifierSuffix)")
    }
}

/// A finished experiment that started from a pattern. Its result lives in Patterns, so the row opens Patterns.
struct ProtocolPatternTestRow: View {
    let row: ProtocolExperimentRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
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
        .accessibilityHint("Opens Patterns.")
        .accessibilityIdentifier("protocol-experiment-\(row.id)")
    }
}

/// Strong and Clear in the result green; every other state neutral. The word is the label, so colour is never the
/// only difference.
struct ProtocolExperimentLabelChip: View {
    let presentation: ProtocolExperimentPresentation

    var body: some View {
        if presentation.claimsDifference {
            StatusChip(presentation.chip, symbol: nil, accent: .recoveryHigh)
        } else {
            StatusChip(presentation.chip, symbol: nil, tone: .neutral)
        }
    }
}

// MARK: - Start one

/// Two ways to start an experiment: from a pattern Loopr found, which opens Patterns, or from ideas on the web.
struct ProtocolExperimentStartSection: View {
    let pattern: ProtocolPatternLine?
    let openPatterns: () -> Void
    /// Opens the community folder in Safari (LV-07.4). No GitHub API call.
    var openGitHub: () -> Void = {}

    var body: some View {
        let detail = pattern.map { ProtocolExperimentText.fromPattern(title: $0.title, outcome: $0.outcome) }
            ?? ProtocolExperimentText.noPattern
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Start one", identifier: "protocol-experiments-start-header")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    Button(action: openPatterns) {
                        HStack(spacing: LooprSpacing.sm) {
                            text(ProtocolExperimentText.fromPattern, detail: detail,
                                 gloss: ProtocolExperimentText.mentionsHRV(detail) ? ProtocolExperimentText.hrvGloss : nil)
                            LooprChevron()
                        }
                        .padding(.horizontal, LooprSpacing.cardHorizontal)
                        .padding(.vertical, LooprSpacing.xs)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens Patterns, where an experiment starts from a pattern.")
                    .accessibilityIdentifier("protocol-experiment-start-pattern")
                    LooprHairline()
                    Button(action: openGitHub) {
                        HStack(spacing: LooprSpacing.sm) {
                            text(ProtocolExperimentText.fromGitHub, detail: ProtocolExperimentText.fromGitHubDetail, gloss: nil)
                            Image(systemName: "safari")
                                .foregroundStyle(Color.loopr(.protocolChip))
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, LooprSpacing.cardHorizontal)
                        .padding(.vertical, LooprSpacing.xs)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Opens the community folder in Safari.")
                    .accessibilityIdentifier("protocol-experiment-start-github")
                }
            }
        }
    }

    private func text(_ title: String, detail: String, gloss: String?) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
            LooprText(title, style: .rowTitle)
                .fixedSize(horizontal: false, vertical: true)
            LooprText(detail, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let gloss {
                LooprText(gloss, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Strip view

/// Draws a `ProtocolExperimentStrip`: a legend and a row of dots for each arm, the mean as a short bar, the noise band
/// behind each row's dots (never behind a legend line, ICP R3-DES-09, R3-NEW-06, R3-VET-12) with one key line under
/// the axis that names it, and on a result the likely range of the on nights' average under their row. The captions
/// that explain the band and the bracket sit behind the card's "How this works". Dots that would cover
/// each other stack into lanes above and below the row's line, and the row grows to hold them. On its first showing of the day the dots land one
/// after another in night order; `revealed` counts them for a hero number. Under Reduce Motion the strip fades in at
/// its final state.
struct ProtocolExperimentStripView: View {
    let strip: ProtocolExperimentStrip
    let entranceKey: String
    @Binding var revealed: Int?

    @State private var entrance = false
    @State private var visible = false
    /// The rows' width, for how close two dots may sit before they stack.
    @State private var rowWidth: CGFloat = 300
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    static let dotSize: CGFloat = 11
    static let rowHeight: CGFloat = 30
    static let inset: CGFloat = 8
    /// Vertical distance between stacked lanes: a dot and a hair, so stacked rings touch but never overlap.
    static let laneStep: CGFloat = dotSize + 1

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                legend(.on)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    row(.on)
                    if strip.likelyRange != nil { rangeRow }
                }
                .background { band }
                legend(.off)
                row(.off)
                    .background { band }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            axis
            if strip.band != nil && !strip.isPlaceholder { bandKey }
            if strip.isEmpty && !strip.isPlaceholder {
                LooprText("No night counts yet. Each counted night lands here as a dot.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(visible ? 1 : 0)
        .onAppear {
            if LooprMotion.reducesMotion(reduceMotion) {
                withAnimation(.easeOut(duration: LooprMotion.standard)) { visible = true }
            } else {
                visible = true
            }
        }
        .looprEntrance(tab: entranceKey, animates: $entrance)
        .task(id: entrance) { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strip.accessibilitySummary)
    }

    private func color(_ arm: ExperimentArm) -> Color { Color.loopr(arm == .on ? .protocol : .inkSecondary) }

    private func legend(_ arm: ExperimentArm) -> some View {
        let count = arm == .on ? strip.onDots.count : strip.offDots.count
        let title = arm == .on ? strip.onTitle : strip.offTitle
        return HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            dot(arm)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            LooprText("\(title) \u{00B7} \(ProtocolExperimentText.nightCount(count))", style: .caption,
                      color: arm == .on ? .ink : .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// On nights are filled. Off nights are rings with a surface-coloured centre, so the mean bar does not show through
    /// a ring and read as a mark of its own.
    @ViewBuilder
    private func dot(_ arm: ExperimentArm) -> some View {
        if arm == .on {
            Circle().fill(color(.on)).frame(width: Self.dotSize, height: Self.dotSize)
        } else {
            Circle().fill(Color.loopr(.surface))
                .overlay { Circle().strokeBorder(color(.off), lineWidth: 2) }
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
    }

    /// Each dot's lane in one arm's row, keyed by dot id.
    private func lanes(_ dots: [ProtocolExperimentStrip.Dot]) -> [String: Int] {
        let usable = max(rowWidth - 2 * Self.inset, 1)
        let stacked = ProtocolExperimentStrip.lanes(positions: dots.map(\.position), minimumGap: Double(Self.dotSize / usable))
        return Dictionary(zip(dots.map(\.id), stacked), uniquingKeysWith: { first, _ in first })
    }

    /// The row's height: the usual 30 points, or enough for the widest stack of lanes.
    private func height(_ lanes: [String: Int]) -> CGFloat {
        let reach = CGFloat(lanes.values.map(abs).max() ?? 0)
        return max(Self.rowHeight, (2 * reach + 1) * Self.laneStep + 6)
    }

    private func x(_ position: Double, width: CGFloat) -> CGFloat {
        Self.inset + CGFloat(position) * max(width - 2 * Self.inset, 1)
    }

    private func row(_ arm: ExperimentArm) -> some View {
        let dots = arm == .on ? strip.onDots : strip.offDots
        let mean = arm == .on ? strip.onMean : strip.offMean
        let order = Dictionary(strip.dots.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let laneByID = lanes(dots)
        let rowHeight = height(laneByID)
        return GeometryReader { geometry in
            let width = geometry.size.width
            let middle = rowHeight / 2
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(width: max(width - 2 * Self.inset, 1), height: 1)
                    .position(x: width / 2, y: middle)
                if let mean {
                    Capsule()
                        .fill(color(arm))
                        .frame(width: 2.5, height: rowHeight - 6)
                        .position(x: x(strip.position(mean), width: width), y: middle)
                }
                ForEach(dots) { dot in
                    let landed = revealed.map { (order[dot.id] ?? 0) < $0 } ?? true
                    self.dot(arm)
                        .position(x: x(dot.position, width: width), y: middle - CGFloat(laneByID[dot.id] ?? 0) * Self.laneStep)
                        .offset(y: landed ? 0 : -18)
                        .scaleEffect(landed ? 1 : 0.4)
                        .opacity(landed ? 1 : 0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.62), value: landed)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private var rangeRow: some View {
        GeometryReader { geometry in
            if let range = strip.likelyRange {
                let width = geometry.size.width
                let low = x(strip.position(range.lowerBound), width: width)
                let high = x(strip.position(range.upperBound), width: width)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.loopr(.protocol))
                        .frame(width: max(high - low, 2), height: 2.4)
                        .position(x: (low + high) / 2, y: 7)
                    ForEach(Array([low, high].enumerated()), id: \.offset) { _, edge in
                        Capsule()
                            .fill(Color.loopr(.protocol))
                            .frame(width: 2, height: 10)
                            .position(x: edge, y: 7)
                    }
                }
            }
        }
        .frame(height: 14)
    }

    /// The noise band's fill, shared by the band behind the rows and the swatch in its key.
    private static var bandFill: Color { Color.loopr(.inkMuted).opacity(0.14) }

    /// The noise band behind one plot row: as tall as the row, so it never reaches a legend line.
    private var band: some View {
        GeometryReader { geometry in
            if let band = strip.band {
                let width = geometry.size.width
                let low = x(strip.position(band.lowerBound), width: width)
                let high = x(strip.position(band.upperBound), width: width)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Self.bandFill)
                    .frame(width: max(high - low, 2), height: geometry.size.height)
                    .position(x: (low + high) / 2, y: geometry.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    /// The band's one label, under the axis with a swatch drawn like the band, so the shading has a name on the
    /// running card and on the result alike.
    private var bandKey: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Self.bandFill)
                .frame(width: 18, height: Self.dotSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            LooprText("Your usual spread", style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.inset / 2)
    }

    private var axis: some View {
        let ticks = strip.ticks.map { ExperimentCopy.amount($0) }
        let unit = strip.unit.isEmpty ? "" : " \(strip.unit)"
        return HStack(alignment: .firstTextBaseline) {
            LooprText(ticks[0], style: .caption, color: .inkMuted)
            Spacer(minLength: LooprSpacing.xs)
            if !typeSize.isAccessibilitySize {
                LooprText(ticks[1], style: .caption, color: .inkMuted)
                Spacer(minLength: LooprSpacing.xs)
            }
            LooprText(ticks[2] + unit, style: .caption, color: .inkMuted)
        }
        .padding(.horizontal, Self.inset / 2)
    }

    private func play() async {
        guard entrance else { revealed = nil; return }
        let total = strip.dots.count
        guard total > 0 else { revealed = nil; return }
        revealed = 0
        try? await Task.sleep(for: .seconds(0.2))
        let step = min(0.06, 0.9 / Double(total))
        for index in 1...total {
            if Task.isCancelled { break }
            revealed = index
            try? await Task.sleep(for: .seconds(step))
        }
        revealed = nil
    }
}

extension ProtocolExperimentStrip {
    /// The empty shape: two rows, a band and no dots.
    static let placeholder = ProtocolExperimentStrip(
        dots: [], onTitle: "On nights", offTitle: ProtocolExperimentText.offTitle, unit: "", lowerBound: 0, upperBound: 10,
        onMean: nil, offMean: nil, band: 3.5...6.5, likelyRange: nil, spread: nil, difference: nil,
        accessibilitySummary: ProtocolExperimentText.noExperiment)

    var isPlaceholder: Bool { self == .placeholder }
}
