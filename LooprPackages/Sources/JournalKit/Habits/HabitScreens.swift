import Foundation
import SwiftUI
import DesignSystem
import DomainKit

public struct HabitHomeSection: View {
    @ObservedObject private var viewModel: HabitViewModel
    private let route: (JournalRoute) -> Void

    public init(viewModel: HabitViewModel, route: @escaping (JournalRoute) -> Void) {
        self.viewModel = viewModel
        self.route = route
    }

    public var body: some View {
        if viewModel.settings.featureStage.exposesEntryPoints {
            LooprSectionGroup(title: "Habits") {
                if viewModel.isLoading {
                    LooprFormCard { StateMessage(.loading, compact: true) }
                } else if viewModel.activeDefinitions.isEmpty {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("Track daily habits and compare them with your next sleep and Recovery.", style: .prose, color: .inkSecondary)
                            Button("Choose habits") { route(.habitSetup) }
                                .buttonStyle(LooprPrimaryButtonStyle())
                                .accessibilityIdentifier("habit-choose")
                        }
                    }
                } else {
                    let day = viewModel.previousDay
                    let completion = viewModel.completion(for: day)
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            LooprText("YESTERDAY · \(completion.answered) OF \(completion.total) ANSWERED", style: .headerMeta, color: .inkSecondary)
                            ForEach(viewModel.activeDefinitions) { definition in
                                let answer = viewModel.record(for: day)?.response(for: definition.id)?.answer
                                HStack {
                                    LooprText(definition.name, style: .prose)
                                    Spacer()
                                    LooprText(answerLabel(answer), style: .confidence, color: .inkSecondary)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(definition.name), \(answerLabel(answer))")
                            }
                            Button(completion.answered == 0 ? "Start check-in" : "Continue check-in") { route(.checkIn(day)) }
                                .buttonStyle(LooprPrimaryButtonStyle())
                                .accessibilityIdentifier("habit-continue-check-in")
                        }
                    }
                    LooprMenuGroup(title: "Review", rows: [
                        LooprMenuItem(title: "Habit insights", value: nil, accessibilityIdentifier: "habit-insights", action: { route(.habitInsights) }),
                        LooprMenuItem(title: "History", value: nil, accessibilityIdentifier: "habit-history", action: { route(.habitHistory) }),
                        LooprMenuItem(title: "Manage habits", value: "\(viewModel.activeDefinitions.count) active", accessibilityIdentifier: "habit-manage", action: { route(.habits) })
                    ])
                }
            }
            .accessibilityIdentifier("habit-home-section")
        }
    }

    private func answerLabel(_ answer: HabitAnswer?) -> String {
        switch answer {
        case .yes: "Yes"
        case .no: "No"
        case .skipped: "Skipped"
        case nil: "Unanswered"
        }
    }
}

public struct HabitSetupScreen: View {
    @ObservedObject private var viewModel: HabitViewModel
    @State private var search = ""
    @State private var customName = ""
    @State private var customQuestion = ""
    @State private var showingCustom = false
    @State private var approvedLegacyIDs = Set<String>()
    @State private var pendingPreset: HabitCatalogItem?
    @State private var pendingCustom = false

    public init(viewModel: HabitViewModel) { self.viewModel = viewModel }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Choose habits") {
                LooprFormCard {
                    TextField("Search habits", text: $search)
                        .looprTypography(.prose)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("habit-search")
                }
                ForEach(HabitCategory.allCases, id: \.self) { category in
                    let items = HabitCatalog.search(search).filter { $0.category == category }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText(category.rawValue.uppercased(), style: .confidence, color: .inkSecondary)
                                .accessibilityLabel(category.rawValue)
                                .accessibilityAddTraits(.isHeader)
                            LooprFormCard(padding: LooprSpacing.none) {
                                VStack(spacing: LooprSpacing.none) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                        Button {
                                            if viewModel.activeDefinitions.count >= HabitStoreValidator.activeLimit {
                                                pendingPreset = item
                                            } else {
                                                Task { await viewModel.addPreset(item) }
                                            }
                                        } label: {
                                            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                                                VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                                                    LooprText(item.name, style: .prose)
                                                    LooprText(item.question, style: .caption, color: .inkSecondary)
                                                }
                                                Spacer()
                                                Image(systemName: selected(item) ? "checkmark.circle.fill" : "plus.circle")
                                                    .looprTypography(.rowTitle)
                                                    .foregroundStyle(Color.loopr(.brand))
                                                    .accessibilityHidden(true)
                                            }
                                            .padding(LooprSpacing.formCardPadding)
                                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(selected(item))
                                        .accessibilityLabel("\(item.name). \(item.question). \(selected(item) ? "Selected" : "Add habit")")
                                        .accessibilityIdentifier("habit-preset-\(item.id)")
                                        if index < items.count - 1 { LooprHairline() }
                                    }
                                }
                            }
                        }
                    }
                }
                if HabitCatalog.search(search).isEmpty {
                    LooprFormCard { StateMessage(.noRecords) }
                }
            }

            LooprSectionGroup(title: "Custom") {
                Button("Create custom habit") { showingCustom.toggle() }
                    .buttonStyle(LooprButtonStyle(prominent: false))
                if showingCustom {
                    LooprFormCard {
                        VStack(spacing: LooprSpacing.sm) {
                            TextField("Habit name", text: $customName)
                                .looprTypography(.prose)
                                .accessibilityIdentifier("habit-custom-name")
                            TextField("Yes or No question", text: $customQuestion)
                                .looprTypography(.prose)
                                .accessibilityIdentifier("habit-custom-question")
                            Button("Add habit") {
                                if viewModel.activeDefinitions.count >= HabitStoreValidator.activeLimit {
                                    pendingCustom = true
                                } else {
                                    addCustom()
                                }
                            }
                            .buttonStyle(LooprPrimaryButtonStyle())
                            .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || customQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("habit-custom-save")
                        }
                    }
                }
            }

            if !viewModel.migrationSuggestions.isEmpty {
                LooprSectionGroup(title: "From your journal") {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprText("Choose old tags to keep as history. Loopr will not treat missing tags as No answers.", style: .prose, color: .inkSecondary)
                            ForEach(viewModel.migrationSuggestions) { suggestion in
                                Toggle(suggestion.displayText, isOn: Binding(
                                    get: { approvedLegacyIDs.contains(suggestion.id) },
                                    set: { selected in
                                        if selected { approvedLegacyIDs.insert(suggestion.id) }
                                        else { approvedLegacyIDs.remove(suggestion.id) }
                                    }
                                ))
                                .looprTypography(.prose)
                                .accessibilityIdentifier("habit-migration-\(suggestion.id)")
                            }
                            Button(approvedLegacyIDs.isEmpty ? "Skip old tags" : "Add selected history") {
                                Task { await viewModel.completeMigration(approvedSuggestionIDs: approvedLegacyIDs) }
                            }
                            .buttonStyle(LooprButtonStyle(prominent: false))
                            .accessibilityIdentifier("habit-migration-complete")
                        }
                    }
                }
            }

            if HabitCatalog.hasNearDuplicate(in: selectedCatalogIDs) {
                LooprFormCard {
                    LooprInlineMessage(
                        "These habits overlap. Log days when only one happens so Loopr can separate them.",
                        tone: .warning
                    )
                }
            }

            errorCard
        }
        .navigationTitle("Choose habits")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .confirmationDialog(
            "Archive one active habit",
            isPresented: Binding(
                get: { pendingPreset != nil || pendingCustom },
                set: { if !$0 { pendingPreset = nil; pendingCustom = false } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(viewModel.activeDefinitions) { definition in
                Button("Archive \(definition.name)") { archiveThenAdd(definition) }
            }
            Button("Cancel", role: .cancel) { pendingPreset = nil; pendingCustom = false }
        } message: {
            Text("You can keep up to 10 habits active. Archived habits keep their history and insights.")
        }
        .accessibilityIdentifier("habit-setup-screen")
    }

    private var selectedCatalogIDs: Set<String> {
        Set(viewModel.definitions.compactMap {
            if case .preset(let catalogID) = $0.source { return catalogID }
            return nil
        })
    }

    private func selected(_ item: HabitCatalogItem) -> Bool { selectedCatalogIDs.contains(item.id) }

    private func addCustom() {
        Task {
            await viewModel.createCustom(name: customName, question: customQuestion)
            if viewModel.errorMessage == nil {
                customName = ""
                customQuestion = ""
                showingCustom = false
            }
        }
    }

    private func archiveThenAdd(_ definition: HabitDefinition) {
        let preset = pendingPreset
        let shouldAddCustom = pendingCustom
        pendingPreset = nil
        pendingCustom = false
        Task {
            await viewModel.setArchived(true, definition: definition)
            guard viewModel.errorMessage == nil else { return }
            if let preset { await viewModel.addPreset(preset) }
            if shouldAddCustom { addCustom() }
        }
    }

    @ViewBuilder private var errorCard: some View {
        if let error = viewModel.errorMessage {
            HabitErrorCard(message: error)
        }
    }
}

public struct HabitManagementScreen: View {
    @ObservedObject private var viewModel: HabitViewModel
    @State private var pendingDelete: HabitDefinition?
    @State private var editing: HabitDefinition?
    @State private var editName = ""
    @State private var editQuestion = ""

    public init(viewModel: HabitViewModel) { self.viewModel = viewModel }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Reminder") {
                LooprFormCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        Toggle("Habit check-in reminder", isOn: Binding(
                            get: { viewModel.settings.reminderEnabled },
                            set: { enabled in
                                Task { await viewModel.updateReminder(enabled: enabled, hour: viewModel.settings.reminderHour, minute: viewModel.settings.reminderMinute) }
                            }
                        ))
                        .looprTypography(.prose)
                        LooprText("Off by default. Lock-screen text never names a habit.", style: .caption, color: .inkSecondary)
                        if viewModel.settings.reminderEnabled {
                            DatePicker(
                                "Reminder time",
                                selection: reminderTime,
                                displayedComponents: .hourAndMinute
                            )
                            .looprTypography(.prose)
                        }
                    }
                }
            }
            LooprSectionGroup(title: "Active") { definitionList(viewModel.activeDefinitions) }
            if viewModel.definitions.contains(where: \.isArchived) {
                LooprSectionGroup(title: "Archived") { definitionList(viewModel.definitions.filter(\.isArchived)) }
            }
            errorCard
        }
        .navigationTitle("Manage habits")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .confirmationDialog("Delete this habit and its history?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete habit", role: .destructive) {
                if let pendingDelete { Task { await viewModel.delete(pendingDelete) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes every saved answer and cached insight for the habit.")
        }
        .sheet(item: $editing) { definition in
            NavigationStack {
                LooprDetailScaffold {
                    LooprSectionGroup(title: "Habit") {
                        LooprFormCard {
                            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                                TextField("Habit name", text: $editName)
                                    .looprTypography(.prose)
                                    .accessibilityIdentifier("habit-edit-name")
                                LooprHairline()
                                TextField("Yes or No question", text: $editQuestion)
                                    .looprTypography(.prose)
                                    .accessibilityIdentifier("habit-edit-question")
                            }
                        }
                    }
                    Button("Save changes") {
                        Task {
                            await viewModel.rename(definition, name: editName, question: editQuestion)
                            if viewModel.errorMessage == nil { editing = nil }
                        }
                    }
                    .buttonStyle(LooprPrimaryButtonStyle())
                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("habit-edit-save")
                }
                .navigationTitle("Rename habit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editing = nil }
                    }
                }
            }
        }
        .accessibilityIdentifier("habit-management-screen")
    }

    private func definitionList(_ definitions: [HabitDefinition]) -> some View {
        LooprFormCard(padding: LooprSpacing.none) {
            VStack(spacing: LooprSpacing.none) {
                ForEach(Array(definitions.enumerated()), id: \.element.id) { index, definition in
                    HStack {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText(definition.name, style: .prose)
                            LooprText(definition.question, style: .caption, color: .inkSecondary)
                        }
                        Spacer()
                        Menu {
                            Button("Rename") {
                                editName = definition.name
                                editQuestion = definition.question
                                editing = definition
                            }
                            Button(definition.isArchived ? "Reactivate" : "Archive") {
                                Task { await viewModel.setArchived(!definition.isArchived, definition: definition) }
                            }
                            Button("Delete", role: .destructive) { pendingDelete = definition }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .looprTypography(.rowTitle)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                        }
                        .accessibilityLabel("Actions for \(definition.name)")
                    }
                    .padding(LooprSpacing.formCardPadding)
                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("habit-manage-\(definition.id.rawValue.uuidString)")
                    if index < definitions.count - 1 { LooprHairline() }
                }
            }
        }
    }

    @ViewBuilder private var errorCard: some View {
        if let error = viewModel.errorMessage { HabitErrorCard(message: error) }
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: viewModel.settings.reminderHour, minute: viewModel.settings.reminderMinute)) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                Task {
                    await viewModel.updateReminder(
                        enabled: true,
                        hour: components.hour ?? 9,
                        minute: components.minute ?? 0
                    )
                }
            }
        )
    }
}

public struct HabitCheckInScreen: View {
    @ObservedObject private var viewModel: HabitViewModel
    public let day: DayIdentity
    /// A tick for each saved answer and a success tap for a finished check-in.
    @State private var haptic: LooprHaptic?

    public init(viewModel: HabitViewModel, day: DayIdentity) { self.viewModel = viewModel; self.day = day }

    public var body: some View {
        LooprDetailScaffold {
            let completion = viewModel.completion(for: day)
            LooprSectionGroup(title: HabitCalendarText.fullDate(day)) {
                LooprSurface(emphasis: .hero(.brand)) {
                    HStack(alignment: .center, spacing: LooprSpacing.sm) {
                        VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                            LooprText("Daily check-in", style: .cardTitle)
                            LooprText("Answers save as soon as you tap them.", style: .prose, color: .inkSecondary)
                        }
                        Spacer(minLength: LooprSpacing.sm)
                        StatusChip(
                            "\(completion.answered) of \(completion.total)",
                            symbol: completion.answered == completion.total ? "checkmark.circle.fill" : "circle.dotted",
                            tone: completion.answered == completion.total ? .positive : .brand
                        )
                    }
                }
                if viewModel.activeDefinitions.isEmpty {
                    LooprFormCard { StateMessage(.noRecords) }
                } else {
                    ForEach(viewModel.activeDefinitions) { definition in
                        LooprFormCard {
                            VStack(alignment: .leading, spacing: LooprSpacing.md) {
                                LooprText(definition.question, style: .prose)
                                HStack(spacing: LooprSpacing.sm) {
                                    answerButton("Yes", .yes, definition)
                                    answerButton("No", .no, definition)
                                    answerButton("Skip", .skipped, definition)
                                }
                                if let response = viewModel.record(for: day)?.response(for: definition.id),
                                   let reason = HabitEligibility.exclusion(for: response) {
                                    LooprInlineMessage(exclusionText(reason), tone: .warning)
                                }
                            }
                        }
                    }
                }
            }
            Button("Finish check-in") {
                Task {
                    await viewModel.finish(day: day)
                    haptic = viewModel.errorMessage == nil ? .success : .error
                }
            }
                .buttonStyle(LooprPrimaryButtonStyle())
                .accessibilityIdentifier("habit-finish-check-in")
            if let error = viewModel.errorMessage { HabitErrorCard(message: error) }
        }
        .navigationTitle("Habit check-in")
        .navigationBarTitleDisplayMode(.inline)
        .looprHaptic(haptic)
        .task { await viewModel.load() }
        .accessibilityIdentifier("habit-check-in-screen")
    }

    private func answerButton(_ title: String, _ answer: HabitAnswer, _ definition: HabitDefinition) -> some View {
        let selected = viewModel.record(for: day)?.response(for: definition.id)?.answer == answer
        return Button(title) {
            Task {
                await viewModel.answer(answer, habitID: definition.id, day: day, source: day == viewModel.currentDay ? .sameDay : .morningCheckIn)
                haptic = viewModel.errorMessage == nil ? LooprHaptic(.selection) : .error
            }
        }
        .buttonStyle(LooprButtonStyle(prominent: selected))
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("habit-answer-\(definition.id.rawValue.uuidString)-\(answer.rawValue)")
    }

    private func exclusionText(_ reason: HabitExclusionReason) -> String {
        switch reason {
        case .lateFirstEntry: "Not used in insights: this answer was first saved after the editing deadline."
        case .skipped: "Skipped answers stay in history and are not used in insights."
        case .legacyPresence: "Imported history is not used in insights."
        default: "This answer is not used in insights."
        }
    }
}

public struct HabitHistoryScreen: View {
    @ObservedObject private var viewModel: HabitViewModel
    private let route: (JournalRoute) -> Void
    @State private var monthOffset = 0
    @State private var selectedDay: DayIdentity?

    public init(viewModel: HabitViewModel, route: @escaping (JournalRoute) -> Void) { self.viewModel = viewModel; self.route = route }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: monthTitle) {
                LooprFormCard {
                    VStack(spacing: LooprSpacing.sm) {
                        HStack {
                            Button("Previous month", systemImage: "chevron.left") { monthOffset -= 1 }
                                .labelStyle(.iconOnly)
                                .frame(minWidth: LooprSpacing.formButtonHeight, minHeight: LooprSpacing.formButtonHeight)
                                .foregroundStyle(Color.loopr(.brand))
                                .accessibilityIdentifier("habit-history-previous-month")
                            Spacer()
                            LooprText(monthTitle, style: .rowTitle)
                            Spacer()
                            Button("Next month", systemImage: "chevron.right") { monthOffset += 1 }
                                .labelStyle(.iconOnly)
                                .frame(minWidth: LooprSpacing.formButtonHeight, minHeight: LooprSpacing.formButtonHeight)
                                .foregroundStyle(Color.loopr(.brand))
                                .disabled(monthOffset >= 0)
                                .accessibilityIdentifier("habit-history-next-month")
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: LooprSpacing.xs) {
                            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) {
                                LooprText($0.element, style: .caption, color: .inkSecondary)
                            }
                            ForEach(0..<calendarCellCount, id: \.self) { index in
                                if let day = dayForCell(index) {
                                    Button { selectedDay = day } label: {
                                        VStack(spacing: LooprSpacing.xxs) {
                                            LooprText("\(day.day)", style: .caption)
                                            Image(systemName: marker(for: day))
                                                .looprTypography(.confidence)
                                                .foregroundStyle(Color.loopr(markerColor(for: day)))
                                                .accessibilityHidden(true)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                                        .background(
                                            Color.loopr(.brandSoft).opacity(selectedDay == day ? 1 : 0),
                                            in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(day.habitKey), \(dayStatus(viewModel.record(for: day)))")
                                    .accessibilityAddTraits(selectedDay == day ? .isSelected : [])
                                } else {
                                    Spacer().frame(minHeight: LooprSpacing.formButtonHeight)
                                }
                            }
                        }
                        calendarLegend
                    }
                }
            }

            if let selectedDay {
                LooprSectionGroup(title: HabitCalendarText.fullDate(selectedDay)) {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprText(dayStatus(viewModel.record(for: selectedDay)), style: .prose)
                            Button("Review answers") { route(.checkIn(selectedDay)) }
                                .buttonStyle(LooprButtonStyle(prominent: false))
                        }
                    }
                }
            }

            LooprSectionGroup(title: "Saved days") {
                if viewModel.records.isEmpty {
                    LooprFormCard { StateMessage(.noRecords) }
                } else {
                    LooprFormCard(padding: LooprSpacing.none) {
                        VStack(spacing: LooprSpacing.none) {
                            ForEach(Array(viewModel.records.reversed().enumerated()), id: \.element.id) { index, record in
                                Button { route(.checkIn(record.behaviorDay)) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                                            LooprText(HabitCalendarText.fullDate(record.behaviorDay), style: .prose)
                                            LooprText(dayStatus(record), style: .caption, color: .inkSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(Color.loopr(.inkSecondary))
                                            .accessibilityHidden(true)
                                    }
                                    .padding(LooprSpacing.formCardPadding)
                                    .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(HabitCalendarText.fullDate(record.behaviorDay)), \(dayStatus(record)), opens answers")
                                if index < viewModel.records.count - 1 { LooprHairline() }
                            }
                        }
                    }
                }
            }
            if let error = viewModel.errorMessage { HabitErrorCard(message: error) }
        }
        .navigationTitle("Habit history")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .accessibilityIdentifier("habit-history-screen")
    }

    private func dayStatus(_ record: HabitDayRecord) -> String {
        let activeIDs = Set(viewModel.activeDefinitions.map(\.id))
        let answers = record.responses.filter { activeIDs.contains($0.habitID) }
        if answers.isEmpty { return "Empty" }
        if answers.allSatisfy({ $0.answer == .skipped }) { return "Skipped" }
        if record.completedAt != nil { return "Complete, \(answers.count) saved" }
        return "Partial, \(answers.count) saved"
    }

    private func dayStatus(_ record: HabitDayRecord?) -> String {
        guard let record else { return "Empty" }
        return dayStatus(record)
    }

    private var visibleMonth: Date {
        let anchor = HabitCalendarText.date(viewModel.currentDay) ?? Date()
        return Calendar.current.date(byAdding: .month, value: monthOffset, to: anchor) ?? anchor
    }

    private var monthTitle: String { visibleMonth.formatted(.dateTime.month(.wide).year()) }

    private var calendarCellCount: Int {
        guard let range = Calendar.current.range(of: .day, in: .month, for: visibleMonth) else { return 35 }
        let occupiedCells = firstWeekdayOffset + range.count
        return ((occupiedCells + 6) / 7) * 7
    }

    private var firstWeekdayOffset: Int {
        let components = Calendar.current.dateComponents([.year, .month], from: visibleMonth)
        guard let first = Calendar.current.date(from: components) else { return 0 }
        let weekday = Calendar.current.component(.weekday, from: first)
        return (weekday - Calendar.current.firstWeekday + 7) % 7
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let offset = max(0, Calendar.current.firstWeekday - 1)
        return Array(symbols[offset...] + symbols[..<offset])
    }

    private func dayForCell(_ index: Int) -> DayIdentity? {
        let number = index - firstWeekdayOffset + 1
        guard let range = Calendar.current.range(of: .day, in: .month, for: visibleMonth), range.contains(number) else { return nil }
        let components = Calendar.current.dateComponents([.era, .year, .month], from: visibleMonth)
        guard let year = components.year, let month = components.month else { return nil }
        return DayIdentity(era: components.era ?? 1, year: year, month: month, day: number)
    }

    private func marker(for day: DayIdentity) -> String {
        guard let record = viewModel.record(for: day) else { return "circle" }
        let activeIDs = Set(viewModel.activeDefinitions.map(\.id))
        let answers = record.responses.filter { activeIDs.contains($0.habitID) }
        if !answers.isEmpty, answers.allSatisfy({ $0.answer == .skipped }) { return "minus.circle.fill" }
        if record.completedAt != nil { return "checkmark.circle.fill" }
        return "circle.lefthalf.filled"
    }

    private func markerColor(for day: DayIdentity) -> LooprColorToken {
        guard let record = viewModel.record(for: day) else { return .inkMuted }
        let activeIDs = Set(viewModel.activeDefinitions.map(\.id))
        let answers = record.responses.filter { activeIDs.contains($0.habitID) }
        if !answers.isEmpty, answers.allSatisfy({ $0.answer == .skipped }) { return .inkSecondary }
        if record.completedAt != nil { return .brand }
        return .strain
    }

    private var calendarLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LooprSpacing.md) {
                legendItem("Complete", symbol: "checkmark.circle.fill", color: .brand)
                legendItem("Partial", symbol: "circle.lefthalf.filled", color: .strain)
                legendItem("Skipped", symbol: "minus.circle.fill", color: .inkSecondary)
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                legendItem("Complete", symbol: "checkmark.circle.fill", color: .brand)
                legendItem("Partial", symbol: "circle.lefthalf.filled", color: .strain)
                legendItem("Skipped", symbol: "minus.circle.fill", color: .inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendItem(_ title: String, symbol: String, color: LooprColorToken) -> some View {
        Label(title, systemImage: symbol)
            .looprTypography(.confidence)
            .foregroundStyle(Color.loopr(color))
    }
}

public struct HabitInsightsScreen: View {
    @ObservedObject private var viewModel: HabitViewModel
    private let route: (JournalRoute) -> Void

    public init(viewModel: HabitViewModel, route: @escaping (JournalRoute) -> Void) { self.viewModel = viewModel; self.route = route }

    public var body: some View {
        LooprDetailScaffold {
            LooprSectionGroup(title: "Past 90 days") {
                if activeEstimates.isEmpty {
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StateMessage(.noRecords, compact: true)
                            LooprText("Answer each habit with both Yes and No to build a comparison.", style: .prose, color: .inkSecondary)
                        }
                    }
                } else {
                    insightList(activeEstimates)
                }
            }
            if !archivedEstimates.isEmpty {
                LooprSectionGroup(title: "Archived") {
                    insightList(archivedEstimates)
                }
            }
            if let error = viewModel.errorMessage { HabitErrorCard(message: error) }
        }
        .navigationTitle("Habit insights")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .accessibilityIdentifier("habit-insights-screen")
    }

    private var activeEstimates: [HabitImpactEstimate] {
        viewModel.estimates.filter { viewModel.definition(for: $0.habitID)?.isArchived == false }
    }

    private var archivedEstimates: [HabitImpactEstimate] {
        viewModel.estimates.filter { viewModel.definition(for: $0.habitID)?.isArchived == true }
    }

    @ViewBuilder
    private func insightList(_ estimates: [HabitImpactEstimate]) -> some View {
        ForEach(estimates) { estimate in
            if let definition = viewModel.definition(for: estimate.habitID) {
                let presentation = presentation(for: estimate)
                Button { route(.habitDetail(estimate.habitID)) } label: {
                    LooprSurface(emphasis: presentation.emphasis) {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            StatusChip(
                                presentation.chipLabel,
                                symbol: presentation.symbol,
                                tone: presentation.tone
                            )
                            LooprText(definition.name, style: .cardTitle)
                            LooprText(presentation.detail, style: .prose, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.sm) {
                                LooprText(presentation.counts.uppercased(), style: .confidence, color: .inkSecondary)
                                Spacer(minLength: LooprSpacing.sm)
                                Image(systemName: "chevron.right")
                                    .looprTypography(.metricUnit)
                                    .foregroundStyle(Color.loopr(.inkSecondary))
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(definition.name). \(presentation.chipLabel). \(presentation.detail). \(presentation.counts). Opens details.")
                .accessibilityIdentifier("habit-insight-\(estimate.habitID.rawValue.uuidString)")
            }
        }
    }

    private func presentation(for estimate: HabitImpactEstimate) -> HabitInsightPresentation {
        HabitInsightPresentation(
            estimate: estimate,
            overlappingHabitName: estimate.overlappingHabitID.flatMap { viewModel.definition(for: $0)?.name }
        )
    }
}

public struct HabitDetailScreen: View {
    @ObservedObject private var viewModel: HabitViewModel
    public let habitID: HabitID

    public init(viewModel: HabitViewModel, habitID: HabitID) { self.viewModel = viewModel; self.habitID = habitID }

    public var body: some View {
        LooprDetailScaffold {
            if viewModel.definition(for: habitID) != nil, let estimate = viewModel.estimate(for: habitID) {
                let presentation = HabitInsightPresentation(
                    estimate: estimate,
                    overlappingHabitName: estimate.overlappingHabitID.flatMap { viewModel.definition(for: $0)?.name }
                )
                LooprSectionGroup(title: "Summary") {
                    LooprSurface(emphasis: presentation.emphasis) {
                        VStack(alignment: .leading, spacing: LooprSpacing.md) {
                            StatusChip(
                                presentation.chipLabel,
                                symbol: presentation.symbol,
                                tone: presentation.tone
                            )
                            LooprText(detailHeadline(estimate, fallback: presentation.detail), style: .cardTitle)
                                .fixedSize(horizontal: false, vertical: true)
                            LooprText(presentation.counts.uppercased(), style: .confidence, color: .inkSecondary)
                            LooprHairline()
                            LooprText("This is an observed association. Other habits and changes in your routine may explain some or all of it.", style: .prose, color: .inkSecondary)
                        }
                    }
                }

                if let recovery = estimate.metric(.recoveryScore) {
                    metricDetails(recovery)
                }

                let secondaryMetrics = HabitOutcomeMetricID.allCases
                    .filter { $0 != .recoveryScore }
                    .compactMap { estimate.metric($0) }
                if !secondaryMetrics.isEmpty {
                    LooprSectionGroup(title: "Other metrics") {
                        ForEach(secondaryMetrics, id: \.metricID) { metric in
                            metricDetails(metric, includesSection: false)
                        }
                    }
                }

                LooprSectionGroup(title: "Answer history") {
                    HabitAnswerCalendar(
                        habitID: habitID,
                        records: viewModel.records,
                        start: estimate.windowStart,
                        end: estimate.windowEnd
                    )
                }

                LooprSectionGroup(title: "Calculation") {
                    HairlineMetricList(rows: calculationRows(estimate))
                    LooprFormCard {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprText("Loopr adjusts for your recent baseline, weekday, prior-day Strain, and other tracked habits.", style: .prose, color: .inkSecondary)
                            LooprText("CALCULATED \(estimate.calculatedAt.formatted(date: .abbreviated, time: .shortened).uppercased())", style: .confidence, color: .inkSecondary)
                            LooprText(estimate.algorithmVersion.uppercased(), style: .confidence, color: .inkSecondary)
                        }
                    }
                }

                if !estimate.exclusions.isEmpty {
                    LooprSectionGroup(title: "Excluded days") {
                        HairlineMetricList(rows: exclusionRows(estimate))
                    }
                }
            } else if viewModel.isLoading {
                LooprFormCard { StateMessage(.loading) }
            } else {
                LooprFormCard { StateMessage(.noRecords) }
            }
            if let error = viewModel.errorMessage { HabitErrorCard(message: error) }
        }
        .navigationTitle(viewModel.definition(for: habitID)?.name ?? "Habit insight")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .accessibilityIdentifier("habit-detail-screen")
    }

    @ViewBuilder
    private func metricDetails(_ metric: HabitMetricEstimate, includesSection: Bool = true) -> some View {
        let rows = HabitMetricText.rows(metric)
        if includesSection {
            LooprSectionGroup(title: metric.metricID.title) {
                HairlineMetricList(rows: rows)
            }
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprText(metric.metricID.title.uppercased(), style: .confidence, color: .inkSecondary)
                    .accessibilityLabel(metric.metricID.title)
                    .accessibilityAddTraits(.isHeader)
                HairlineMetricList(rows: rows)
            }
        }
    }

    private func detailHeadline(_ estimate: HabitImpactEstimate, fallback: String) -> String {
        guard estimate.status == .noClearAssociation,
              let secondary = HabitOutcomeMetricID.allCases
                .filter({ $0 != .recoveryScore })
                .compactMap({ estimate.metric($0) })
                .first(where: { $0.isClear && $0.adjustedDifference != nil }),
              let effect = secondary.adjustedDifference else { return fallback }
        return "No clear Recovery association. \(HabitMetricText.effectSentence(effect, metric: secondary.metricID))"
    }

    private func calculationRows(_ estimate: HabitImpactEstimate) -> [HairlineMetricRow] {
        [
            HairlineMetricRow(
                title: "Comparison period",
                value: HabitCalendarText.range(estimate.windowStart, estimate.windowEnd)
            ),
            HairlineMetricRow(title: "Yes answers", value: "\(estimate.yesCount)", unit: "days"),
            HairlineMetricRow(title: "No answers", value: "\(estimate.noCount)", unit: "days"),
            HairlineMetricRow(title: "Eligible days", value: "\(estimate.eligibleDayCount)", unit: "days"),
            HairlineMetricRow(title: "Excluded days", value: "\(estimate.excludedDayCount)", unit: "days")
        ]
    }

    private func exclusionRows(_ estimate: HabitImpactEstimate) -> [HairlineMetricRow] {
        Dictionary(grouping: estimate.exclusions, by: \.reason)
            .map { reason, rows in
                HairlineMetricRow(
                    id: reason.rawValue,
                    title: HabitExclusionText.label(reason),
                    value: "\(rows.count)",
                    unit: rows.count == 1 ? "day" : "days"
                )
            }
            .sorted { $0.title < $1.title }
    }
}

private struct HabitInsightPresentation {
    let chipLabel: String
    let symbol: String
    let tone: ChipTone
    let emphasis: SurfaceEmphasis
    let detail: String
    let counts: String

    init(estimate: HabitImpactEstimate, overlappingHabitName: String?) {
        counts = if estimate.status == .collecting {
            "\(min(estimate.yesCount, HabitImpactPolicy.default.earlyPerGroup)) of \(HabitImpactPolicy.default.earlyPerGroup) Yes · \(min(estimate.noCount, HabitImpactPolicy.default.earlyPerGroup)) of \(HabitImpactPolicy.default.earlyPerGroup) No"
        } else {
            "\(estimate.yesCount) Yes · \(estimate.noCount) No · \(estimate.eligibleDayCount) eligible"
        }

        switch estimate.status {
        case .collecting:
            chipLabel = "Collecting"
            symbol = "circle.dotted"
            tone = .brand
            emphasis = .standard
            detail = "Keep logging both Yes and No days. Loopr needs at least five of each before it shows an early comparison."
        case .earlySignal:
            chipLabel = "Early signal"
            symbol = "chart.line.uptrend.xyaxis"
            tone = .warning
            emphasis = .standard
            if let raw = estimate.metric(.recoveryScore)?.rawDifference {
                detail = "Small sample. \(HabitMetricText.effectSentence(raw, metric: .recoveryScore, prefix: "Recovery averaged"))"
            } else {
                detail = "There are enough answers for an early comparison, but the sample is still small."
            }
        case .enoughData:
            chipLabel = "Calculating"
            symbol = "clock.arrow.circlepath"
            tone = .brand
            emphasis = .standard
            detail = "There are enough eligible days. Loopr is calculating the uncertainty around the comparison."
        case .clearAssociation:
            chipLabel = "Clear association"
            symbol = "waveform.path.ecg"
            tone = .positive
            emphasis = .hero(.brand)
            if let effect = estimate.metric(.recoveryScore)?.adjustedDifference {
                detail = HabitMetricText.effectSentence(effect, metric: .recoveryScore)
            } else {
                detail = "Your current data shows a clear association. Open the detail view to review the metric."
            }
        case .noClearAssociation:
            chipLabel = "No clear result"
            symbol = "equal.circle"
            tone = .neutral
            emphasis = .standard
            detail = "Your current data does not show a clear Recovery association."
        case .cannotSeparate:
            chipLabel = "Cannot separate"
            symbol = "link"
            tone = .warning
            emphasis = .standard
            let name = overlappingHabitName ?? "another tracked habit"
            detail = "This habit usually occurs with \(name). Log days when only one happens so Loopr can separate them."
        case .stale:
            chipLabel = "Out of date"
            symbol = "clock.badge.exclamationmark"
            tone = .warning
            emphasis = .standard
            if let last = estimate.lastValidEstimate,
               let effect = last.recovery.adjustedDifference {
                detail = "Last clear result through \(HabitCalendarText.shortDate(last.validThrough)): \(HabitMetricText.effectSentence(effect, metric: .recoveryScore, prefix: "Recovery was")) Keep logging to refresh it."
            } else {
                detail = "The current 90-day window no longer has enough contrasting days. Keep logging to refresh the result."
            }
        case .unavailable:
            chipLabel = "Unavailable"
            symbol = "moon.zzz"
            tone = .neutral
            emphasis = .standard
            detail = HabitExclusionText.unavailableDetail(estimate.exclusions.first?.reason)
        }
    }
}

private enum HabitMetricText {
    static func rows(_ metric: HabitMetricEstimate) -> [HairlineMetricRow] {
        [
            row("Yes average", value: metric.yesMean, metric: metric.metricID),
            row("No average", value: metric.noMean, metric: metric.metricID),
            row("Raw difference", value: metric.rawDifference, metric: metric.metricID, signed: true),
            row("Adjusted difference", value: metric.adjustedDifference, metric: metric.metricID, signed: true),
            intervalRow(metric)
        ]
    }

    static func effectSentence(
        _ effect: Double,
        metric: HabitOutcomeMetricID,
        prefix: String? = nil
    ) -> String {
        let subject = prefix ?? "\(metric.title) was"
        let direction: String
        if metric == .sleepDuration {
            direction = effect < 0 ? "shorter" : "longer"
        } else {
            direction = effect < 0 ? "lower" : "higher"
        }
        return "\(subject) \(number(abs(effect))) \(unit(metric.unit)) \(direction) on nights you answered Yes."
    }

    private static func row(
        _ title: String,
        value: Double?,
        metric: HabitOutcomeMetricID,
        signed: Bool = false
    ) -> HairlineMetricRow {
        guard let value else { return HairlineMetricRow(title: title, value: "Not measured") }
        return HairlineMetricRow(
            title: title,
            value: signed ? signedNumber(value) : number(value),
            unit: unit(metric.unit)
        )
    }

    private static func intervalRow(_ metric: HabitMetricEstimate) -> HairlineMetricRow {
        guard let lower = metric.intervalLower, let upper = metric.intervalUpper else {
            return HairlineMetricRow(title: "95% interval", value: "Not measured")
        }
        return HairlineMetricRow(
            title: "95% interval",
            value: "\(signedNumber(lower)) to \(signedNumber(upper))",
            unit: unit(metric.metricID.unit)
        )
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private static func signedNumber(_ value: Double) -> String {
        "\(value > 0 ? "+" : "")\(number(value))"
    }

    static func unit(_ unit: HabitMetricUnitID) -> String {
        switch unit {
        case .scorePoints: "points"
        case .milliseconds: "ms"
        case .beatsPerMinute: "bpm"
        case .minutes: "minutes"
        case .percentagePoints: "percentage points"
        }
    }
}

private enum HabitExclusionText {
    static func label(_ reason: HabitExclusionReason) -> String {
        switch reason {
        case .skipped: "Skipped"
        case .unanswered: "Unanswered"
        case .lateFirstEntry: "Entered after the deadline"
        case .legacyPresence: "Imported journal history"
        case .missingMainSleep: "Main sleep not measured"
        case .ambiguousMainSleep: "Main sleep could not be resolved"
        case .partialSleep: "Sleep was still processing"
        case .missingMetric: "Metric not measured"
        case .invalidMetric: "Metric was invalid"
        case .incompatibleMetricVersion: "Metric version was incompatible"
        case .unresolvedTimeZone: "Time zone could not be resolved"
        case .insufficientBaseline: "Not enough baseline history"
        }
    }

    static func unavailableDetail(_ reason: HabitExclusionReason?) -> String {
        switch reason {
        case .missingMainSleep: "No complete main sleep was measured for the answered days."
        case .ambiguousMainSleep: "Loopr could not resolve one main sleep for the answered days."
        case .partialSleep: "Sleep data was still processing for the answered days."
        case .missingMetric: "The next-sleep outcome was not measured for the answered days."
        case .invalidMetric: "The available next-sleep values were invalid."
        case .incompatibleMetricVersion: "The available sleep data uses an incompatible metric version."
        case .unresolvedTimeZone: "Loopr could not resolve the behavior-day time zone."
        case .insufficientBaseline: "There is not enough recent baseline history for an adjusted comparison."
        case .skipped, .unanswered, .lateFirstEntry, .legacyPresence: "No eligible Yes and No answers have a next-sleep outcome yet."
        case nil: "No eligible next-sleep outcome is available yet."
        }
    }
}

private struct HabitAnswerCalendar: View {
    let habitID: HabitID
    let records: [HabitDayRecord]
    let start: DayIdentity
    let end: DayIdentity

    var body: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: LooprSpacing.xs) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { item in
                        LooprText(item.element, style: .caption, color: .inkSecondary)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { cell in
                        if let day = cell.element {
                            let answer = recordByDay[day]?.response(for: habitID)?.answer
                            VStack(spacing: LooprSpacing.xxs) {
                                LooprText("\(day.day)", style: .caption)
                                Image(systemName: symbol(answer))
                                    .looprTypography(.confidence)
                                    .foregroundStyle(Color.loopr(color(answer)))
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: LooprSpacing.formButtonHeight)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(HabitCalendarText.fullDate(day)), \(answerText(answer))")
                        } else {
                            Spacer().frame(minHeight: LooprSpacing.formButtonHeight)
                        }
                    }
                }
                answerLegend
            }
        }
    }

    private var recordByDay: [DayIdentity: HabitDayRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.behaviorDay, $0) })
    }

    private var cells: [DayIdentity?] {
        guard let startDate = HabitCalendarText.date(start),
              let endDate = HabitCalendarText.date(end) else { return [] }
        let calendar = Calendar.current
        let startWeekday = calendar.component(.weekday, from: startDate)
        let leading = (startWeekday - calendar.firstWeekday + 7) % 7
        var output = Array<DayIdentity?>(repeating: nil, count: leading)
        var cursor = startDate
        while cursor <= endDate {
            output.append(HabitCalendarText.identity(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return output
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let offset = max(0, Calendar.current.firstWeekday - 1)
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private func symbol(_ answer: HabitAnswer?) -> String {
        switch answer {
        case .yes: "checkmark.circle.fill"
        case .no: "xmark.circle.fill"
        case .skipped: "minus.circle.fill"
        case nil: "circle"
        }
    }

    private func color(_ answer: HabitAnswer?) -> LooprColorToken {
        switch answer {
        case .yes: .brand
        case .no: .ink
        case .skipped: .strain
        case nil: .inkMuted
        }
    }

    private func answerText(_ answer: HabitAnswer?) -> String {
        switch answer {
        case .yes: "Yes"
        case .no: "No"
        case .skipped: "Skipped"
        case nil: "Unanswered"
        }
    }

    private var answerLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LooprSpacing.md) {
                legend("Yes", answer: .yes)
                legend("No", answer: .no)
                legend("Skipped", answer: .skipped)
                legend("Unanswered", answer: nil)
            }
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                HStack(spacing: LooprSpacing.md) {
                    legend("Yes", answer: .yes)
                    legend("No", answer: .no)
                }
                HStack(spacing: LooprSpacing.md) {
                    legend("Skipped", answer: .skipped)
                    legend("Unanswered", answer: nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ title: String, answer: HabitAnswer?) -> some View {
        Label(title, systemImage: symbol(answer))
            .looprTypography(.confidence)
            .foregroundStyle(Color.loopr(color(answer)))
    }
}

private enum HabitCalendarText {
    static func date(_ day: DayIdentity) -> Date? {
        var calendar = Calendar.current
        calendar.timeZone = .autoupdatingCurrent
        return calendar.date(from: DateComponents(
            era: day.era,
            year: day.year,
            month: day.month,
            day: day.day
        ))
    }

    static func identity(_ date: Date) -> DayIdentity? {
        let components = Calendar.current.dateComponents([.era, .year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return DayIdentity(era: components.era ?? 1, year: year, month: month, day: day)
    }

    static func fullDate(_ day: DayIdentity) -> String {
        date(day)?.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) ?? day.habitKey
    }

    static func shortDate(_ day: DayIdentity) -> String {
        date(day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day.habitKey
    }

    static func range(_ start: DayIdentity, _ end: DayIdentity) -> String {
        "\(shortDate(start)) to \(shortDate(end))"
    }
}

private struct HabitErrorCard: View {
    let message: String

    var body: some View {
        LooprFormCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                StateMessage(.recoverableError, compact: true)
                LooprText(message, style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
