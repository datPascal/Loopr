import DesignSystem
import SwiftUI

/// Logs a gym session already done (R2-LIFT-05, R1-LIFT-04): the day and start time, how long it took, then each
/// exercise's sets as a table in its measure. A new exercise starts from last time. There is no rest timer and nothing
/// goes to the band. Save hands the draft back; the app stores the session and its workout record.
public struct TrainPastSessionScreen: View {
    @State private var draft: TrainPastSessionDraft
    @State private var picker: PickerItem?
    @State private var saving = false
    @State private var failure: String?
    private let library: ExerciseLibrary
    private let templates: [WorkoutTemplate]
    private let now: () -> Date
    private let createCustom: @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition
    private let save: @MainActor (TrainPastSessionDraft) async throws -> Void

    /// - Parameters:
    ///   - history: Finished sessions. They fill new exercises from last time and decide the bests.
    ///   - save: Stores the session. A throw shows its message above Save.
    public init(library: ExerciseLibrary, history: [TrainSession], templates: [WorkoutTemplate] = [],
                now: @escaping () -> Date = Date.init,
                timeZoneIdentifier: String = TimeZone.current.identifier,
                createCustom: @escaping @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition,
                save: @escaping @MainActor (TrainPastSessionDraft) async throws -> Void) {
        self.library = library
        self.templates = templates.filter { $0.kind == .strength && !$0.exercises.isEmpty }
        self.now = now
        self.createCustom = createCustom
        self.save = save
        _draft = State(initialValue: TrainPastSessionDraft(startedAt: TrainPastSessionDraft.defaultStart(now: now()),
                                                           history: history, timeZoneIdentifier: timeZoneIdentifier))
    }

    private struct PickerItem: Identifiable {
        let id = 0
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                whenCard
                if draft.lines.isEmpty, !templates.isEmpty { startFrom }
                ForEach(Array(draft.lines.enumerated()), id: \.element.id) { index, line in
                    lineCard(line, index: index)
                }
                Button { picker = PickerItem() } label: {
                    Label("Add exercise", systemImage: "plus")
                }
                .buttonStyle(LooprButtonStyle(prominent: draft.lines.isEmpty, accent: .fitnessTab))
                .accessibilityIdentifier("train-past-add-exercise")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.xxl * 2)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background).ignoresSafeArea())
        // On the scroll view, before the bar, so Save keeps its own identifier.
        .accessibilityIdentifier("train-past-screen")
        .safeAreaInset(edge: .bottom) { saveBar }
        .navigationTitle("Log a gym session")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color.loopr(.fitnessTab))
        .sheet(item: $picker) { _ in
            ExercisePickerScreen(library: library, createCustom: createCustom) { definition in
                picker = nil
                do { try draft.addExercise(definition) } catch { failure = error.localizedDescription }
            }
        }
    }

    // MARK: When

    private var whenCard: some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                TextField("Name", text: $draft.name, prompt: Text("Workout"))
                    .looprTypography(.rowTitle)
                    .accessibilityIdentifier("train-past-name")
                DatePicker("Started", selection: $draft.startedAt, in: ...now(), displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("train-past-start")
                Stepper(value: $draft.durationMinutes, in: TrainPastSessionDraft.durationRange, step: 5) {
                    LooprText("Took \(draft.durationMinutes) min", style: .body)
                }
                .accessibilityIdentifier("train-past-duration")
                LooprText("No rest timer and no band. The sets count toward the day you pick.", style: .caption,
                          color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Start from

    /// One tap fills the session from a saved workout, each exercise with last time's sets (R3-LIFT-01).
    private var startFrom: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Start from", identifier: "train-past-start-from")
            LooprCard(density: .flush) {
                VStack(spacing: LooprSpacing.none) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, template in
                        Button { fill(from: template) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    LooprText(template.name, style: .rowTitle)
                                    LooprText("\(template.exercises.count) exercises", style: .caption, color: .inkSecondary)
                                }
                                Spacer(minLength: LooprSpacing.sm)
                                Image(systemName: "plus.circle").foregroundStyle(Color.loopr(.fitnessTab))
                            }
                            .padding(.horizontal, LooprSpacing.cardHorizontal)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight + LooprSpacing.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityLabel("Start from \(template.name), \(template.exercises.count) exercises")
                        .accessibilityIdentifier("train-past-template-\(index)")
                        if index < templates.count - 1 { LooprHairline().padding(.leading, LooprSpacing.cardHorizontal) }
                    }
                }
            }
        }
    }

    private func fill(from template: WorkoutTemplate) {
        if draft.name == TrainPastSessionDraft.defaultName || draft.name.isEmpty { draft.name = template.name }
        for line in template.exercises {
            let definition = library.definition(forKey: line.exercise.key)
                ?? ExerciseDefinition(key: line.exercise.key, name: line.exercise.name, category: "strength")
            do { try draft.addExercise(definition) } catch { failure = error.localizedDescription; return }
        }
    }

    // MARK: Exercises

    private func lineCard(_ line: TrainPastSessionDraft.Line, index: Int) -> some View {
        LooprCard {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText(line.exercise.name, style: .rowTitle)
                        LooprText(line.fromLastTime ? "\(line.measure.title), filled from last time" : line.measure.title,
                                  style: .caption, color: .inkSecondary)
                    }
                    Spacer(minLength: LooprSpacing.sm)
                    Button(role: .destructive) { draft.removeExercise(at: index) } label: {
                        Image(systemName: "trash")
                            .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.loopr(.inkSecondary))
                    .accessibilityLabel("Remove \(line.exercise.name)")
                    .accessibilityIdentifier("train-past-remove-\(index)")
                }
                headerRow(line.measure)
                ForEach(Array(line.rows.enumerated()), id: \.element.id) { rowIndex, _ in
                    setRow(line: index, row: rowIndex, measure: line.measure)
                }
                Button { try? draft.addSet(toLineAt: index) } label: {
                    Label("Add set", systemImage: "plus")
                        .looprTypography(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.loopr(.fitnessTab))
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .accessibilityIdentifier("train-past-add-set-\(index)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("train-past-exercise-\(index)")
    }

    private func columns(_ measure: TrainSetMeasure) -> [String] {
        switch measure {
        case .weight: ["kg", "Reps"]
        case .bodyweight: ["Added kg", "Reps"]
        case .time: ["Seconds", "Added kg"]
        case .distance: ["Metres", "kg"]
        }
    }

    private func headerRow(_ measure: TrainSetMeasure) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            LooprText("Set", style: .caption, color: .inkSecondary).frame(width: 32, alignment: .leading)
            ForEach(columns(measure), id: \.self) { title in
                LooprText(title, style: .caption, color: .inkSecondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.clear.frame(width: LooprSpacing.interactiveRowHeight, height: 1)
        }
        .accessibilityHidden(true)
    }

    private func setRow(line: Int, row: Int, measure: TrainSetMeasure) -> some View {
        HStack(spacing: LooprSpacing.sm) {
            LooprText("\(row + 1)", style: .body, color: .inkSecondary).frame(width: 32, alignment: .leading)
            switch measure {
            case .weight:
                number(line, row, \.loadKg, label: "kilograms")
                count(line, row)
            case .bodyweight:
                number(line, row, \.loadKg, label: "added kilograms")
                count(line, row)
            case .time:
                seconds(line, row)
                number(line, row, \.loadKg, label: "added kilograms")
            case .distance:
                number(line, row, \.metres, label: "metres")
                number(line, row, \.loadKg, label: "kilograms")
            }
            Button { draft.removeSet(lineIndex: line, rowIndex: row) } label: {
                Image(systemName: "minus.circle")
                    .frame(width: LooprSpacing.interactiveRowHeight, height: LooprSpacing.interactiveRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.loopr(.inkSecondary))
            .accessibilityLabel("Delete set \(row + 1)")
            .accessibilityIdentifier("train-past-delete-set-\(line)-\(row)")
        }
        .frame(minHeight: LooprSetLogTable.minimumRowHeight)
    }

    private func values(_ line: Int, _ row: Int) -> TrainSetValues {
        draft.lines.indices.contains(line) && draft.lines[line].rows.indices.contains(row)
            ? draft.lines[line].rows[row].values : TrainSetValues()
    }

    private func write(_ line: Int, _ row: Int, _ change: (inout TrainSetValues) -> Void) {
        var next = values(line, row)
        change(&next)
        let tag = draft.lines.indices.contains(line) && draft.lines[line].rows.indices.contains(row)
            ? draft.lines[line].rows[row].tag : nil
        draft.updateSet(lineIndex: line, rowIndex: row, values: next, tag: tag)
    }

    private func number(_ line: Int, _ row: Int, _ path: WritableKeyPath<TrainSetValues, Double?>, label: String) -> some View {
        TextField("0", value: Binding(get: { values(line, row)[keyPath: path] },
                                      set: { value in write(line, row) { $0[keyPath: path] = value } }),
                  format: .number.precision(.fractionLength(0...2)))
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Set \(row + 1), \(label)")
            .accessibilityIdentifier("train-past-\(line)-\(row)-\(label.replacingOccurrences(of: " ", with: "-"))")
    }

    private func count(_ line: Int, _ row: Int) -> some View {
        TextField("0", value: Binding(get: { values(line, row).reps }, set: { value in write(line, row) { $0.reps = max(value, 0) } }),
                  format: .number)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Set \(row + 1), reps")
            .accessibilityIdentifier("train-past-\(line)-\(row)-reps")
    }

    private func seconds(_ line: Int, _ row: Int) -> some View {
        TextField("0", value: Binding(get: { values(line, row).seconds }, set: { value in write(line, row) { $0.seconds = value } }),
                  format: .number)
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Set \(row + 1), seconds")
            .accessibilityIdentifier("train-past-\(line)-\(row)-seconds")
    }

    // MARK: Save

    private var problem: TrainPastSessionDraft.Problem? { draft.problem(now: now()) }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            if let message = failure ?? problem?.message {
                LooprText(message, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("train-past-problem")
            }
            Button {
                Task { await commit() }
            } label: {
                Text(saving ? "Saving" : "Save session").frame(maxWidth: .infinity)
            }
            .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
            .disabled(problem != nil || saving)
            .accessibilityIdentifier("train-past-save")
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .padding(.vertical, LooprSpacing.sm)
        .background(Color.loopr(.background).ignoresSafeArea(edges: .bottom))
    }

    private func commit() async {
        guard problem == nil else { return }
        saving = true
        failure = nil
        do {
            try await save(draft)
        } catch {
            failure = error.localizedDescription
        }
        saving = false
    }
}
