import DesignSystem
import Foundation
import SwiftUI

/// How much of the day's rules the rail shows. `.full` is every rule; `.upNext` is Today's card: the next few rules not
/// kept yet and a row to all of them (UX R1-DES-01).
enum TodayRailStyle: Equatable {
    case full
    case upNext

    /// How many open rules Up next lists before "All N rules".
    static let upNextLimit = 3
}

/// "Protocol today": the chips, then one 56 pt row per rule in time order. A manual rule ticks with a tap on its row or
/// its square, or with a long press on the square that fills a ring; either plays the kept-rule success, and an Undo
/// line stays under the rules for a few seconds. VoiceOver gets a "Tick" action and the same Undo.
struct TodayRailView: View {
    let state: TodayRailState
    let tick: @MainActor (String) async -> Bool
    let untick: @MainActor (String) async -> Bool
    let openProtocol: @MainActor () -> Void
    var style: TodayRailStyle = .full

    /// Ticks the person made on this screen that the next read has not brought back yet, so a kept rule shows kept at
    /// once and a second tap has nothing to tick.
    @State private var ticked: Set<String> = []
    /// Rules ticked on this screen. Up next keeps their rows, now kept, until the person leaves Today, so a row never
    /// vanishes under the finger once the store confirms the tick.
    @State private var tickedHere: Set<String> = []
    /// The rule ticked last, while its Undo is offered.
    @State private var undoable: TodayRailUndo?
    @State private var haptic: LooprHaptic?

    /// How long Undo stays after a tick.
    static let undoSeconds: Double = 6

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            header
            switch state {
            case .rules(let content):
                let chips = visibleChips(content)
                if !chips.isEmpty {
                    TodayFlowLayout(spacing: LooprSpacing.xs) {
                        ForEach(chips) { chip in
                            TodayRailChipView(chip: chip, isTicked: ticked.contains(chip.id), tick: { run(chip.id, title: chip.title) })
                        }
                    }
                    .padding(.bottom, LooprSpacing.xxs)
                }
                let rows = visibleRows(content)
                if !rows.isEmpty || style == .upNext {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider().overlay(Color.loopr(.divider)) }
                            TodayRailRowView(row: row, timeTexts: rows.map(\.timeText), isTicked: ticked.contains(row.id),
                                             tick: { run(row.id, title: row.title) })
                        }
                        if style == .upNext {
                            if rows.isEmpty && chips.isEmpty {
                                Text(TodayRailContent.nothingLeft(kept: content.keptCount + ticked.count, total: content.ruleCount))
                                    .looprTypography(.prose)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                                    .accessibilityIdentifier("today-rail-done")
                            }
                            Divider().overlay(Color.loopr(.divider))
                            allRulesRow(total: content.ruleCount)
                        }
                    }
                    .padding(.horizontal, LooprSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .looprCardBackground()
                }
                if let undoable {
                    TodayRailUndoBar(undo: undoable) { revert(undoable) }
                        .transition(.opacity)
                }
            case .noProtocol:
                empty
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprHaptic(haptic)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-rail")
        .onChange(of: state) { _, _ in ticked = [] }
        .task(id: undoable) {
            guard let current = undoable else { return }
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, undoable == current else { return }
            withAnimation(.easeOut(duration: LooprMotion.fast)) { undoable = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            Text(style == .upNext ? "Up next" : "Protocol today")
                .looprTypography(.title)
                .foregroundStyle(Color.loopr(.ink))
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if case .rules(let content) = state, content.ruleCount > 0 {
                let kept = content.keptCount + ticked.count
                HStack(spacing: LooprSpacing.xs) {
                    Text(TodayRailContent.ringLabel(kept: kept, total: content.ruleCount))
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .monospacedDigit()
                    TodayRailMiniRing(kept: kept, total: content.ruleCount)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TodayRailContent.summary(kept: kept, total: content.ruleCount))
                .accessibilityIdentifier("today-rail-count")
            }
        }
        .padding(.horizontal, LooprSpacing.xxs)
    }

    /// Up next drops the rules already kept or missed and keeps the next few. Rules the person ticks come first, in
    /// time order; rules Food, Fitness, the band or Apple Health check on their own follow, because there is nothing to
    /// do about them right now (UX R2-DES-01, R2-NEW-02). A rule ticked here stays until the next read, so its row does
    /// not jump away under the finger.
    private func visibleRows(_ content: TodayRailContent) -> [TodayRailRow] {
        guard style == .upNext else { return content.rows }
        let open = content.rows.filter { row in
            ticked.contains(row.id) || tickedHere.contains(row.id) || row.state == .pending || row.state == .unknown
        }
        let yours = open.filter { $0.source == .manual }
        let checked = open.filter { $0.source != .manual }
        return Array((yours + checked).prefix(TodayRailStyle.upNextLimit))
    }

    /// Up next shows only the chips still to tick; a kept chip belongs in the full list.
    private func visibleChips(_ content: TodayRailContent) -> [TodayRailChip] {
        guard style == .upNext else { return content.chips }
        return content.chips.filter { ticked.contains($0.id) || $0.state == .pending || $0.state == .unknown }
    }

    private func allRulesRow(total: Int) -> some View {
        Button { openProtocol() } label: {
            HStack(spacing: LooprSpacing.xxs) {
                Text(TodayRailContent.allRulesLabel(total: total))
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(LooprColorToken.protocol.textInk))
                Spacer(minLength: 0)
                LooprChevron()
            }
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your check-in in Protocol.")
        .accessibilityIdentifier("today-rail-all")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            Text(TodayRailState.emptyText)
                .looprTypography(.prose)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { openProtocol() } label: {
                HStack(spacing: LooprSpacing.xxs) {
                    Text(TodayRailState.emptyAction)
                        .looprTypography(.label)
                        .foregroundStyle(Color.loopr(LooprColorToken.protocol.textInk))
                    LooprChevron()
                }
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today-rail-empty-open")
        }
        .padding(.vertical, LooprSpacing.sm)
        .padding(.horizontal, LooprSpacing.cardHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .looprCardBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-rail-empty")
    }

    private func run(_ key: String, title: String) {
        guard !ticked.contains(key) else { return }
        ticked.insert(key)
        tickedHere.insert(key)
        haptic = .ruleKept
        let offer = TodayRailUndo(key: key, title: title)
        withAnimation(.easeOut(duration: LooprMotion.fast)) { undoable = offer }
        Task { @MainActor in
            if await tick(key) == false {
                ticked.remove(key); tickedHere.remove(key)
                if undoable == offer { undoable = nil }
                haptic = .error
            }
        }
    }

    private func revert(_ offer: TodayRailUndo) {
        withAnimation(.easeOut(duration: LooprMotion.fast)) { undoable = nil }
        ticked.remove(offer.key)
        tickedHere.remove(offer.key)
        Task { @MainActor in
            if await untick(offer.key) == false { haptic = .error }
        }
    }
}

/// The rule ticked last on this screen, while Undo is on offer. The id makes two ticks of one rule two offers.
struct TodayRailUndo: Equatable {
    let key: String
    let title: String
    let id = UUID()
}

/// "Screens off ticked" and an Undo button, under the rules for a few seconds after a tick.
struct TodayRailUndoBar: View {
    let undo: TodayRailUndo
    let revert: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LooprSpacing.sm) {
            Text("\(undo.title) ticked")
                .looprTypography(.caption)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: revert) {
                Text("Undo")
                    .looprTypography(.label)
                    .foregroundStyle(Color.loopr(LooprColorToken.protocol.textInk))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo, \(undo.title)")
            .accessibilityIdentifier("today-rail-undo")
        }
        .padding(.horizontal, LooprSpacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-rail-undo-bar")
    }
}

/// The small ring beside "Protocol today": kept rules over all of today's rules. Its label sits beside it.
struct TodayRailMiniRing: View {
    let kept: Int
    let total: Int

    var body: some View {
        let share = total > 0 ? min(Double(kept) / Double(total), 1) : 0
        ZStack {
            Circle().stroke(Color.loopr(.divider), lineWidth: 3.2)
            Circle()
                .trim(from: 0, to: share)
                .stroke(Color.loopr(.brand), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// One rule: its time, a square in the domain accent, the title and what checks it.
struct TodayRailRowView: View {
    let row: TodayRailRow
    /// Every row's time text: the column takes the widest, so every square and title starts at the same x.
    var timeTexts: [String] = []
    let isTicked: Bool
    let tick: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isKept: Bool { row.state == .kept || isTicked }

    var body: some View {
        // At accessibility sizes the time goes above the title, so every line takes the row's whole width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: LooprSpacing.sm))
        layout {
            ZStack(alignment: .leading) {
                if !dynamicTypeSize.isAccessibilitySize {
                    ForEach(timeTexts, id: \.self) { text in
                        Text(text).looprTypography(.caption).monospacedDigit().hidden()
                    }
                }
                Text(row.timeText)
                    .looprTypography(.caption)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .monospacedDigit()
            }
            .fixedSize()
            .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? nil : 52, alignment: .leading)
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                TodayRailSquare(symbol: isKept ? "checkmark" : row.symbol, accent: row.accent, isKept: isKept,
                                canTick: row.canTick && !isTicked, identifier: "today-rail-tick-\(row.id)",
                                label: row.title, tick: tick)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .looprTypography(.rowTitle)
                        .foregroundStyle(Color.loopr(.ink))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(isTicked && row.state != .kept ? "Ticked" : row.detail)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(isKept ? .recoveryHigh : .inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress = row.progress, !isKept {
                        Capsule()
                            .fill(Color.loopr(.divider))
                            .frame(height: 4)
                            .overlay(alignment: .leading) {
                                GeometryReader { proxy in
                                    Capsule().fill(Color.loopr(row.accent)).frame(width: proxy.size.width * progress)
                                }
                            }
                            .frame(maxWidth: 120)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isTicked && row.state != .kept ? "\(row.title), \(row.timeText), ticked, kept" : row.accessibilityLabel)
                .modifier(TodayRailTickAction(enabled: row.canTick && !isTicked, tick: tick))
            }
        }
        .padding(.vertical, LooprSpacing.xs)
        .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
        // A tap anywhere on a row that can tick ticks it. The square keeps its own tap and hold.
        .contentShape(Rectangle())
        .onTapGesture { if row.canTick && !isTicked { tick() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-rail-rule-\(row.id)")
    }
}

/// The row's square. For a manual rule not kept yet a tap ticks it, and so does a hold: the ring fills while the finger
/// stays down, and the tick lands when it closes.
struct TodayRailSquare: View {
    let symbol: String
    let accent: LooprColorToken
    let isKept: Bool
    let canTick: Bool
    let identifier: String
    let label: String
    let tick: () -> Void

    var body: some View {
        let square = Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.loopr(isKept ? .background : accent))
            .frame(width: 36, height: 36)
            .background(Color.loopr(accent).opacity(isKept ? 1 : 0.16),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        // One 44 pt column whether the square ticks or not, so the titles beside it line up (ICP R2-UPG-23).
        if canTick {
            TodayHoldToTick(accent: accent, identifier: identifier, label: label, tick: tick) { square }
                .frame(width: 44, height: 44)
        } else {
            square
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }
}

/// A tap ticks at once. A long press fills a progress ring over `duration` and ticks when it closes, the press-and-feel
/// the vision asks of objects (rule 5); letting go before then is a tap. Always at least 44 pt.
struct TodayHoldToTick<Label: View>: View {
    let accent: LooprColorToken
    let identifier: String
    let label: String
    let tick: () -> Void
    @ViewBuilder let content: () -> Label
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: CGFloat = 0

    static var duration: Double { 0.8 }

    var body: some View {
        content()
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .trim(from: 0, to: fill)
                    .stroke(Color.loopr(accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(-3)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture { tick() }
            .onLongPressGesture(minimumDuration: Self.duration, maximumDistance: 16) {
                fill = 0
                tick()
            } onPressingChanged: { pressing in
                if pressing {
                    withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : .linear(duration: Self.duration)) { fill = 1 }
                } else {
                    withAnimation(.easeOut(duration: LooprMotion.fast)) { fill = 0 }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Tick \(label)")
            .accessibilityHint("Ticks this rule for today.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Tick") { tick() }
            .accessibilityIdentifier(identifier)
    }
}

/// VoiceOver's "Tick" on a row's text, the same tick a tap makes.
struct TodayRailTickAction: ViewModifier {
    let enabled: Bool
    let tick: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: "Tick") { tick() }
        } else {
            content
        }
    }
}

/// Morning light and supplements, at the top of the rail.
struct TodayRailChipView: View {
    let chip: TodayRailChip
    let isTicked: Bool
    let tick: () -> Void

    private var isKept: Bool { chip.state == .kept || isTicked }

    var body: some View {
        let capsule = HStack(spacing: LooprSpacing.xxs + 2) {
            Image(systemName: isKept ? "checkmark" : "circle")
                .font(.system(size: 12, weight: .bold))
            Text(chip.title)
                .looprTypography(.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.loopr(isKept ? .brandInk : .inkSecondary))
        .padding(.vertical, LooprSpacing.xs)
        .padding(.horizontal, LooprSpacing.sm)
        .frame(minHeight: 44)
        .background(Color.loopr(isKept ? .brandSoft : .divider), in: Capsule(style: .continuous))

        Group {
            if chip.canTick && !isTicked {
                TodayHoldToTick(accent: .brand, identifier: "today-rail-chip-\(chip.id)", label: chip.title, tick: tick) { capsule }
            } else {
                capsule
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(isTicked ? "\(chip.title), kept" : chip.accessibilityLabel)
                    .accessibilityIdentifier("today-rail-chip-\(chip.id)")
            }
        }
    }
}
