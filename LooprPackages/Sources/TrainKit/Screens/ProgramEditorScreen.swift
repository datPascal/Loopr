import DesignSystem
import SwiftUI

/// The program editor: name, start day, the weeks of sessions, and the rules.
///
/// It edits a `ProgramEditorModel` and writes nothing until Save. Back asks before it discards edits.
/// The app supplies storage through `save` and Calendar permission through `requestCalendarAccess`,
/// which runs only when the person turns Add to Calendar on.
///
/// Pass closures that cross a suspension as `@Sendable`. In the app that reads
/// `{ @MainActor @Sendable [repository] program in ... }`.
public struct ProgramEditorScreen: View {
    private struct SlotTarget: Identifiable {
        let week: Int
        let weekday: TrainWeekday
        var id: String { "\(week)-\(weekday.rawValue)" }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var model: ProgramEditorModel
    @State private var editing: SlotTarget?
    @State private var confirmsDiscard = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var calendarDenied = false

    private let calendar: Calendar
    private let save: ProgramEditorModel.SaveHandler
    private let requestCalendarAccess: @Sendable () async -> Bool
    private let onClose: () -> Void

    /// - Parameters:
    ///   - model: The program to edit, or `ProgramEditorModel.blank` for a new one.
    ///   - calendar: Turns the start day into a date for the picker.
    ///   - save: Stores a program and returns it with its new revision.
    ///   - requestCalendarAccess: Asks for Calendar access and returns whether sessions can be saved.
    ///   - onClose: Pops the screen after a save, or after the person confirms they want to discard.
    public init(model: ProgramEditorModel, calendar: Calendar = .current,
                save: @escaping ProgramEditorModel.SaveHandler,
                requestCalendarAccess: @escaping @Sendable () async -> Bool,
                onClose: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.calendar = calendar
        self.save = save
        self.requestCalendarAccess = requestCalendarAccess
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                nameSection
                startSection
                weeksSection
                rulesSection
                if let saveError {
                    LooprText(saveError, style: .body, color: .critical)
                        .accessibilityIdentifier("program-editor-save-error")
                }
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.tabContentTop)
            .padding(.bottom, LooprSpacing.tabSection)
            .disabled(saving)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background))
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: cancel) { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Cancel")
                    .accessibilityHint(model.isDirty ? "Asks before it discards your changes" : "Leaves without saving")
                    .accessibilityIdentifier("program-editor-cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await performSave() } }
                    .disabled(!model.canSave || saving)
                    .accessibilityIdentifier("program-editor-save")
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive, action: onClose)
                .accessibilityIdentifier("program-editor-discard-confirm")
            Button("Keep editing", role: .cancel) {}
                .accessibilityIdentifier("program-editor-keep-editing")
        } message: {
            Text("This program has edits you have not saved.")
        }
        .sheet(item: $editing) { target in
            ProgramSlotSheet(weekday: target.weekday, week: target.week, templates: model.templates,
                             draft: model.slotDraft(week: target.week, weekday: target.weekday)) { result in
                model.apply(result, week: target.week, weekday: target.weekday)
            }
        }
        .accessibilityIdentifier("program-editor")
    }

    // MARK: Name and start

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Name")
            LooprCard(density: .flush) {
                LooprTextFieldRow(title: "Name", placeholder: "Strength block", text: nameBinding)
                    .accessibilityIdentifier("program-editor-name")
            }
            if model.problem == .nameMissing, model.isDirty { hint(ProgramEditorModel.Problem.nameMissing.message) }
        }
    }

    private var startSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Start day", detail: model.weekRunText)
            LooprCard(density: .flush) {
                HStack(spacing: LooprSpacing.sm) {
                    LooprText("Week 1 starts", style: .settingsRow)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: LooprSpacing.sm)
                    DatePicker("Week 1 starts", selection: startBinding, displayedComponents: .date)
                        .labelsHidden()
                        .tint(Color.loopr(.movement))
                        .accessibilityIdentifier("program-editor-start")
                }
                .padding(.horizontal, LooprSpacing.formCardPadding)
                .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            }
        }
    }

    // MARK: Weeks

    private var weeksSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Weeks", detail: model.summary)
            if model.templates.isEmpty {
                hint(ProgramEditorModel.Problem.noTemplates.message)
            }
            weekChips
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(TrainWeekday.allCases.enumerated()), id: \.element) { index, weekday in
                        slotRow(weekday)
                        if index < TrainWeekday.allCases.count - 1 { hairline }
                    }
                }
            }
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    LooprInlineActionRow("Use this week for every week", symbol: "square.on.square",
                                         identifier: "program-editor-copy-all") { model.copyWeekToAll(model.selectedWeek) }
                    hairline
                    LooprInlineActionRow("Remove week \(model.selectedWeek)", symbol: "minus.circle",
                                         identifier: "program-editor-remove-week") { model.removeWeek(model.selectedWeek) }
                        .disabled(!model.canRemoveWeek)
                }
            }
            if model.isDirty, model.problem == .noSessions { hint(ProgramEditorModel.Problem.noSessions.message) }
        }
    }

    private var weekChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LooprSpacing.xs) {
                    ForEach(1...model.weekCount, id: \.self) { week in
                        let selected = week == model.selectedWeek
                        Button { model.selectedWeek = week } label: {
                            Text("W\(week)")
                                .looprTypography(.label)
                                .foregroundStyle(selected ? LooprColorToken.movement.filledLabelColor : Color.loopr(.ink))
                                .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                                .background(selected ? Color.loopr(.movement) : Color.loopr(.surfaceSunk),
                                            in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(week)
                        .accessibilityLabel("Week \(week)")
                        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("program-editor-week-\(week)")
                    }
                    Button { model.addWeek() } label: {
                        Image(systemName: "plus")
                            .looprTypography(.label)
                            .foregroundStyle(Color.loopr(.movement))
                            .frame(minWidth: LooprSpacing.interactiveRowHeight, minHeight: LooprSpacing.interactiveRowHeight)
                            .overlay {
                                RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                                    .strokeBorder(Color.loopr(.movement).opacity(0.4), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAddWeek)
                    .accessibilityLabel("Add a week")
                    .accessibilityIdentifier("program-editor-add-week")
                }
            }
            .onChange(of: model.selectedWeek) { _, week in withAnimation { proxy.scrollTo(week) } }
        }
    }

    private func slotRow(_ weekday: TrainWeekday) -> some View {
        let slot = model.slot(week: model.selectedWeek, weekday: weekday)
        let template = slot.flatMap { model.template(id: $0.templateID) }
        var detail = template?.name ?? "Rest"
        if let slot {
            if slot.kind != .normal { detail += ", \(slot.kind.rawValue)" }
            if let minute = slot.startMinute { detail += ", \(TrainClockText.time(minute: minute))" }
        }
        let spoken = "\(weekday.ruleName), \(detail)"
        return Button { editing = SlotTarget(week: model.selectedWeek, weekday: weekday) } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(weekday.ruleName, style: .settingsRow)
                    LooprText(detail, style: .prose, color: slot == nil ? .inkSecondary : .ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let slot {
                    Text(ProgramScreenModel.code(for: slot, template: template))
                        .looprTypography(.metricUnit)
                        .foregroundStyle(Color.loopr(.inkSecondary))
                }
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Choose the workout for this day")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("program-editor-slot-\(weekday.ruleName.lowercased())")
    }

    // MARK: Rules

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Rules")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    LooprToggleRow(title: "Early light week",
                                   subtitle: "When \(model.rules.earlyLightWindowDays)-day recovery averages under \(model.rules.earlyLightBelowScore)",
                                   accent: .movement, identifier: "program-editor-rule-early-light",
                                   isOn: Binding(get: { model.rules.earlyLightWeek }, set: { model.rules.earlyLightWeek = $0 }))
                    hairline
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprText("Missed session", style: .settingsRow)
                        LooprText(ProgramScreenModel.missedText(model.rules.missed), style: .prose, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LooprChoiceControl("Missed session",
                                           choices: [LooprChoice(MissedSessionRule.moveBack.rawValue, title: "Move back"),
                                                     LooprChoice(MissedSessionRule.skip.rawValue, title: "Skip")],
                                           selection: model.rules.missed.rawValue, accent: .movement,
                                           identifier: "program-editor-rule-missed") { choice in
                            if let choice, let rule = MissedSessionRule(rawValue: choice) { model.rules.missed = rule }
                        }
                    }
                    .padding(.horizontal, LooprSpacing.formCardPadding)
                    .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    hairline
                    LooprToggleRow(title: "Add to Calendar", accent: .movement, identifier: "program-editor-rule-calendar",
                                   isOn: calendarBinding)
                        .disabled(model.isDraftProgram)
                }
            }
            if model.isDraftProgram {
                hint("Available after you accept the plan.")
            } else if calendarDenied {
                LooprText(ProgramScreenModel.calendarDeniedMessage, style: .body, color: .critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LooprSpacing.xs)
                    .accessibilityIdentifier("program-editor-calendar-denied")
            }
        }
    }

    // MARK: Actions

    private func cancel() {
        if model.isDirty { confirmsDiscard = true } else { onClose() }
    }

    private func performSave() async {
        guard model.canSave, !saving else { return }
        saving = true
        saveError = nil
        var saved = model
        do {
            try await saved.save(using: save)
            model = saved
            saving = false
            onClose()
        } catch {
            saving = false
            saveError = error.localizedDescription
        }
    }

    // MARK: Bindings and small views

    private var nameBinding: Binding<String> {
        Binding(get: { model.name }, set: { model.name = $0 })
    }

    private var startBinding: Binding<Date> {
        Binding(get: { ProgramEditorModel.date(fromDay: model.startDay, calendar: calendar) ?? Date() },
                set: { model.startDay = ProgramEditorModel.day(from: $0, calendar: calendar) })
    }

    private var calendarBinding: Binding<Bool> {
        Binding(get: { model.rules.calendarExport && !calendarDenied }, set: { newValue in
            guard newValue else {
                calendarDenied = false
                model.rules.calendarExport = false
                return
            }
            Task {
                let allowed = await requestCalendarAccess()
                calendarDenied = !allowed
                model.rules.calendarExport = allowed
            }
        })
    }

    private func hint(_ text: String) -> some View {
        LooprText(text, style: .body, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xs)
            .accessibilityIdentifier("program-editor-hint")
    }

    private var hairline: some View {
        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
            .padding(.horizontal, LooprSpacing.cardHorizontal).accessibilityHidden(true)
    }
}

/// Picks the workout, intensity, tag and planned time for one day of one week.
struct ProgramSlotSheet: View {
    let weekday: TrainWeekday
    let week: Int
    let templates: [WorkoutTemplate]
    let apply: (ProgramSlotDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ProgramSlotDraft

    init(weekday: TrainWeekday, week: Int, templates: [WorkoutTemplate], draft: ProgramSlotDraft,
         apply: @escaping (ProgramSlotDraft) -> Void) {
        self.weekday = weekday; self.week = week; self.templates = templates; self.apply = apply
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprSectionHeader("Workout")
                        LooprCard(density: .flush) {
                            VStack(spacing: LooprSpacing.none) {
                                choiceRow(title: "Rest", caption: nil, selected: draft.templateID == nil, identifier: "program-editor-slot-template-rest") {
                                    draft.templateID = nil
                                }
                                ForEach(templates) { template in
                                    hairline
                                    choiceRow(title: template.name, caption: caption(for: template), selected: draft.templateID == template.id,
                                              identifier: "program-editor-slot-template-\(TrainOverviewModel.slug(template.name))") {
                                        draft.templateID = template.id
                                    }
                                }
                            }
                        }
                    }
                    if draft.templateID != nil {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Intensity")
                            LooprChoiceControl("Intensity",
                                               choices: ProgramSlotKind.allCases.map { LooprChoice($0.rawValue, title: $0.rawValue.capitalized) },
                                               selection: draft.kind.rawValue, accent: .movement,
                                               identifier: "program-editor-slot-kind") { choice in
                                if let choice, let kind = ProgramSlotKind(rawValue: choice) { draft.kind = kind }
                            }
                        }
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Grid label", detail: "Up to \(ProgramSlotDraft.maxTagLength) characters. Leave it empty to use the workout's initials.")
                            LooprCard(density: .flush) {
                                LooprTextFieldRow(title: "Label", placeholder: "UA", text: tagBinding)
                                    .accessibilityIdentifier("program-editor-slot-tag")
                            }
                        }
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Planned time")
                            LooprCard(density: .flush) {
                                VStack(spacing: LooprSpacing.none) {
                                    LooprToggleRow(title: "Set a start time", accent: .movement, identifier: "program-editor-slot-time-toggle",
                                                   isOn: Binding(get: { draft.startMinute != nil },
                                                                 set: { draft.startMinute = $0 ? (draft.startMinute ?? 18 * 60) : nil }))
                                    if draft.startMinute != nil {
                                        hairline
                                        HStack {
                                            LooprText("Starts at", style: .settingsRow)
                                            Spacer(minLength: LooprSpacing.sm)
                                            DatePicker("Starts at", selection: timeBinding, displayedComponents: .hourAndMinute)
                                                .labelsHidden()
                                                .tint(Color.loopr(.movement))
                                                .accessibilityIdentifier("program-editor-slot-time")
                                        }
                                        .padding(.horizontal, LooprSpacing.formCardPadding)
                                        .padding(.vertical, LooprSpacing.formRowVerticalPadding)
                                        .frame(minHeight: LooprSpacing.interactiveRowHeight)
                                    }
                                }
                            }
                        }
                    }
                    Button("Apply") {
                        apply(draft)
                        dismiss()
                    }
                    .buttonStyle(LooprButtonStyle(accent: .movement))
                    .accessibilityIdentifier("program-editor-slot-apply")
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.tabContentTop)
                .padding(.bottom, LooprSpacing.tabSection)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background))
            .navigationTitle("\(weekday.ruleName), week \(week)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("program-editor-slot-cancel")
                }
            }
        }
        .tint(Color.loopr(.movement))
        .accessibilityIdentifier("program-editor-slot-sheet")
    }

    private func caption(for template: WorkoutTemplate) -> String {
        switch template.kind {
        case .cardio: template.cardio.map { "\($0.minutes) min" } ?? "Cardio"
        case .strength: "\(template.exercises.count) \(template.exercises.count == 1 ? "exercise" : "exercises")"
        }
    }

    private func choiceRow(title: String, caption: String?, selected: Bool, identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(title, style: .settingsRow)
                    if let caption { LooprText(caption, style: .prose, color: .inkSecondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.loopr(.movement)).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(identifier)
    }

    private var tagBinding: Binding<String> {
        Binding(get: { draft.tag }, set: { draft.tag = String($0.prefix(ProgramSlotDraft.maxTagLength)) })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let minute = draft.startMinute ?? 18 * 60
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60)) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.startMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    private var hairline: some View {
        Rectangle().fill(Color.loopr(.divider)).frame(height: LooprSpacing.hairline)
            .padding(.horizontal, LooprSpacing.cardHorizontal).accessibilityHidden(true)
    }
}

/// "18:00" for the planned time of a slot. Always 24-hour, so it reads the same in every locale.
public enum TrainClockText {
    public static func time(minute: Int) -> String {
        let clamped = min(max(minute, 0), ProgramSlot.minutesPerDay - 1)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
