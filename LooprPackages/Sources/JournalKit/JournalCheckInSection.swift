import SwiftUI
import DesignSystem
import DomainKit

public extension JournalFeeling {
    /// What 1 means on this scale.
    var lowEnd: String {
        switch self {
        case .mood: "Low"
        case .energy: "Drained"
        case .stress: "Calm"
        }
    }

    /// What 5 means on this scale.
    var highEnd: String {
        switch self {
        case .mood: "Good"
        case .energy: "Full of energy"
        case .stress: "Very stressed"
        }
    }

    /// "1 is low, 5 is good."
    var scaleHint: String { "1 is \(lowEnd.lowercased()), 5 is \(highEnd.lowercased())." }
}

/// The Journal's check-in on its own screen: how you feel, the questions about the day and the note. The Protocol tab
/// places the same three parts itself (`JournalFeelingSection`, `JournalQuestionsSection`, `JournalNoteSection`).
public struct JournalCheckInSection: View {
    @ObservedObject private var model: HabitViewModel
    private let day: DayIdentity
    private let entries: [JournalEntry]
    private let route: (JournalRoute) -> Void
    private let editNote: (JournalEntry?, Bool) -> Void

    public init(model: HabitViewModel, day: DayIdentity, entries: [JournalEntry],
                route: @escaping (JournalRoute) -> Void, editNote: @escaping (JournalEntry?, Bool) -> Void) {
        self.model = model; self.day = day; self.entries = entries; self.route = route; self.editNote = editNote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.lg) {
            if model.isLoading {
                LooprCard { StateMessage(.loading, compact: true) }
            }
            JournalFeelingSection(model: model, day: day)
            JournalQuestionsSection(model: model, day: day, route: route)
            JournalNoteSection(day: day, entries: entries, editNote: editNote)
            JournalErrorCard(model: model)
        }
        .disabled(model.isSavingCheckIn || model.isLoading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal-check-in")
    }
}

/// "How you feel": mood, energy and stress on a 1 to 5 scale with both ends named, and where it is sore.
public struct JournalFeelingSection<Accessory: View>: View {
    @ObservedObject private var model: HabitViewModel
    private let day: DayIdentity
    private let accessory: Accessory
    @State private var editingSoreness = false
    @State private var soreAreas = Set<JournalSoreness>()
    /// The person asked for Stress and Sore. They also show once either has an answer.
    @State private var showsMore = false

    public init(model: HabitViewModel, day: DayIdentity, @ViewBuilder accessory: () -> Accessory) {
        self.model = model; self.day = day; self.accessory = accessory()
    }

    private var wellbeing: JournalWellbeing { model.record(for: day)?.wellbeing ?? .init() }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                LooprSectionHeader("How you feel")
                accessory
            }
            LooprCard {
                // Mood and Energy every evening; Stress and Sore one tap away, so the check-in starts with two
                // questions, not four (UX R1-DES-04).
                VStack(alignment: .leading, spacing: LooprSpacing.md) {
                    scale(.mood)
                    scale(.energy)
                    if showsAll {
                        scale(.stress)
                        LooprHairline()
                        soreRow
                    } else {
                        Button {
                            withAnimation(LooprMotion.stateChange) { showsMore = true }
                        } label: {
                            HStack(spacing: LooprSpacing.xxs) {
                                LooprText("Add stress and soreness", style: .label, color: .protocolChip)
                                Spacer(minLength: 0)
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.loopr(.protocolChip))
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("journal-feelings-more")
                    }
                }
            }
        }
        .disabled(model.isSavingCheckIn || model.isLoading)
        .sheet(isPresented: $editingSoreness) { sorenessEditor }
    }

    private var showsAll: Bool { showsMore || wellbeing[.stress] != nil || wellbeing.soreness != nil }

    private func scale(_ feeling: JournalFeeling) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprText(feeling.rawValue, style: .rowTitle)
            LooprChoiceControl(feeling.rawValue, choices: JournalRating.allCases.map { LooprChoice(String($0.rawValue)) },
                selection: wellbeing[feeling].map { String($0.rawValue) }, accent: .cyclePlum,
                style: .rating, allowsClear: true, identifier: "journal-\(feeling.rawValue.lowercased())") { value in
                Task { await model.rate(feeling, value: value.flatMap(Int.init).flatMap(JournalRating.init(rawValue:)), day: day) }
            }
            .accessibilityHint(feeling.scaleHint)
            HStack {
                LooprText("1 \(feeling.lowEnd.lowercased())", style: .caption, color: .inkSecondary)
                Spacer(minLength: LooprSpacing.sm)
                LooprText("5 \(feeling.highEnd.lowercased())", style: .caption, color: .inkSecondary)
            }
            .accessibilityHidden(true)
        }
    }

    private var soreRow: some View {
        Button {
            soreAreas = wellbeing.soreness ?? []
            editingSoreness = true
        } label: {
            HStack(spacing: LooprSpacing.sm) {
                LooprText("Sore", style: .rowTitle)
                Spacer()
                if let value = wellbeing.soreness {
                    StatusChip(value.isEmpty ? "None" : value.map(\.rawValue).sorted().joined(separator: ", "), accent: .cyclePlum)
                } else { LooprText("Unanswered", style: .caption, color: .inkSecondary) }
                LooprChevron()
            }
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityIdentifier("journal-soreness")
    }

    private var sorenessEditor: some View {
        NavigationStack {
            LooprDetailScaffold {
                LooprCard {
                    VStack(spacing: LooprSpacing.none) {
                    ForEach(JournalSoreness.allCases, id: \.self) { area in
                        Toggle(area.rawValue, isOn: Binding(get: { soreAreas.contains(area) }, set: { value in
                            if value { soreAreas.insert(area) } else { soreAreas.remove(area) }
                        }))
                        .looprTypography(.rowTitle)
                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                        .accessibilityIdentifier("journal-sore-\(area.rawValue.lowercased())")
                    }
                    }
                }
                Button(soreAreas.isEmpty ? "Save no soreness" : "Save soreness") {
                    Task {
                        await model.setSoreness(soreAreas, day: day)
                        if model.errorMessage == nil { editingSoreness = false }
                    }
                }.buttonStyle(LooprButtonStyle(accent: .protocol)).accessibilityIdentifier("journal-soreness-save")
                Button("Clear answer") {
                    Task {
                        await model.setSoreness(nil, day: day)
                        if model.errorMessage == nil { editingSoreness = false }
                    }
                }.buttonStyle(LooprButtonStyle(prominent: false, accent: .protocol)).accessibilityIdentifier("journal-soreness-clear")
            }
            .navigationTitle("Soreness")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { editingSoreness = false }
                        .accessibilityIdentifier("journal-soreness-cancel")
                }
            }
        }
    }
}

public extension JournalFeelingSection where Accessory == EmptyView {
    init(model: HabitViewModel, day: DayIdentity) {
        self.init(model: model, day: day) { EmptyView() }
    }
}

/// Something to offer under a question once it is answered Yes, such as "Skip the rest of today" under "Feeling sick"
/// (ICP R2-HAB-02). `matches` picks the questions; `content` is drawn under each one answered Yes.
public struct JournalYesOffer {
    public let matches: @MainActor (HabitDefinition) -> Bool
    public let content: @MainActor () -> AnyView

    public init(matches: @escaping @MainActor (HabitDefinition) -> Bool, content: @escaping @MainActor () -> AnyView) {
        self.matches = matches; self.content = content
    }
}

/// The yes-or-no questions the Journal still asks: the ones about the day that did not become protocol rules. A
/// question that became a rule is answered and edited as a rule only, so it never shows here (ICP R1-UPG-1).
public struct JournalQuestionsSection: View {
    @ObservedObject private var model: HabitViewModel
    private let day: DayIdentity
    private let route: (JournalRoute) -> Void
    private let title: String
    /// Opens the protocol's rules. Nil leaves out the line that points there.
    private let openRules: (() -> Void)?
    /// A question this returns true for is left out, such as one that asks the same as a protocol rule (ICP R1-SEN-10).
    private let hides: ((HabitDefinition) -> Bool)?
    /// Drawn under a matching question answered Yes. Nil offers nothing.
    private let yesOffer: JournalYesOffer?
    /// True when the host asks about the evening of `day` itself, as the Protocol tab's evening sheet does: an evening
    /// question reads "This evening" and its answer is that day's (ICP R3-SEN-09). False keeps the Journal's morning
    /// check-in, where it reads "Yesterday evening" and the answer is the day before's.
    private let eveningIsSameDay: Bool
    /// The accent for the section's links and buttons: the brand teal in the Journal, `.protocol` in Protocol.
    private let accent: LooprColorToken
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The questions Food or Apple Health answered are shown, to check or override.
    @State private var showsAnswered = false

    public init(model: HabitViewModel, day: DayIdentity, route: @escaping (JournalRoute) -> Void,
                title: String = "Questions", openRules: (() -> Void)? = nil, hides: ((HabitDefinition) -> Bool)? = nil,
                yesOffer: JournalYesOffer? = nil, eveningIsSameDay: Bool = false, accent: LooprColorToken = .brand) {
        self.model = model; self.day = day; self.route = route; self.title = title; self.openRules = openRules
        self.hides = hides; self.yesOffer = yesOffer; self.eveningIsSameDay = eveningIsSameDay; self.accent = accent
    }

    public var body: some View {
        let asked = model.checkInDefinitions.filter { !(hides?($0) ?? false) }
        let hidden = model.checkInDefinitions.count - asked.count
        let evening = asked.filter { $0.checkInPeriod == .evening }
        let today = asked.filter { $0.checkInPeriod == .today }
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title)
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.none) {
                    if evening.isEmpty && today.isEmpty {
                        LooprText(hidden > 0 ? "Your rules already ask these questions."
                                  : model.ruleHabitIDs.isEmpty ? "No questions yet." : "Every question you had is a rule now.",
                                  style: .prose, color: .inkSecondary)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                    }
                    group(HabitQuestionPeriod.evening, evening, first: true)
                    group(HabitQuestionPeriod.today, today, first: evening.isEmpty)
                    if evening.isEmpty && today.isEmpty && model.ruleHabitIDs.isEmpty && hidden == 0 {
                        Button("Choose questions") { route(.habitSetup) }
                            .buttonStyle(LooprButtonStyle(prominent: false, accent: accent))
                            .accessibilityIdentifier("journal-choose-questions")
                    }
                }
            }
            if let openRules, !model.ruleHabitIDs.isEmpty {
                Button(action: openRules) {
                    HStack(spacing: LooprSpacing.xs) {
                        LooprText(rulesPointer, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LooprChevron()
                    }
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.looprPressableRow)
                .accessibilityIdentifier("journal-questions-rules")
            }
            LooprInlineAction("Edit questions", identifier: "journal-edit-questions", color: accent.textInk) { route(.habits) }
        }
        .disabled(model.isSavingCheckIn || model.isLoading)
    }

    private var rulesPointer: String {
        let count = model.ruleHabitIDs.count
        return count == 1 ? "1 of your habit questions is a rule now. You answer it on the check-in cards and edit it in Rules."
            : "\(count) of your habit questions are rules now. You answer them on the check-in cards and edit them in Rules."
    }

    @ViewBuilder
    private func group(_ period: HabitQuestionPeriod, _ definitions: [HabitDefinition], first: Bool) -> some View {
        if !definitions.isEmpty {
            if !first { LooprHairline() }
            LooprText(Self.periodTitle(period, eveningIsSameDay: eveningIsSameDay, isToday: day == model.currentDay),
                      style: .label, color: .inkSecondary)
                .padding(.top, first ? LooprSpacing.none : LooprSpacing.sm)
                .padding(.bottom, LooprSpacing.xxs)
                .accessibilityAddTraits(.isHeader)
            // Questions Food or Apple Health already answered fold into one line; the person answers only what is
            // open (UX R2-DES-14, R2-VET-09). A tap shows them, to check or override.
            let filled = definitions.filter(isAutoAnswered)
            let shown = showsAnswered ? definitions : definitions.filter { !isAutoAnswered($0) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, definition in
                question(definition)
                if let yesOffer, yesOffer.matches(definition), answer(definition) == .yes { yesOffer.content() }
                if index < shown.count - 1 { LooprHairline() }
            }
            if !filled.isEmpty && !showsAnswered {
                if !shown.isEmpty { LooprHairline() }
                Button {
                    withAnimation(LooprMotion.stateChange) { showsAnswered = true }
                } label: {
                    HStack(spacing: LooprSpacing.xs) {
                        LooprText(Self.answeredLine(filled.count, domains: filled.compactMap(autoFillDomain)),
                                  style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LooprText("Show", style: .label, color: .protocolChip)
                    }
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("journal-answered-\(period.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
            }
        }
    }

    private func answer(_ definition: HabitDefinition) -> HabitAnswer? {
        let answerDay = model.behaviorDay(for: definition.checkInPeriod, selectedDay: day, eveningIsSameDay: eveningIsSameDay)
        return model.record(for: answerDay)?.response(for: definition.id)?.answer
    }

    private func isAutoAnswered(_ definition: HabitDefinition) -> Bool {
        let answerDay = model.behaviorDay(for: definition.checkInPeriod, selectedDay: day, eveningIsSameDay: eveningIsSameDay)
        guard let response = model.record(for: answerDay)?.response(for: definition.id) else { return false }
        return response.lastUpdateSource == .autoFill && response.autoFillProvenance != nil && response.answer != nil
    }

    private func autoFillDomain(_ definition: HabitDefinition) -> String? {
        let answerDay = model.behaviorDay(for: definition.checkInPeriod, selectedDay: day, eveningIsSameDay: eveningIsSameDay)
        return model.record(for: answerDay)?.response(for: definition.id)?.autoFillProvenance?.domain.title
    }

    /// The label over a group of questions. The Journal's morning check-in asks about "Yesterday evening". A host that
    /// asks about the day's own evening says "This evening" for today and "That evening" for a past day.
    static func periodTitle(_ period: HabitQuestionPeriod, eveningIsSameDay: Bool, isToday: Bool) -> String {
        guard period == .evening, eveningIsSameDay else { return period.rawValue }
        return isToday ? "This evening" : "That evening"
    }

    /// "Food answered 2 for you", or "Food and Apple Health answered 3 for you".
    static func answeredLine(_ count: Int, domains: [String]) -> String {
        var unique: [String] = []
        for domain in domains where !unique.contains(domain) { unique.append(domain) }
        let who = unique.isEmpty ? "Your logs" : unique.count == 1 ? unique[0] : unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1]
        return "\(who) answered \(count) for you."
    }

    private func question(_ definition: HabitDefinition) -> some View {
        let answerDay = model.behaviorDay(for: definition.checkInPeriod, selectedDay: day, eveningIsSameDay: eveningIsSameDay)
        let record = model.record(for: answerDay)
        let response = record?.response(for: definition.id)
        let answer = response?.answer
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.xs))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.sm))
        return layout {
            VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                // Stored titles keep 24-hour times; the row follows the phone's clock, as Today does (UX R2-VET-05).
                LooprText(LooprClockFormat.localizing(definition.checkInTitle), style: .rowTitle)
                    .fixedSize(horizontal: false, vertical: true)
                if answer == .skipped { LooprText("Skipped", style: .caption, color: .inkSecondary) }
                if let provenance = response?.autoFillProvenance, response?.lastUpdateSource == .autoFill {
                    LooprText("From \(provenance.domain.title) · \(provenance.summary)".looprLabelCased, style: .confidence,
                        color: provenance.domain == .food ? .caution : .brandInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("journal-source-\(definition.id.rawValue.uuidString)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            LooprChoiceControl(definition.checkInTitle, choices: [LooprChoice("no", title: "No"), LooprChoice("yes", title: "Yes")],
                selection: answer == .skipped ? nil : answer?.rawValue, accent: .cyclePlum, allowsClear: true,
                identifier: "journal-answer-\(definition.id.rawValue.uuidString)") { value in
                Task {
                    await model.setCheckInAnswer(value.flatMap(HabitAnswer.init(rawValue:)), definition: definition, selectedDay: day,
                                                 eveningIsSameDay: eveningIsSameDay)
                }
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : LooprSpacing.interactiveRowHeight * 2 + LooprSpacing.sm)
        }
        .padding(.vertical, LooprSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityHint(record?.hasUserOverride(for: definition.id) == true
            ? (answer == nil ? "You cleared this answer. New logs won't fill it." : "Your answer overrides logged records.") : "")
    }
}

/// The note for the day: one place to read, write or dictate it, and the way to every older note.
public struct JournalNoteSection: View {
    private let day: DayIdentity
    private let entries: [JournalEntry]
    private let editNote: (JournalEntry?, Bool) -> Void
    /// Opens every note. Nil leaves out the header's action.
    private let openAll: (() -> Void)?

    public init(day: DayIdentity, entries: [JournalEntry], editNote: @escaping (JournalEntry?, Bool) -> Void,
                openAll: (() -> Void)? = nil) {
        self.day = day; self.entries = entries; self.editNote = editNote; self.openAll = openAll
    }

    private var note: JournalEntry? { entries.first { $0.day == day.habitKey } }

    public var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            if let openAll {
                LooprSectionHeader("Note", actionTitle: entries.isEmpty ? "Past notes" : "All \(entries.count)", accent: .protocol,
                                   identifier: "protocol-notes-header", actionIdentifier: "protocol-notes", action: openAll)
            } else {
                LooprSectionHeader("Note")
            }
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    Button { editNote(note, false) } label: {
                        LooprText(note?.note ?? "Add a note. It stays on this iPhone.", style: .prose,
                                  color: note == nil ? .inkSecondary : .ink)
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.looprPressableRow)
                    .accessibilityIdentifier("journal-check-in-note")
                    HStack(alignment: .center, spacing: LooprSpacing.sm) {
                        ViewThatFits(in: .horizontal) {
                            HStack { tags }
                            VStack(alignment: .leading) { tags }
                        }
                        Spacer()
                        LooprHeaderActionButton(action: .init(symbol: "mic", label: "Dictate a note",
                            identifier: "journal-dictate-note", run: { editNote(note, true) }))
                    }
                }
            }
        }
    }

    private var tags: some View {
        ForEach((note?.tags ?? []).sorted(), id: \.self) { StatusChip($0, accent: .brand) }
    }
}

/// A save that failed, in the Journal's words.
struct JournalErrorCard: View {
    @ObservedObject var model: HabitViewModel

    var body: some View {
        if let error = model.errorMessage {
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    StateMessage(.recoverableError, compact: true)
                    LooprText(error, style: .prose, color: .inkSecondary)
                }
            }
        }
    }
}
