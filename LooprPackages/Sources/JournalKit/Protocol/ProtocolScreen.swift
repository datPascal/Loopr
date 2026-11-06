import DesignSystem
import DomainKit
import RoutineKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// The three views of the Protocol tab.
public enum ProtocolSegment: String, CaseIterable, Hashable, Sendable {
    case checkIn = "checkin"
    case experiments
    case rules

    public var title: String {
        switch self {
        case .checkIn: "Check-in"
        case .experiments: "Experiments"
        case .rules: "Rules"
        }
    }
}

/// A screen the Protocol tab pushes. The host appends it to its stack's path and shows `ProtocolRouteDestination` for
/// it. A `navigationDestination(isPresented:)` or `(item:)` push here kept the main thread re-presenting the screen
/// until AttributeGraph had described the destination's type, which in this app can take minutes after launch.
public enum ProtocolRoute: Hashable, Sendable {
    /// A finished experiment's result.
    case experiment(ExperimentID)
    /// Every saved version of the rules.
    case versionHistory
    /// The share pass.
    case pass
}

/// The screen behind a `ProtocolRoute`, for the host's `navigationDestination(for:)`.
public struct ProtocolRouteDestination: View {
    @ObservedObject private var model: ProtocolTabModel
    private let route: ProtocolRoute

    public init(model: ProtocolTabModel, route: ProtocolRoute) {
        self.model = model
        self.route = route
    }

    public var body: some View {
        switch route {
        case .experiment(let id): ProtocolExperimentResultScreen(model: model, id: id)
        case .versionHistory: ProtocolVersionHistoryScreen(model: model)
        case .pass: ProtocolPassScreen(model: model)
        }
    }
}

/// The Protocol tab root (contract phone p-proto). The colour field, the header with the day and rule count, the
/// segments, then on Check-in: the week of rosettes, one hero line ("12 of 13 kept this week · In bed not kept on
/// Monday", with the key and the counting rule behind its info button), and the deck of rules whose time has come, with
/// "See all" in its header, which opens today's day sheet (ICP R3-HAB-03). Under the deck sit the ready card on day 1,
/// the rules still ahead, each a tap to answer now, "Skip the rest of today", the pattern line while a card is due,
/// "4 checked for you", which opens today's day sheet, and "How was your day?", which opens how you feel, the questions
/// about the day and the note in a sheet. While nothing is due the deck is one quiet line and the pattern line sits
/// above it; once nothing is left a closing card takes its place and says what tomorrow holds. On Experiments: the
/// running experiment's strip, the finished results, which open the result screen, and the ways to start one.
///
/// The scroll view keeps the identifier `journal-screen` and the header's Ask button `journal-header-ask`, which the
/// tab's existing UI tests use; the content carries `protocol-screen`.
public struct ProtocolScreen: View {
    @ObservedObject private var model: ProtocolTabModel
    @ObservedObject private var journal: JournalViewModel
    private let route: (JournalRoute) -> Void
    private let push: (ProtocolRoute) -> Void
    private let editNote: (JournalEntry?, DayIdentity, Bool) -> Void
    private let openPatterns: () -> Void
    private let weeklyReview: ProtocolWeeklyReviewEntry?

    /// - Parameter push: Puts a result, the version history or the share pass on the host's navigation path.
    public init(model: ProtocolTabModel, journal: JournalViewModel, route: @escaping (JournalRoute) -> Void = { _ in },
                push: @escaping (ProtocolRoute) -> Void, editNote: ((JournalEntry?, DayIdentity, Bool) -> Void)? = nil,
                openPatterns: @escaping () -> Void = {}, weeklyReview: ProtocolWeeklyReviewEntry? = nil) {
        self.model = model
        self.journal = journal
        self.route = route
        self.push = push
        self.editNote = editNote ?? { _, _, _ in route(.compose) }
        self.openPatterns = openPatterns
        self.weeklyReview = weeklyReview
    }

    public var body: some View {
        ProtocolScreenContent(model: model, habits: model.habits, journal: journal, route: route, push: push,
                              editNote: editNote, openPatterns: openPatterns, weeklyReview: weeklyReview)
            #if canImport(UIKit)
            .looprDotFlightHost()
            #endif
    }
}

private struct ProtocolScreenContent: View {
    @ObservedObject var model: ProtocolTabModel
    @ObservedObject var habits: HabitViewModel
    @ObservedObject var journal: JournalViewModel
    let route: (JournalRoute) -> Void
    let push: (ProtocolRoute) -> Void
    let editNote: (JournalEntry?, DayIdentity, Bool) -> Void
    let openPatterns: () -> Void
    let weeklyReview: ProtocolWeeklyReviewEntry?

    @Environment(\.looprAsk) private var ask
    @Environment(\.looprDayNavigation) private var dayNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if canImport(UIKit)
    @Environment(\.looprDotFlight) private var flight
    #endif
    @State private var segment = ProtocolSegment.checkIn
    @AppStorage(ProtocolIntro.seenKey) private var introSeen = false
    /// Set once the person opened a day, which retires "Tap a day to see each rule".
    @AppStorage(ProtocolRosetteHint.openedKey) private var dayOpened = false
    /// Deck answers given on this phone. The swipe hint shows only before the third, and only to a person with no answer
    /// of their own in the stored history (ICP R1-HAB-05, R3-HAB-01).
    @AppStorage("loopr.protocol.deckAnswers") private var deckAnswers = 0
    @State private var haptic: LooprHaptic?
    /// The week as it was before an answer, held until the answer's dot lands on today's rosette.
    @State private var heldDays: [ProtocolDayPresentation]?
    @State private var entrance = false
    @State private var revealed: Int?
    /// The rule editor on screen (LV-07.4).
    @State private var editing: ProtocolRuleEditing?
    @State private var showsImporter = false
    /// The day sheet on screen, opened from a rosette, the hero's not kept line or "checked for you".
    @State private var openedDay: ProtocolOpenedDay?
    /// "How was your day?" on screen.
    @State private var showsEvening = false
    /// Where the evening sheet leads once it has closed.
    @State private var eveningExit: ProtocolEveningExit?
    @Environment(\.openURL) private var openURL

    var body: some View {
        LooprTabScaffold(
            header: LooprTabHeaderContent(title: "Protocol", accent: .protocol, dayPhrase: model.headerMeta,
                                          secondaryAction: ask?.header(for: "Protocol", identifier: "journal-header-ask")),
            glow: .protocol, field: .protocol, identifier: "journal-screen"
        ) {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                // With no protocol the tab is one start screen, with no segments to choose from (ICP R1-DES-03).
                if model.content?.routine != .noProtocol {
                    LooprGlassSegmentedControl("Protocol view", segments: ProtocolSegment.allCases.map {
                        LooprGlassSegment($0.title, value: $0, identifier: "protocol-segment-\($0.rawValue)")
                    }, selection: $segment, identifier: "protocol-segments")
                }
                switch segment {
                case .checkIn: checkIn
                case .experiments:
                    ProtocolExperimentsSegment(content: model.content, open: { push(.experiment($0)) },
                                               openPatterns: openPatterns, openGitHub: openGitHub)
                case .rules: rules
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.sm)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("protocol-screen")
        }
        .scrollIndicators(.hidden)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(Color.loopr(.protocol))
        .looprHaptic(haptic)
        .task { await model.load() }
        .task(id: selectedDay) { await habits.refreshAutoFill(on: selectedDay) }
        .onAppear { if let start = model.takeInitialSegment() { segment = start } }
        .sheet(item: $openedDay) { opened in ProtocolDaySheet(model: model, day: opened.day) }
        .sheet(isPresented: $showsEvening, onDismiss: leaveEvening) {
            ProtocolEveningSheet(habits: habits, journal: journal, day: selectedDay, rules: model.routine?.rules ?? [],
                                 yesOffer: selectedDay == model.routine?.today ? ProtocolSickDayOffer.offer(model: model) : nil) { exit in
                eveningExit = exit
                showsEvening = false
            }
        }
        .modifier(ProtocolRulesPresentations(model: model, segment: $segment, editing: $editing,
                                             showsImporter: $showsImporter, haptic: $haptic))
    }

    private func openGitHub() { openURL(ProtocolCommunity.repositoryURL) }

    private var selectedDay: DayIdentity {
        guard let day = dayNavigation?.day else { return habits.currentDay }
        return DayIdentity(year: day.year, month: day.month, day: day.day)
    }

    // MARK: Check-in

    @ViewBuilder
    private var checkIn: some View {
        switch model.content?.routine {
        case nil:
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprSkeleton(height: ProtocolRosetteWeek.height + ProtocolRosetteWeek.letterHeight)
                LooprSkeleton(height: 64)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading your protocol")
            .accessibilityIdentifier("protocol-loading")
        case .noProtocol?:
            ProtocolStartView(model: model, hasQuestions: !habits.activeDefinitions.isEmpty, startFromQuestions: { useMyQuestions() },
                              importFile: { showsImporter = true }, openGitHub: openGitHub)
        case .unavailable(let message)?:
            ProtocolUnavailableCard(message: message) { Task { await model.load() } }
            eveningRow(routine: nil)
        case .ready(let routine)?:
            // When cards are due the order is the week, one hero line, then the deck, so Yes and No sit above the tab bar
            // without a scroll on a 6.3 inch phone at 21:50 (ICP R2-NEW-01, R3-NEW-01, R3-SEN-01, R3-VET-04, R3-DES-01).
            // The pattern line then waits under the deck; once nothing is due it sits above it.
            let cardsDue = !model.deck.isEmpty
            week
            if !cardsDue {
                patternLineSlot
                prominentReview
            }
            deck(routine: routine)
            if cardsDue { prominentReview }
            if let weeklyReview, let placement = reviewPlacement, !placement.isProminent {
                ProtocolWeeklyReviewRow(entry: weeklyReview, title: placement.title, prominent: false)
            }
        }
        if let message = model.errorMessage {
            LooprInlineMessage(message, tone: .warning)
                .accessibilityIdentifier("protocol-message")
        }
    }

    /// The weekly review when the week has just ended (ICP R1-DES-18, R1-NEW-09). Above the deck only while no card is
    /// due.
    @ViewBuilder
    private var prominentReview: some View {
        if let weeklyReview, let placement = reviewPlacement, placement.isProminent {
            ProtocolWeeklyReviewRow(entry: weeklyReview, title: placement.title, prominent: true)
        }
    }

    /// Where the weekly review's row sits and what it says. Nil without the week it covers, and nil until the protocol
    /// has run that whole week, so a list started today shows no "Last week" (ICP R2-NEW-02).
    private var reviewPlacement: ProtocolWeeklyReviewPlacement? {
        guard let monday = weeklyReview?.monday, let routine = model.routine,
              let started = model.week.adding(1 - max(routine.dayNumber, 1), to: routine.today),
              let lead = model.week.days(from: started, to: monday), lead >= 0 else { return nil }
        return model.weeklyReviewPlacement(monday: monday)
    }

    /// The week of rosettes and its one hero line. "Tap a day to see each rule" shows under them only while no card is
    /// due, until the person has opened a day once.
    @ViewBuilder
    private var week: some View {
        let days = heldDays ?? model.days
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            ProtocolRosetteWeek(days: days, revealed: revealed, open: { openDay($0.day) })
                .looprEntrance(tab: LooprColorFieldTab.protocol.rawValue, animates: $entrance)
                .task(id: entrance) { await playEntrance(days: days) }
            if let summary = model.summary {
                ProtocolThisWeekHero(model: model, summary: summary, openSlip: summary.slippedDay.map { day in { openDay(day) } })
            }
            if model.deck.isEmpty { ProtocolRosetteHint() }
        }
    }

    // MARK: Deck

    /// The deck while something is left to answer today, then the closing card. The check-in ends here (ICP R1-DES-01).
    /// The slot closes as the last card goes: the model drops a card while its answer saves, so the quiet line or the
    /// closing card takes its place in the same animation and no empty card frame stays (ICP R3-NEW-08, R3-DES-11).
    /// On day 1 the ready card sits right under the card, then in the deck's place once nothing is due (R3-SEN-04).
    @ViewBuilder
    private func deck(routine: ProtocolRoutineData) -> some View {
        if let closing = model.closing {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                readyCard(routine)
                ProtocolClosingCard(closing: closing) { eveningRow(routine: routine) }
                ProtocolDeckLines(later: nil, offNights: model.offNightLines)
                skipRestOfTodaySlot
                if let lastAnswer = model.lastAnswer { undoRow(lastAnswer) }
                introCard(routine)
                checkedForYou
            }
        } else {
            let cardsDue = !model.deck.isEmpty
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                deckHeader
                if !cardsDue { readyCard(routine) }
                ProtocolDeckView(questions: model.deck, waitingText: model.waitingLine ?? Self.nothingDue,
                                 lastAnswer: model.lastAnswer, isSaving: model.isSaving,
                                 showsSwipeHint: model.showsSwipeHint(answersOnPhone: deckAnswers),
                                 onAnswer: answer, onUndo: undo)
                if cardsDue { readyCard(routine) }
                ProtocolDeckLines(later: model.deckLater, offNights: model.offNightLines, answerNow: answerEarly)
                skipRestOfTodaySlot
                introCard(routine)
                if cardsDue { patternLineSlot }
                checkedForYou
                eveningRow(routine: routine)
            }
        }
    }

    static let nothingDue = "Nothing to answer right now."

    /// "Tonight's check-in", "2 left" and "See all", which opens today's day sheet: every rule of the day as a list with
    /// its answers (ICP R3-HAB-03). At large text sizes the count and "See all" go under the title.
    private var deckHeader: some View {
        let progress = model.deckProgress
        let title = LooprText(model.deckTitle, style: .title)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("protocol-deck-title")
        let count = progress.text.map { text in
            LooprText(text, style: .label, color: .inkSecondary)
                .accessibilityLabel(progress.accessibilityLabel)
                .accessibilityIdentifier("protocol-deck-progress")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                title
                Spacer(minLength: LooprSpacing.sm)
                count
                seeAll
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                title.fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                    count
                    Spacer(minLength: LooprSpacing.sm)
                    seeAll
                }
            }
        }
    }

    /// "See all": today's day sheet, the same one today's rosette opens. Its tap area is 44 pt high without making the
    /// header row taller, so the first card does not move down.
    private var seeAll: some View {
        Button {
            if let today = model.routine?.today { openDay(today) }
        } label: {
            LooprText("See all", style: .label, color: .protocolChip)
                .fixedSize()
                .padding(.vertical, LooprSpacing.sm)
                .padding(.leading, LooprSpacing.xs)
                .contentShape(Rectangle())
                .padding(.vertical, -LooprSpacing.sm)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all of today's rules")
        .accessibilityHint("Opens today's rules as a list, so you can answer each one there.")
        .accessibilityIdentifier("protocol-deck-see-all")
    }

    /// "Your list is ready" on a new protocol's first day.
    private func readyCard(_ routine: ProtocolRoutineData) -> some View {
        ProtocolReadyCard(routine: routine, locale: model.week.locale)
    }

    /// The card for a protocol moved over from the Journal.
    @ViewBuilder
    private func introCard(_ routine: ProtocolRoutineData) -> some View {
        if !introSeen && ProtocolIntro.shows(routine) {
            ProtocolIntroCard(intro: ProtocolIntro.make(rules: routine.rules, habitRuleIDs: routine.habitRuleIDs,
                                                        stayed: habits.checkInDefinitions.map(\.checkInTitle),
                                                        locale: model.week.locale)) {
                withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) { introSeen = true }
            }
        }
    }

    // MARK: Pattern line and skip

    /// The first clear or strong pattern Patterns shows, as a headline over its counts, spread and "Not proof of cause"
    /// (ICP R4 Q7), or how many more nights it needs. A tap opens Patterns, which names the rule (ICP R2-HAB-01,
    /// R3-NEW-02). Nothing on days 1 and 2.
    private var patternLineSlot: some View {
        ProtocolCheckInPatternLine(signal: model.patternSignal, open: openPatterns)
    }

    /// "Skip the rest of today" in the deck's foot while a rule is open, then "6 rules skipped for today." with Undo,
    /// which also sits under the closing card the skip brings on (ICP R2-NEW-06, R2-HAB-02).
    private var skipRestOfTodaySlot: some View {
        ProtocolSkipDayAction(openCount: model.skipDayOpenCount, checking: model.skipDayChecking, skipped: model.skippedToday,
                              isSaving: model.isSaving,
                              skip: { haptic = .light; Task { await model.skipRestOfToday() } },
                              undo: { haptic = .light; Task { await model.undoSkipRestOfToday() } })
    }

    @ViewBuilder
    private var checkedForYou: some View {
        if let item = model.checkedForYou, let today = model.routine?.today {
            ProtocolCheckedForYouRow(item: item) { openDay(today) }
        }
    }

    private func eveningRow(routine: ProtocolRoutineData?) -> some View {
        ProtocolEveningRow(answered: eveningAnswered(routine: routine)) { showsEvening = true }
    }

    /// The answers the evening sheet shows for the day: how you feel, soreness, the questions about the day it lists and
    /// the note. A question the sheet leaves out because a rule asks the same is not counted (ICP R2-NEW-02), and only
    /// answers made on that day of the list count, so a new list does not show the Journal's answers from earlier as its
    /// own (ICP R3-NEW-04).
    private func eveningAnswered(routine: ProtocolRoutineData?) -> Int {
        let day = selectedDay
        let rules = routine?.rules ?? []
        var madeAt: [Date] = []
        if let record = habits.record(for: day) {
            let wellbeing = record.wellbeing
            for feeling in JournalFeeling.allCases where wellbeing?[feeling] != nil {
                madeAt.append(wellbeing?.firstAnsweredAt?[feeling.rawValue] ?? record.updatedAt)
            }
            if wellbeing?.soreness != nil { madeAt.append(record.updatedAt) }
        }
        for definition in habits.checkInDefinitions where !ProtocolQuestionMatch.matches(definition.checkInTitle, rules: rules) {
            if let response = habits.record(for: habits.behaviorDay(for: definition.checkInPeriod, selectedDay: day, eveningIsSameDay: true))?
                .response(for: definition.id) {
                madeAt.append(response.updatedAt)
            }
        }
        if let note = journal.snapshot.entries.filter({ $0.day == day.habitKey }).map(\.updatedAt).max() { madeAt.append(note) }
        return ProtocolEveningCount.count(madeAt, since: ProtocolEveningCount.since(day: day, routine: routine, calendar: model.week))
    }

    /// Undo stays reachable after the last card, under the closing card.
    private func undoRow(_ answer: ProtocolDeckAnswer) -> some View {
        ProtocolDeckView(questions: [], waitingText: "", lastAnswer: answer, isSaving: model.isSaving, onAnswer: { _, _ in },
                         onUndo: undo, showsEmpty: false)
    }

    /// A tap on a rule in the later list brings its card to the top of the deck (ICP R2-VET-04, R2-HAB-04).
    private func answerEarly(_ key: RuleKey) {
        haptic = .light
        withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) { model.answerEarly(key) }
    }

    private func openDay(_ day: DayIdentity) {
        dayOpened = true
        openedDay = ProtocolOpenedDay(day: day)
    }

    /// Runs what a tap in the evening sheet asked for, once the sheet is gone. A push or a new sheet started inside the
    /// dismissal's own update is dropped, so it waits for the next run loop and the end of the slide-down.
    private func leaveEvening() {
        guard let exit = eveningExit else { return }
        eveningExit = nil
        let day = selectedDay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            switch exit {
            case .route(let target): route(target)
            case .note(let entry, let dictate): editNote(entry, day, dictate)
            case .rules: segment = .rules
            }
        }
    }

    private var rules: some View {
        let useQuestions: (() -> Void)? = habits.activeDefinitions.isEmpty ? nil : { useMyQuestions() }
        return ProtocolRulesSegment(model: model, edit: { editing = ProtocolRuleEditing(draft: $0) },
                                    openHistory: { push(.versionHistory) }, openShare: { push(.pass) },
                                    importFile: { showsImporter = true }, openGitHub: openGitHub,
                                    startFromQuestions: useQuestions)
    }

    /// "Use my questions" makes the protocol at once and lands on its rules (ICP R3-UPG-5). The questions themselves are
    /// edited from the check-in, as before.
    private func useMyQuestions() {
        Task {
            if await model.startFromQuestions() { segment = .rules }
        }
    }

    // MARK: Entrance

    /// The dots land one after another, once a day.
    private func playEntrance(days: [ProtocolDayPresentation]) async {
        guard entrance else { revealed = nil; return }
        let total = days.reduce(0) { $0 + $1.dots.count }
        guard total > 0 else { return }
        let step = min(0.03, 0.9 / Double(total))
        for index in 0...total {
            revealed = index
            try? await Task.sleep(for: .seconds(step))
            if Task.isCancelled { break }
        }
        revealed = nil
    }

    // MARK: Answers

    private func answer(_ question: ProtocolDeckQuestion, choice: ProtocolDeckChoice) {
        guard !model.isSaving else { return }
        haptic = choice == .yes && question.ruleKey != nil ? .ruleKept : .light
        deckAnswers += 1
        let isRule = question.ruleKey != nil
        if isRule { heldDays = model.days }
        #if canImport(UIKit)
        let color: UIColor = switch choice {
        case .yes: UIColor(Color.loopr(.protocol))
        case .no: UIColor(Color.loopr(.inkMuted))
        case .skip: UIColor(Color.loopr(.inkMuted).opacity(0.5))
        }
        let flew = isRule && flight?.fly(from: ProtocolDeckView.flightSource, to: ProtocolRosetteWeek.flightTarget,
                                         shape: .point, colors: [color],
                                         haptics: LooprDotFlightHaptics(playsSuccess: false),
                                         completion: { heldDays = nil }) == true
        #else
        let flew = false
        #endif
        // The card leaves the deck now, while its answer saves, so the next card or the closing card moves up with it.
        withAnimation(LooprMotion.reducesMotion(reduceMotion) ? nil : LooprMotion.stateChange) { model.willAnswer(question) }
        Task {
            await model.answer(question, choice: choice)
            if !flew { heldDays = nil }
        }
    }

    private func undo() {
        haptic = .light
        heldDays = nil
        Task { await model.undo() }
    }
}

/// The Journal's comparisons and the mood calendar, one tap down from "How was your day?".
struct ProtocolJournalInsightsScreen: View {

    @ObservedObject var habits: HabitViewModel
    let day: DayIdentity

    var body: some View {
        LooprDetailScaffold(spacing: LooprSpacing.lg) {
            JournalInsightsSection(model: habits, day: day)
        }
        .navigationTitle("Mood and habit links")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("journal-insights-screen")
    }
}

/// The Rules segment's sheets and file importer (LV-07.4); its pushes go through `ProtocolRoute`. A file that arrives
/// from outside switches to Rules and opens its review or shows the validator's message.
private struct ProtocolRulesPresentations: ViewModifier {
    @ObservedObject var model: ProtocolTabModel
    @Binding var segment: ProtocolSegment
    @Binding var editing: ProtocolRuleEditing?
    @Binding var showsImporter: Bool
    @Binding var haptic: LooprHaptic?
    /// "Saved as version 3." with Undo, after the editor closes (ICP R1-HAB-19).
    @State private var notice: ProtocolSavedNotice?

    func body(content: Content) -> some View {
        content
            .looprToast(Binding(get: { notice?.toast }, set: { if $0 == nil { notice = nil } }), seconds: 8) {
                guard let shown = notice else { return }
                // After a new rule the action is "Add another" (ICP R3-HAB-08); otherwise it is Undo.
                if shown.addsAnother { notice = nil; editing = ProtocolRuleEditing(draft: .newRule()); return }
                Task { @MainActor in if let undone = await model.undoSave(shown) { notice = undone } }
            }
            .sheet(item: $editing) { item in
                ProtocolRuleEditor(model: model, draft: item.draft) { saved in
                    haptic = .ruleKept
                    notice = saved
                }
            }
            .sheet(isPresented: Binding(get: { model.importReview != nil }, set: { if !$0 { model.dismissImport() } })) {
                if let review = model.importReview {
                    ProtocolImportReviewSheet(model: model, review: review) { haptic = .ruleKept }
                }
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [ProtocolFileDocument.protocolType, .json]) { result in
                switch result {
                case .success(let url): model.openPickedFile(url)
                case .failure(let error): model.pickerFailed(error)
                }
            }
            .onChange(of: model.requestedSegment, initial: true) { _, requested in
                guard let requested else { return }
                segment = requested
                model.requestedSegment = nil
            }
            .task { await model.refreshReminders() }
    }
}
