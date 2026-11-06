import DesignSystem
import Foundation
import SwiftUI

/// Where the rail's rules come from: the active protocol's rules with today's checks, or none yet.
public enum TodayRailSource: Equatable, Sendable {
    case rules([TodayRailRuleInput])
    case noProtocol
}

/// The weekly review's card on Today (LV-09.2): "Your week", from Sunday 17:00 until Monday 12:00, until the person opens
/// the review. The app decides the window and whether the week was seen; the card draws only inside the window.
public struct TodayWeekReviewOffer: Equatable, Sendable {
    /// The ISO week the review covers, such as `2026-W43`.
    public var weekKey: String
    public var opens: Date
    public var closes: Date
    public var title: String
    public var detail: String

    public init(weekKey: String, opens: Date, closes: Date, title: String, detail: String) {
        self.weekKey = weekKey
        self.opens = opens
        self.closes = closes
        self.title = title
        self.detail = detail
    }

    public func isOpen(at date: Date) -> Bool { opens <= date && date < closes }
}

/// Everything under the dial and the readouts (LV-04 step 3): the coach note, the first-evening card, the weekly review
/// card, the protocol rail and the experiment strip. The app reads it from its stores; TodayKit decides which note shows at what time.
public struct TodayCompanionContent: Equatable, Sendable {
    /// The rule-written morning note, or its learning or absent state. Nil hides the note slot.
    public var morning: TodayNoteState?
    /// The evening note. After 18:00 it replaces the morning note; without one the morning note stays.
    public var evening: TodayNoteCard?
    /// Nil when this composition has no protocol store; the rail then draws nothing.
    public var rail: TodayRailSource?
    public var experiment: TodayExperimentStrip?
    /// The weekly review card's window, or nil when there is nothing to offer or the week was seen.
    public var weekReview: TodayWeekReviewOffer?
    /// The bedtime Live Activity is on (DEC-12.17). Start wind-down shows in the note only then.
    public var bedtimeEnabled: Bool
    /// The person has not dismissed the first-evening card.
    public var offersFirstEvening: Bool
    public var isToday: Bool
    /// The instant the content was read for, and whether it stays there (fixture launches pin the clock).
    public var now: Date
    public var isClockPinned: Bool
    /// Its time zone decides 18:00.
    public var calendar: Calendar
    public var locale: Locale

    public init(morning: TodayNoteState? = nil, evening: TodayNoteCard? = nil, rail: TodayRailSource? = nil,
                experiment: TodayExperimentStrip? = nil, bedtimeEnabled: Bool = false, offersFirstEvening: Bool = true,
                isToday: Bool = true, now: Date, isClockPinned: Bool = false, calendar: Calendar, locale: Locale = .current) {
        self.morning = morning
        self.evening = evening
        self.rail = rail
        self.experiment = experiment
        self.bedtimeEnabled = bedtimeEnabled
        self.offersFirstEvening = offersFirstEvening
        self.isToday = isToday
        self.now = now
        self.isClockPinned = isClockPinned
        self.calendar = calendar
        self.locale = locale
    }

    /// Evening from 18:00 on today's content, morning otherwise and on every past day, as the dial decides it.
    public func mode(at date: Date) -> TodayDialMode {
        let instant = isClockPinned ? now : date
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return isToday && minute >= TodayDialMode.eveningStartMinute ? .evening : .morning
    }

    /// The note for the mode. In the evening the evening note wins; Start wind-down stays off it until the bedtime
    /// activity is on. The note never carries its own Ask chip: Today keeps Ask in the header and the Ask card, two
    /// entry points instead of three (R1-UPG-18, R1-OPT-20).
    public func note(for mode: TodayDialMode) -> TodayNoteState? {
        // "All 29 nights" went too: "See the nights" under the note already shows them, and three links to one place
        // was two too many (UX R2-DES-02).
        if mode == .evening, let evening {
            let note = evening.removingChip(.ask).removingChip(.showNights)
            return .note(bedtimeEnabled ? note : note.removingChip(.startWindDown))
        }
        if case .note(let card)? = morning { return .note(card.removingChip(.ask).removingChip(.showNights)) }
        return morning
    }

    /// The first-evening card offers the bedtime activity on an evening with rules still to come, until the person
    /// turns it on or says not now.
    public func showsFirstEvening(for mode: TodayDialMode) -> Bool {
        mode == .evening && isToday && !bedtimeEnabled && offersFirstEvening
            && evening?.chips.contains { $0.action == .startWindDown } == true
    }

    /// The weekly review card shows on today's content inside its window. A pinned clock reads the pinned instant.
    public func showsWeekReview(at date: Date) -> Bool {
        isToday && weekReview?.isOpen(at: isClockPinned ? now : date) == true
    }

    public func rail(for mode: TodayDialMode) -> TodayRailState? {
        switch rail {
        case .rules(let rules)?: .rules(TodayRailRules.content(rules, isToday: isToday, mode: mode, locale: locale))
        case .noProtocol?: .noProtocol
        case nil: nil
        }
    }
}

/// What the companion's controls do. The app writes through RoutineKit and the bedtime runtime.
public struct TodayCompanionActions {
    public var note: @MainActor (TodayNoteAction) -> Void
    /// Ticks a manual rule for today. True when the tick is stored.
    public var tick: @MainActor (String) async -> Bool
    /// Takes back a tick made on Today (the rail's Undo). True when the tick is gone.
    public var untick: @MainActor (String) async -> Bool
    public var openProtocol: @MainActor () -> Void
    public var openExperiment: @MainActor () -> Void
    /// Opens the weekly review sheet.
    public var openWeekReview: @MainActor () -> Void
    /// True starts wind-down from the first-evening card; false is "Not now".
    public var firstEvening: @MainActor (Bool) -> Void

    public init(note: @escaping @MainActor (TodayNoteAction) -> Void = { _ in },
                tick: @escaping @MainActor (String) async -> Bool = { _ in false },
                untick: @escaping @MainActor (String) async -> Bool = { _ in false },
                openProtocol: @escaping @MainActor () -> Void = {},
                openExperiment: @escaping @MainActor () -> Void = {},
                openWeekReview: @escaping @MainActor () -> Void = {},
                firstEvening: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.note = note
        self.tick = tick
        self.untick = untick
        self.openProtocol = openProtocol
        self.openExperiment = openExperiment
        self.openWeekReview = openWeekReview
        self.firstEvening = firstEvening
    }
}

/// Which part of the companion a view draws. Today's first screen holds the note, the weekly review card, Up next and the
/// first-evening card; the experiment strip waits under "More from today" (UX R1-DES-01).
public enum TodayCompanionPart: Sendable {
    case main
    case more
}

/// The note, the weekly review card, Up next and the first-evening card, top to bottom, or the experiment strip alone.
/// Nothing here animates except the receipt dots landing once a day; the dial stays the one moving object.
public struct TodayCompanionView: View {
    let content: TodayCompanionContent
    let actions: TodayCompanionActions
    let part: TodayCompanionPart

    public init(content: TodayCompanionContent, actions: TodayCompanionActions, part: TodayCompanionPart = .main) {
        self.content = content
        self.actions = actions
        self.part = part
    }

    /// True when the part has something to draw, so Today can leave out an empty "More from today".
    public static func hasMore(_ content: TodayCompanionContent) -> Bool {
        content.experiment != nil && content.isToday
    }

    public var body: some View {
        // Read once a minute so the 18:00 switch follows the clock, as the dial does. A pinned clock never moves.
        TimelineView(.periodic(from: TodayDialSection.minuteStart(), by: 60)) { context in
            let mode = content.mode(at: context.date)
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                switch part {
                case .main:
                    if let note = content.note(for: mode) {
                        TodayNoteCardView(state: note, act: actions.note)
                    }
                    if content.showsWeekReview(at: context.date), let offer = content.weekReview {
                        TodayWeekReviewCard(offer: offer, open: actions.openWeekReview)
                    }
                    if let rail = content.rail(for: mode) {
                        TodayRailView(state: rail, tick: actions.tick, untick: actions.untick,
                                      openProtocol: actions.openProtocol, style: .upNext)
                    }
                    // The bedtime opt-in waits under the rules the person came to tick.
                    if content.showsFirstEvening(for: mode) {
                        TodayFirstEveningCard(act: actions.firstEvening)
                    }
                case .more:
                    if let experiment = content.experiment, content.isToday {
                        TodayExperimentStripView(strip: experiment, open: actions.openExperiment)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Every card keeps its ideal height; none is squeezed into the one above it.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        // As under the dial: large text must not widen the scroll view past the screen.
        .containerRelativeFrame(.horizontal)
    }
}


/// "Your week": the coach's orb, a line on what the five pages hold, and a tap that opens them as a sheet.
struct TodayWeekReviewCard: View {
    let offer: TodayWeekReviewOffer
    let open: @MainActor () -> Void

    var body: some View {
        Button { open() } label: {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                LooprCoachOrb(size: .regular)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    Text(offer.title)
                        .looprTypography(.cardTitle)
                        .foregroundStyle(Color.loopr(.ink))
                    Text(offer.detail)
                        .looprTypography(.caption)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.vertical, LooprSpacing.md)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .looprCardBackground(.hero(.protocol))
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(offer.title). \(offer.detail)")
        .accessibilityHint("Opens the weekly review.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("today-week-card")
    }
}
