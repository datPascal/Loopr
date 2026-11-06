import DesignSystem
import DomainKit
import Foundation
import RoutineKit
import SwiftUI

// What sits around the deck and ends the check-in (ICP R1-DES-01, R1-SEN-09, R1-VET-16, R1-NEW-07): the quiet lines for
// rules still ahead and off nights, the "checked for you" row, the closing card once nothing is left, and the one row
// "How was your day?" that opens how you feel, the questions about the day and the note in a sheet.

/// Under the deck: "Later tonight" with one row per rule the person ticks that is still ahead, each a tap to answer it
/// now (ICP R2-VET-04, R2-HAB-04), then "Tonight is an off night for the magnesium test." in a quiet line.
struct ProtocolDeckLines: View {
    let later: ProtocolDeckLater?
    let offNights: [String]
    /// Brings a later rule to the front of the deck. Nil shows the rules as text only.
    var answerNow: ((RuleKey) -> Void)?

    var body: some View {
        if later != nil || !offNights.isEmpty {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                if let later { laterList(later) }
                ForEach(offNights, id: \.self) { text in
                    ProtocolQuietLine(text: text, symbol: "moon.zzz", identifier: "protocol-deck-off-night")
                }
            }
        }
    }

    private func laterList(_ later: ProtocolDeckLater) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ProtocolQuietLine(text: later.title, symbol: "clock", identifier: "protocol-deck-later-title")
                .accessibilityAddTraits(.isHeader)
            ForEach(later.shown) { item in
                if let answerNow {
                    Button { answerNow(item.key) } label: { row(item, tappable: true) }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityLabel(item.text)
                        .accessibilityHint("Brings it to the top of the deck, so you can answer it now.")
                        .accessibilityIdentifier(item.accessibilityIdentifier)
                } else {
                    row(item, tappable: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(item.accessibilityIdentifier)
                }
            }
            if later.more > 0 {
                LooprText("and \(later.more) more", style: .caption, color: .inkSecondary)
                    .padding(.leading, LooprSpacing.xl)
                    .accessibilityIdentifier("protocol-deck-later-more")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-deck-later")
    }

    /// "Magnesium, 300 mg" and "21:30" on the left, "Answer now" on the right; they stack at large text sizes.
    private func row(_ item: ProtocolDeckLater.Item, tappable: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                label(item)
                Spacer(minLength: LooprSpacing.xs)
                if tappable { answerLabel }
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                label(item)
                if tappable { answerLabel }
            }
        }
        .padding(.leading, LooprSpacing.xl)
        .padding(.vertical, LooprSpacing.xxs)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func label(_ item: ProtocolDeckLater.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            LooprText(item.name, style: .label, color: .ink)
                .fixedSize(horizontal: false, vertical: true)
            if let when = item.when {
                LooprText(when, style: .caption, color: .inkSecondary)
                    .fixedSize()
            }
        }
    }

    private var answerLabel: some View {
        HStack(spacing: LooprSpacing.xxs) {
            LooprText("Answer now", style: .label, color: .protocolChip)
                .fixedSize()
            LooprChevron()
        }
    }
}

/// A quiet caption line with a symbol: the deck's "Nothing yet. Next: Magnesium at 21:30." (ICP R2-DES-05), the later
/// list's title and the off-night line. No card, so a wait never looks like an empty state.
struct ProtocolQuietLine: View {
    let text: String
    let symbol: String
    let identifier: String
    var style: LooprTextStyle = .caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
            Image(systemName: symbol)
                .looprTypography(style)
                .foregroundStyle(Color.loopr(.inkSecondary))
                .frame(width: LooprSpacing.md)
                .accessibilityHidden(true)
            LooprText(text, style: style, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, LooprSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// "4 checked for you" over "By Food, Fitness and the band." A tap opens today's day sheet (ICP R1-NEW-08, R1-HAB-16).
/// It keeps the old line's identifier, `protocol-autofill`, which UI tests use.
struct ProtocolCheckedForYouRow: View {
    let item: ProtocolCheckedForYou
    let action: () -> Void

    var body: some View {
        ProtocolCheckInRow(symbol: "checkmark.circle", title: item.title, detail: item.detail, action: action)
            .accessibilityLabel(item.accessibilityLabel)
            .accessibilityHint("Opens today's rules, with what each source saw.")
            .accessibilityIdentifier("protocol-autofill")
    }
}

/// "How was your day?": how you feel, the questions about the day and the note, one tap down.
struct ProtocolEveningRow: View {
    let answered: Int
    let action: () -> Void

    static let title = "How was your day?"

    static func detail(answered: Int) -> String {
        answered > 0 ? "\(answered) answered. Optional." : "Mood, a few questions and a note. Optional."
    }

    var body: some View {
        ProtocolCheckInRow(symbol: "square.and.pencil", title: Self.title, detail: Self.detail(answered: answered), action: action)
            .accessibilityLabel("\(Self.title) \(Self.detail(answered: answered))")
            .accessibilityHint("Opens how you feel, questions about the day and your note.")
            .accessibilityIdentifier("protocol-evening-open")
    }
}

/// Which of the evening sheet's answers "How was your day?" counts (ICP R3-NEW-04): only answers made on the day it
/// shows, and only on the list's own days. On a new list's first day that starts when the list was made, so the Journal
/// answers from earlier that day are not read as the list's own. With none the row says what the sheet holds.
enum ProtocolEveningCount {
    /// The moment from which an answer counts for `day`: the start of that day, or the moment a new list was made on its
    /// first day. `distantFuture` for a day before the list began, where nothing counts.
    static func since(day: DayIdentity, routine: ProtocolRoutineData?, calendar: ProtocolWeekCalendar) -> Date {
        guard let noon = calendar.date(day) else { return .distantPast }
        let start = calendar.calendar.startOfDay(for: noon)
        guard let routine else { return start }
        if let first = calendar.adding(1 - max(routine.dayNumber, 1), to: routine.today),
           let lead = calendar.days(from: first, to: day), lead < 0 {
            return .distantFuture
        }
        // A list moved over from the Journal owns the Journal's answers, so only a new list starts at its own moment.
        let isNew = routine.version == 1 && routine.dayNumber <= 1 && routine.habitRuleIDs.isEmpty
        return isNew && day == routine.today ? max(start, routine.versionCreatedAt) : start
    }

    /// How many of the answers, by when each was made, count.
    static func count(_ madeAt: [Date], since: Date) -> Int {
        madeAt.filter { $0 >= since }.count
    }
}

/// A plain row on the check-in: a symbol, a title over a caption, and a chevron.
private struct ProtocolCheckInRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: symbol)
                    .looprTypography(.rowTitle)
                    .foregroundStyle(Color.loopr(.protocolChip))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LooprSpacing.xxs / 2) {
                    LooprText(title, style: .rowTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprText(detail, style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.vertical, LooprSpacing.xs)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
    }
}

/// The card in the deck's place once nothing is left to answer today: the day is done, and one line about tomorrow
/// (ICP R2-SEN-06). No streak and no word about what was not kept (ICP R1-SEN-08). "How was your day?" sits inside it.
struct ProtocolClosingCard<Footer: View>: View {
    let closing: ProtocolDeckClosing
    @ViewBuilder let footer: Footer

    var body: some View {
        LooprCard(style: .hero(.protocol)) {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                    Image(systemName: "moon.stars")
                        .looprTypography(.title)
                        .foregroundStyle(Color.loopr(.protocol))
                        .accessibilityHidden(true)
                    LooprText(closing.title, style: .title)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                LooprText(closing.detail, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let tomorrow = closing.tomorrow {
                    LooprText(tomorrow, style: .rowTitle, color: .protocolChip)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("protocol-deck-closing-tomorrow")
                }
                LooprHairline()
                footer
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("protocol-deck-closing")
    }
}

/// Where a tap in the evening sheet leads once the sheet has closed: a Journal screen, the note editor, or Rules.
enum ProtocolEveningExit {
    case route(JournalRoute)
    case note(JournalEntry?, dictate: Bool)
    case rules
}

/// "How was your day?": how you feel, the questions about the day that are not rules, the note, and at the foot the
/// rest of the Journal (Mood and habit links, Answer history, Privacy). The content keeps the identifier
/// `journal-check-in`. A tap that leads to another screen closes the sheet first and goes there from the tab.
struct ProtocolEveningSheet: View {
    @ObservedObject var habits: HabitViewModel
    @ObservedObject var journal: JournalViewModel
    let day: DayIdentity
    /// The protocol's rules. A question about the day that asks the same as a rule is left out (ICP R1-SEN-10).
    let rules: [ProtocolRule]
    /// "Skip the rest of today" under "Feeling sick" answered Yes (ICP R2-HAB-02). Nil on a day that is not today.
    var yesOffer: JournalYesOffer? = nil
    let leave: (ProtocolEveningExit) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.looprDayNavigation) private var dayNavigation
    @State private var showsInsights = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                    JournalFeelingSection(model: habits, day: day) {
                        if let dayNavigation {
                            Spacer(minLength: LooprSpacing.xs)
                            LooprDayNavigator(dayNavigation, accent: .protocol)
                        }
                    }
                    JournalQuestionsSection(model: habits, day: day, route: { leave(.route($0)) }, title: "About the day",
                                            openRules: { leave(.rules) },
                                            hides: { ProtocolQuestionMatch.matches($0.checkInTitle, rules: rules) },
                                            yesOffer: yesOffer, eveningIsSameDay: true, accent: .protocol)
                    JournalNoteSection(day: day, entries: journal.snapshot.entries,
                                       editNote: { entry, dictate in leave(.note(entry, dictate: dictate)) },
                                       openAll: { leave(.route(.history)) })
                    JournalErrorCard(model: habits)
                    more
                }
                .padding(LooprSpacing.screenGutter)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("journal-check-in")
            }
            .accessibilityIdentifier("protocol-evening-scroll")
            .background(Color.loopr(.background).ignoresSafeArea())
            .navigationTitle(ProtocolEveningRow.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("protocol-evening-done")
                }
            }
            .navigationDestination(isPresented: $showsInsights) { ProtocolJournalInsightsScreen(habits: habits, day: day) }
        }
        .presentationDetents([.large])
        .tint(Color.loopr(.protocol))
        .accessibilityIdentifier("protocol-evening-sheet")
    }

    /// The rest of the Journal, at the foot of the sheet.
    private var more: some View {
        var rows: [LooprMenuItem] = []
        if habits.settings.featureStage.exposesEntryPoints {
            rows.append(LooprMenuItem(title: "Mood and habit links", value: nil, accessibilityIdentifier: "journal-insights-open",
                                      action: { showsInsights = true }))
            rows.append(LooprMenuItem(title: "Answer history", value: nil, accessibilityIdentifier: "habit-history",
                                      action: { leave(.route(.habitHistory)) }))
        }
        rows.append(LooprMenuItem(title: "Privacy", value: "On this iPhone", accessibilityIdentifier: "journal-privacy",
                                  action: { leave(.route(.privacy)) }))
        return LooprMenuGroup(title: "More", rows: rows, headingIdentifier: "protocol-more")
    }
}

/// Whether a question about the day asks the same as a rule, such as "Read before sleep" and the rule "Read before
/// bed", or "Screens in bed" and "Screens off by 21:45" (ICP R1-SEN-10, R1-HAB-13). Two titles match when their first
/// word that carries meaning is the same, after small words, times and a plural "s" are set aside.
public enum ProtocolQuestionMatch {
    static let ignored: Set<String> = ["no", "not", "a", "an", "the", "in", "by", "at", "after", "before", "until", "of",
                                       "to", "off", "on", "late", "did", "you", "your", "keep", "for", "and", "with", "min",
                                       "minutes", "mg", "g", "h", "am", "pm"]

    public static func matches(_ question: String, rules: [ProtocolRule]) -> Bool {
        guard let lead = words(question).first else { return false }
        return rules.contains { words($0.title).first == lead }
    }

    /// The words that carry meaning, lowercased and singular, in order.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
            .filter { !ignored.contains($0) }
            .map { word in word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word }
    }
}
