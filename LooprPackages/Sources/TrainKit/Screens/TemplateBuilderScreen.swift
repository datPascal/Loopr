import DesignSystem
import SwiftUI
import UniformTypeIdentifiers
import WorkoutKit

/// What a dragged exercise row carries. It is JSON so a text field never accepts it as text.
struct ExerciseDragItem: Codable, Sendable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// The workout builder: name, days, exercises and rules for one template.
///
/// The screen edits a `TemplateBuilderModel` and writes nothing until Save. Back asks before it
/// discards edits. The app supplies storage through `save` and `createCustom`, the bundled library,
/// and `onDescribe`, which opens Ask for the Describe it field.
///
/// Pass closures that take or return values across a suspension as `@Sendable`. In the app that
/// reads `{ @MainActor @Sendable [repository] template in ... }`.
public struct TemplateBuilderScreen: View {
    private struct EditTarget: Identifiable { let id: UUID }

    @State private var model: TemplateBuilderModel
    @State private var editing: EditTarget?
    @State private var showsPicker = false
    @State private var showsProgression = false
    @State private var confirmsDiscard = false
    @State private var saving = false
    @State private var saveError: String?

    private let library: ExerciseLibrary
    private let save: TemplateBuilderModel.SaveHandler
    private let createCustom: @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition
    private let onDescribe: () -> Void
    private let onClose: () -> Void

    /// - Parameters:
    ///   - template: The template to edit, or a blank one for a new template.
    ///   - library: The bundled library merged with the person's custom exercises.
    ///   - save: Stores a template and returns it with its new revision.
    ///   - createCustom: Stores a custom exercise and returns it with its new revision.
    ///   - onDescribe: Opens Ask with "Workout builder" as its origin.
    ///   - onClose: Pops the screen after a save, or after the person confirms they want to discard.
    public init(template: WorkoutTemplate, library: ExerciseLibrary,
                save: @escaping TemplateBuilderModel.SaveHandler,
                createCustom: @escaping @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition,
                onDescribe: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = State(initialValue: TemplateBuilderModel(template: template))
        self.library = library
        self.save = save
        self.createCustom = createCustom
        self.onDescribe = onDescribe
        self.onClose = onClose
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                LooprAskField("Describe it: \"push day, 50 min\"", accessibilityLabel: "Describe it",
                              accent: .fitnessTab, identifier: "template-describe", action: onDescribe)
                nameSection
                daysSection
                if model.isStrength {
                    exercisesSection
                    rulesSection
                } else {
                    targetSection
                }
                if let saveError {
                    LooprText(saveError, style: .body, color: .critical)
                        .accessibilityIdentifier("template-save-error")
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
                    .accessibilityIdentifier("template-cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await performSave() } }
                    .disabled(!model.canSave || saving)
                    .accessibilityIdentifier("template-save")
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive, action: onClose)
                .accessibilityIdentifier("template-discard-confirm")
            Button("Keep editing", role: .cancel) {}
                .accessibilityIdentifier("template-keep-editing")
        } message: {
            Text("This workout has edits you have not saved.")
        }
        .sheet(item: $editing) { target in
            if let line = model.exercise(id: target.id), let draft = model.editorDraft(for: target.id) {
                ExerciseEditorSheet(name: line.exercise.name, draft: draft,
                                    onApply: { model.apply($0, to: target.id) },
                                    onRemove: { model.removeExercise(id: target.id) })
            }
        }
        .sheet(isPresented: $showsPicker) {
            ExercisePickerScreen(library: library, createCustom: createCustom) { model.addExercise($0) }
        }
        .sheet(isPresented: $showsProgression) {
            ProgressionRuleSheet(rule: model.progression) { model.progression = $0 }
        }
        .accessibilityIdentifier("template-builder")
    }

    // MARK: Sections

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Name")
            LooprCard(density: .flush) {
                LooprTextFieldRow(title: "Name", placeholder: "Upper A", text: nameBinding)
                    .accessibilityIdentifier("template-name")
            }
            if model.isDirty, model.problem == .nameMissing { hint(TemplateBuilderModel.Problem.nameMissing.message) }
        }
    }

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Days")
            LooprWeekdayPicker(selection: daysBinding, accent: .fitnessTab, identifier: "template-days")
        }
    }

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Exercises", detail: TemplateBuilderFormat.exerciseSummary(model.summary))
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(model.blocks.enumerated()), id: \.element.id) { offset, block in
                        row(for: block)
                        if offset < model.blocks.count - 1 { supersetLink(after: block) }
                    }
                    LooprInlineActionRow("Add exercise", symbol: "plus", identifier: "template-add-exercise") {
                        showsPicker = true
                    }
                    .disabled(!model.canAddExercise)
                }
            }
            if model.isDirty, let problem = model.problem, problem != .nameMissing { hint(problem.message) }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Rules")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    progressionRow
                    hairline
                    LooprToggleRow(title: "Adjust to recovery",
                                   subtitle: TemplateBuilderFormat.recoverySummary(model.recoveryRule),
                                   accent: .fitnessTab, isOn: $model.recoveryEnabled)
                        .accessibilityIdentifier("template-rule-recovery")
                    hairline
                    LooprToggleRow(title: "Rest cue on the band", subtitle: "Buzz when rest ends", accent: .fitnessTab, isOn: $model.bandRestCue)
                        .accessibilityIdentifier("template-rule-band-cue")
                }
            }
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Target")
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText(targetLine, style: .rowTitle)
                    LooprText("Cardio targets can't be edited here yet.", style: .prose, color: .inkSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("template-cardio-target")
        }
    }

    private var targetLine: String {
        guard let cardio = model.draft.cardio else { return "No target set" }
        var line = "\(cardio.activity.displayName), \(cardio.minutes) min"
        if let zone = cardio.zone { line += ", zone \(zone)" }
        return line
    }

    private var progressionRow: some View {
        let summary = TemplateBuilderFormat.progressionSummary(model.progression)
        return Button { showsProgression = true } label: {
            HStack(spacing: LooprSpacing.sm) {
                VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                    LooprText("Progression", style: .settingsRow)
                    LooprText(summary, style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LooprChevron()
            }
            .padding(.horizontal, LooprSpacing.formCardPadding)
            .padding(.vertical, LooprSpacing.formRowVerticalPadding)
            .frame(minHeight: LooprSpacing.interactiveRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progression, \(summary)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("template-rule-progression")
    }

    // MARK: Exercise rows

    @ViewBuilder
    private func row(for block: TemplateBuilderModel.Block) -> some View {
        let lines = block.exerciseIDs.compactMap { model.exercise(id: $0) }
        let first = block.id
        let firstIndex = model.index(of: first) ?? 0
        let up: (() -> Void)? = model.canMoveUp(first) ? { move(first, up: true) } : nil
        let down: (() -> Void)? = model.canMoveDown(first) ? { move(first, up: false) } : nil
        Group {
            if lines.count == 1, let line = lines.first {
                LooprExerciseRow(name: line.exercise.name, spec: TemplateBuilderFormat.spec(line),
                                 rest: TemplateBuilderFormat.restText(line), identifier: "template-exercise-\(firstIndex)",
                                 accessibilityLabel: TemplateBuilderFormat.spokenLabel(line),
                                 onMoveUp: up, onMoveDown: down) {
                    editing = EditTarget(id: line.id)
                }
            } else {
                LooprExerciseRow(
                    members: lines.enumerated().map { offset, line in
                        LooprExerciseRow.Member(
                            id: line.id.uuidString, name: line.exercise.name, spec: TemplateBuilderFormat.spec(line),
                            rest: TemplateBuilderFormat.restText(line), identifier: "template-exercise-\(firstIndex + offset)",
                            accessibilityLabel: TemplateBuilderFormat.spokenLabel(line, includeRest: offset == lines.count - 1))
                    },
                    identifier: "template-exercise-group-\(firstIndex)",
                    onSelect: { member in
                        if let id = UUID(uuidString: member.id) { editing = EditTarget(id: id) }
                    },
                    onMoveUp: up, onMoveDown: down)
            }
        }
        .draggable(ExerciseDragItem(id: first))
        .dropDestination(for: ExerciseDragItem.self) { items, _ in
            guard let item = items.first else { return false }
            model.move(item.id, onto: first)
            return true
        }
    }

    /// A visible way to pair a block with the one below it. A superset block links through its last member.
    private func supersetLink(after block: TemplateBuilderModel.Block) -> some View {
        let last = block.exerciseIDs[block.exerciseIDs.count - 1]
        let position = model.index(of: last) ?? 0
        let next = model.exercises.indices.contains(position + 1) ? model.exercises[position + 1].exercise.name : ""
        return Button {
            model.linkWithNext(last)
            AccessibilityNotification.Announcement("Superset made with \(next)").post()
        } label: {
            HStack(spacing: LooprSpacing.xs) {
                Image(systemName: "link")
                    .accessibilityHidden(true)
                LooprText("Superset with next", style: .caption, color: .inkSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .foregroundStyle(Color.loopr(.inkSecondary))
        .accessibilityLabel("Superset with next")
        .accessibilityHint(next.isEmpty ? "" : "Runs this with \(next), back to back")
        .accessibilityIdentifier("template-superset-next-\(position)")
    }

    private func move(_ id: UUID, up: Bool) {
        if up { model.moveUp(id) } else { model.moveDown(id) }
        if let position = model.blockIndex(of: id) {
            AccessibilityNotification.Announcement("Moved to position \(position + 1) of \(model.blocks.count)").post()
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
        Binding(get: { model.name }, set: { model.name = String($0.prefix(80)) })
    }

    private var daysBinding: Binding<Set<LooprWeekday>> {
        Binding(get: { Set(model.weekdays.compactMap { LooprWeekday(rawValue: $0.rawValue) }) },
                set: { model.weekdays = Set($0.compactMap { TrainWeekday(rawValue: $0.rawValue) }) })
    }

    private func hint(_ text: String) -> some View {
        LooprText(text, style: .body, color: .inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LooprSpacing.xs)
            .accessibilityIdentifier("template-hint")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.loopr(.divider))
            .frame(height: LooprSpacing.hairline)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .accessibilityHidden(true)
    }
}

#Preview("Workout builder") {
    NavigationStack {
        TemplateBuilderScreen(
            template: WorkoutTemplate(
                name: "Upper A", weekdays: [.tuesday, .saturday],
                exercises: [
                    TemplateExercise(exercise: ExerciseRef(key: "bench", name: "Bench press"), sets: 4, repsMin: 6, repsMax: 8, loadKg: 80, restSeconds: 150),
                    TemplateExercise(exercise: ExerciseRef(key: "pull", name: "Weighted pull-up"), sets: 4, repsMin: 6, repsMax: 6, loadKg: 10, restSeconds: 150)
                ],
                progression: .doubleProgression(incrementKg: 2.5), recoveryRule: RecoveryRule()),
            library: try! ExerciseLibrary(definitions: []),
            save: { $0 }, createCustom: { $0 }, onDescribe: {}, onClose: {})
    }
}
