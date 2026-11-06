import DesignSystem
import SwiftUI

/// Edits one template exercise: sets, rest, what each set records and its target, note and superset links.
/// It works on a copy. Apply hands the copy back, Cancel drops it.
public struct ExerciseEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: ExerciseEditorDraft
    private let name: String
    private let onApply: (ExerciseEditorDraft) -> Void
    private let onRemove: () -> Void

    public init(name: String, draft: ExerciseEditorDraft, onApply: @escaping (ExerciseEditorDraft) -> Void,
                onRemove: @escaping () -> Void) {
        self.name = name
        _draft = State(initialValue: draft)
        self.onApply = onApply
        self.onRemove = onRemove
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    pair {
                        LooprValueStepper("sets", label: "Sets", spokenUnit: "sets", value: setsBinding, step: 1,
                                          range: Double(ExerciseEditorDraft.setsRange.lowerBound)...Double(ExerciseEditorDraft.setsRange.upperBound),
                                          identifier: "exercise-editor-sets", decrementIdentifier: "exercise-editor-sets-minus",
                                          incrementIdentifier: "exercise-editor-sets-plus")
                        LooprValueStepper("rest", label: "Rest", spokenUnit: "seconds", value: restBinding, step: 15,
                                          range: 0...Double(max(600, draft.restSeconds)),
                                          identifier: "exercise-editor-rest", decrementIdentifier: "exercise-editor-rest-minus",
                                          incrementIdentifier: "exercise-editor-rest-plus", format: .clock)
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprSectionHeader("Each set records")
                        LooprChoiceControl("Each set records",
                                           choices: TrainSetMeasure.allCases.map { LooprChoice($0.rawValue, title: $0.title) },
                                           selection: draft.measure.rawValue, accent: .fitnessTab,
                                           identifier: "exercise-editor-measure") { choice in
                            if let choice, let measure = TrainSetMeasure(rawValue: choice) { draft.measure = measure }
                        }
                    }
                    targetSection
                    if draft.hasPrevious || draft.hasNext {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Superset", detail: "Superset exercises run back to back, then you rest.")
                            LooprCard(density: .flush) {
                                VStack(spacing: LooprSpacing.none) {
                                    if draft.hasPrevious {
                                        LooprToggleRow(title: "Superset with the one above", accent: .fitnessTab, isOn: $draft.linkedWithPrevious)
                                            .accessibilityIdentifier("exercise-editor-superset-above")
                                    }
                                    if draft.hasPrevious, draft.hasNext { hairline }
                                    if draft.hasNext {
                                        LooprToggleRow(title: "Superset with next", accent: .fitnessTab, isOn: $draft.linkedWithNext)
                                            .accessibilityIdentifier("exercise-editor-superset-below")
                                    }
                                }
                            }
                        }
                    }
                    if draft.blockCount > 1 {
                        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                            LooprSectionHeader("Position",
                                               detail: "\(draft.isInSuperset ? "Superset" : "Exercise") \(draft.pendingBlockIndex + 1) of \(draft.blockCount)")
                            LooprCard(density: .flush) {
                                VStack(spacing: LooprSpacing.none) {
                                    LooprInlineActionRow(draft.isInSuperset ? "Move superset up" : "Move up", symbol: "arrow.up",
                                                         identifier: "exercise-editor-move-up") { draft.moveUp() }
                                        .disabled(!draft.canMoveUp)
                                    hairline
                                    LooprInlineActionRow(draft.isInSuperset ? "Move superset down" : "Move down", symbol: "arrow.down",
                                                         identifier: "exercise-editor-move-down") { draft.moveDown() }
                                        .disabled(!draft.canMoveDown)
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                        LooprSectionHeader("Note")
                        LooprCard(density: .flush) {
                            LooprTextFieldRow(title: "Cue", placeholder: "Optional", text: noteBinding)
                                .accessibilityIdentifier("exercise-editor-note")
                        }
                    }
                    VStack(spacing: LooprSpacing.cardStack) {
                        Button("Apply") {
                            onApply(draft)
                            dismiss()
                        }
                        .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                        .accessibilityIdentifier("exercise-editor-apply")
                        Button("Remove exercise") {
                            onRemove()
                            dismiss()
                        }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .critical))
                        .accessibilityIdentifier("exercise-editor-remove")
                    }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.tabContentTop)
                .padding(.bottom, LooprSpacing.tabSection)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background))
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("exercise-editor-cancel")
                }
            }
        }
        .accessibilityIdentifier("exercise-editor")
    }

    private var repsRange: ClosedRange<Double> {
        Double(draft.repsLimit.lowerBound)...Double(draft.repsLimit.upperBound)
    }

    /// The target in the measure's unit: a rep range and load, a hold, or a distance.
    @ViewBuilder
    private var targetSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Target")
            VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                switch draft.measure {
                case .weight:
                    repsPair
                    load("Load", $draft.loadKg, id: "exercise-editor-load")
                case .bodyweight:
                    repsPair
                    LooprChoiceControl("Extra load", choices: [
                        LooprChoice(ExerciseEditorDraft.BodyweightLoad.none.rawValue, title: "None"),
                        LooprChoice(ExerciseEditorDraft.BodyweightLoad.added.rawValue, title: "Added"),
                        LooprChoice(ExerciseEditorDraft.BodyweightLoad.assisted.rawValue, title: "Assisted")
                    ], selection: draft.bodyweightLoad.rawValue, accent: .fitnessTab, identifier: "exercise-editor-bw-load") { choice in
                        if let choice, let mode = ExerciseEditorDraft.BodyweightLoad(rawValue: choice) { draft.bodyweightLoad = mode }
                    }
                    if draft.bodyweightLoad == .added { load("Added weight", $draft.loadKg, id: "exercise-editor-load") }
                    if draft.bodyweightLoad == .assisted { load("Assistance", $draft.assistKg, id: "exercise-editor-assist") }
                case .time:
                    pair {
                        LooprValueStepper("hold", label: "Hold", spokenUnit: "seconds",
                                          value: Binding(get: { Double(draft.targetSeconds) }, set: { draft.targetSeconds = Int($0.rounded()) }),
                                          step: 5, range: Double(ExerciseEditorDraft.secondsRange.lowerBound)...Double(ExerciseEditorDraft.secondsRange.upperBound),
                                          identifier: "exercise-editor-seconds", decrementIdentifier: "exercise-editor-seconds-minus",
                                          incrementIdentifier: "exercise-editor-seconds-plus", format: .clock)
                        load("Load", $draft.loadKg, id: "exercise-editor-load")
                    }
                case .distance:
                    pair {
                        LooprValueStepper("m", label: "Distance", spokenUnit: "metres", value: $draft.targetMetres, step: 5,
                                          range: ExerciseEditorDraft.metresRange, identifier: "exercise-editor-metres",
                                          decrementIdentifier: "exercise-editor-metres-minus",
                                          incrementIdentifier: "exercise-editor-metres-plus")
                        load("Load", $draft.loadKg, id: "exercise-editor-load")
                    }
                }
            }
        }
    }

    private var repsPair: some View {
        pair {
            LooprValueStepper("min reps", label: "Minimum reps", spokenUnit: "reps", value: repsMinBinding, step: 1,
                              range: repsRange, identifier: "exercise-editor-reps-min",
                              decrementIdentifier: "exercise-editor-reps-min-minus",
                              incrementIdentifier: "exercise-editor-reps-min-plus")
            LooprValueStepper("max reps", label: "Maximum reps", spokenUnit: "reps", value: repsMaxBinding, step: 1,
                              range: repsRange, identifier: "exercise-editor-reps-max",
                              decrementIdentifier: "exercise-editor-reps-max-minus",
                              incrementIdentifier: "exercise-editor-reps-max-plus")
        }
    }

    private func load(_ label: String, _ value: Binding<Double>, id: String) -> some View {
        LooprValueStepper("kg", label: label, spokenUnit: "kilograms", value: value, step: 2.5,
                          range: ExerciseEditorDraft.loadRange, identifier: id,
                          decrementIdentifier: "\(id)-minus", incrementIdentifier: "\(id)-plus")
    }

    private var setsBinding: Binding<Double> {
        Binding(get: { Double(draft.sets) }, set: { draft.sets = Int($0.rounded()) })
    }

    private var restBinding: Binding<Double> {
        Binding(get: { Double(draft.restSeconds) }, set: { draft.restSeconds = Int($0.rounded()) })
    }

    private var repsMinBinding: Binding<Double> {
        Binding(get: { Double(draft.repsMin) }, set: { draft.setRepsMin(Int($0.rounded())) })
    }

    private var repsMaxBinding: Binding<Double> {
        Binding(get: { Double(draft.repsMax) }, set: { draft.setRepsMax(Int($0.rounded())) })
    }

    private var noteBinding: Binding<String> {
        Binding(get: { draft.note }, set: { draft.note = String($0.prefix(500)) })
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.loopr(.divider))
            .frame(height: LooprSpacing.hairline)
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .accessibilityHidden(true)
    }

    /// Two steppers side by side, stacked at accessibility text sizes.
    private func pair<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: LooprSpacing.cardStack))
            : AnyLayout(HStackLayout(spacing: LooprSpacing.cardStack))
        return layout { content() }
    }
}

#Preview("Exercise editor") {
    ExerciseEditorSheet(
        name: "Bench press",
        draft: ExerciseEditorDraft(sets: 4, repsMin: 6, repsMax: 8, loadKg: 80, measure: .weight, restSeconds: 150,
                                   note: "", hasPrevious: true, hasNext: true),
        onApply: { _ in }, onRemove: {})
}
