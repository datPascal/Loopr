import DesignSystem
import SwiftUI

extension EnvironmentValues {
    /// Exercise keys the person logged, newest first (`ExerciseRecents.keys`). The picker lists them under Recent.
    @Entry public var exerciseRecentKeys: [String] = []
}

/// Searches the bundled exercise library and any custom exercises, and hands back the exercise
/// the person taps. A custom exercise is created here, saved through `createCustom`, and handed
/// back like any other.
///
/// Before a search it lists Recent (from `exerciseRecentKeys`), the person's own exercises and a short
/// Common list. A search or a chip shows the matching exercises. Present it in a sheet. It brings its
/// own navigation stack.
public struct ExercisePickerScreen: View {
    /// Results beyond this many are cut off, with a note to narrow the search.
    public static let resultLimit = 100
    static let anyChoice = "any"
    static let recentLimit = 8

    @Environment(\.dismiss) private var dismiss
    @Environment(\.exerciseRecentKeys) private var recentKeys
    @State private var library: ExerciseLibrary
    @State private var query = ""
    @State private var equipment = Self.anyChoice
    @State private var muscle = Self.anyChoice
    @State private var category: ExercisePickerCategory?
    @State private var creating = false
    private let createCustom: @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition
    private let onPick: (ExerciseDefinition) -> Void

    public init(library: ExerciseLibrary,
                createCustom: @escaping @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition,
                onPick: @escaping (ExerciseDefinition) -> Void) {
        _library = State(initialValue: library)
        self.createCustom = createCustom
        self.onPick = onPick
    }

    private var filter: ExerciseFilter {
        ExerciseFilter(equipment: equipment == Self.anyChoice ? [] : [ExerciseEquipment(dataset: equipment)],
                       muscles: muscle == Self.anyChoice ? [] : [muscle])
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// No search and no chip: the screen shows Recent, Your exercises and Common instead of results.
    private var isBrowsing: Bool { trimmedQuery.isEmpty && category == nil && filter.isEmpty }

    private var equipmentOptions: [String] {
        let present = Set(library.all.map(\.equipmentKind))
        return [Self.anyChoice] + ExerciseEquipment.allCases.filter(present.contains)
            .sorted { $0.displayName < $1.displayName }.map(\.rawValue)
    }

    private var muscleOptions: [String] { [Self.anyChoice] + library.muscles }

    private var recent: [ExerciseDefinition] {
        Array(recentKeys.compactMap(library.definition(forKey:)).prefix(Self.recentLimit))
    }

    private var yours: [ExerciseDefinition] { library.all.filter { $0.origin == .custom } }

    private var common: [ExerciseDefinition] {
        let shown = Set(recent.map(\.key))
        return ExerciseCollections.common.compactMap(library.definition(forKey:)).filter { !shown.contains($0.key) }
    }

    private var found: [ExerciseDefinition] {
        let preferred = Set(recentKeys).union(yours.map(\.key))
        let matches = library.search(trimmedQuery, filter: filter, preferring: preferred)
        guard let category else { return matches }
        return matches.filter(category.matches)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.cardStack) {
                    if isBrowsing { browsing } else { results }
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.xs)
                .padding(.bottom, LooprSpacing.tabSection)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: LooprSpacing.none) { controls }
            .background(Color.loopr(.background))
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("exercise-picker-cancel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New exercise") { creating = true }
                        .tint(Color.loopr(.fitnessTab))
                        .accessibilityHint("Adds an exercise of your own")
                        .accessibilityIdentifier("exercise-custom-new")
                }
            }
            .sheet(isPresented: $creating) {
                CustomExerciseSheet(name: trimmedQuery, library: library, create: createCustom) { saved in
                    if saved.origin == .custom, let merged = try? library.merged(withCustom: [saved]) { library = merged }
                    onPick(saved)
                    dismiss()
                }
            }
        }
        .accessibilityIdentifier("exercise-picker")
    }

    // MARK: Search and chips

    /// The search field and one row of chips, pinned under the title so neither scrolls away.
    private var controls: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprCard(density: .flush) {
                LooprSearchField("Search exercises", text: $query, identifier: "exercise-search")
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: LooprSpacing.xs) {
                    ForEach(ExercisePickerCategory.allCases) { option in
                        Button {
                            category = category == option ? nil : option
                        } label: {
                            ExercisePickerChipLabel(title: option.title, selected: category == option, menu: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(category == option ? .isSelected : [])
                        .accessibilityHint(category == option ? "Shows every category again" : "Shows only \(option.title.lowercased()) exercises")
                        .accessibilityIdentifier("exercise-category-\(option.rawValue)")
                    }
                    Menu {
                        Picker("Equipment", selection: $equipment) {
                            ForEach(equipmentOptions, id: \.self) { option in
                                Text(option == Self.anyChoice ? "Any equipment" : ExerciseEquipment(dataset: option).displayName).tag(option)
                            }
                        }
                    } label: {
                        ExercisePickerChipLabel(title: equipment == Self.anyChoice ? "Equipment" : ExerciseEquipment(dataset: equipment).displayName,
                                                selected: equipment != Self.anyChoice, menu: true)
                    }
                    .accessibilityLabel(equipment == Self.anyChoice ? "Equipment, any" : "Equipment, \(ExerciseEquipment(dataset: equipment).displayName)")
                    .accessibilityIdentifier("exercise-filter-equipment")
                    Menu {
                        Picker("Muscle", selection: $muscle) {
                            ForEach(muscleOptions, id: \.self) { option in
                                Text(option == Self.anyChoice ? "Any muscle" : TemplateBuilderFormat.capitalized(option)).tag(option)
                            }
                        }
                    } label: {
                        ExercisePickerChipLabel(title: muscle == Self.anyChoice ? "Muscle" : TemplateBuilderFormat.capitalized(muscle),
                                                selected: muscle != Self.anyChoice, menu: true)
                    }
                    .accessibilityLabel(muscle == Self.anyChoice ? "Muscle, any" : "Muscle, \(TemplateBuilderFormat.capitalized(muscle))")
                    .accessibilityIdentifier("exercise-filter-muscle")
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
            }
            .accessibilityIdentifier("exercise-chips")
        }
        .padding(.top, LooprSpacing.xs)
        .padding(.bottom, LooprSpacing.xs)
        .background(Color.loopr(.background))
    }

    // MARK: Lists

    @ViewBuilder
    private var browsing: some View {
        if !recent.isEmpty {
            section("Recent", detail: nil, rows: recent, identifier: "exercise-recent")
        }
        if !yours.isEmpty {
            section("Your exercises", detail: nil, rows: yours, identifier: "exercise-yours")
        }
        section("Common", detail: nil, rows: common, identifier: "exercise-result")
        LooprText("Search or choose a category to see all \(library.count) exercises.", style: .caption, color: .inkSecondary)
            .padding(.horizontal, LooprSpacing.xs)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("exercise-browse-note")
    }

    @ViewBuilder
    private var results: some View {
        let found = found
        let shown = Array(found.prefix(Self.resultLimit))
        if shown.isEmpty {
            LooprSectionHeader("Results", detail: "No matches")
                .padding(.top, LooprSpacing.xs)
            VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                LooprText("No exercise matches.", style: .prose, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !trimmedQuery.isEmpty {
                    Button("Add \"\(trimmedQuery)\" as a new exercise") { creating = true }
                        .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab))
                        .accessibilityIdentifier("exercise-empty-create")
                }
            }
            .padding(.horizontal, LooprSpacing.xs)
            .accessibilityIdentifier("exercise-empty")
        } else {
            section("Results", detail: resultsDetail(found: found.count), rows: shown, identifier: "exercise-result")
        }
    }

    private func section(_ title: String, detail: String?, rows: [ExerciseDefinition], identifier: String) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader(title, detail: detail)
                .padding(.top, LooprSpacing.xs)
            LooprCard(density: .flush) {
                LazyVStack(spacing: LooprSpacing.none) {
                    ForEach(Array(rows.enumerated()), id: \.element.key) { offset, definition in
                        resultRow(definition, identifier: "\(identifier)-\(offset)", isLast: offset == rows.count - 1)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier)-section")
    }

    /// "Showing 100 of 941" only when the list is cut, else the count.
    private func resultsDetail(found: Int) -> String {
        if found > Self.resultLimit { return "Showing \(Self.resultLimit) of \(found)" }
        return found == 1 ? "1 exercise" : "\(found) exercises"
    }

    private func resultRow(_ definition: ExerciseDefinition, identifier: String, isLast: Bool) -> some View {
        let alias = library.matchedAlias(of: definition, query: trimmedQuery).map { "Also called \($0)" }
        let detail = ([alias, definition.equipmentKind == .other ? nil : definition.equipmentKind.displayName] +
                      definition.primaryMuscles.prefix(2).map { TemplateBuilderFormat.capitalized($0) }).compactMap { $0 }
        return VStack(spacing: LooprSpacing.none) {
            Button {
                onPick(definition)
                dismiss()
            } label: {
                HStack(spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: LooprSpacing.xxs) {
                        Text(definition.name)
                            .looprTypography(.settingsRow)
                            .foregroundStyle(Color.loopr(.ink))
                            .fixedSize(horizontal: false, vertical: true)
                        if !detail.isEmpty {
                            Text(detail.joined(separator: " · "))
                                .looprTypography(.metricUnit)
                                .foregroundStyle(Color.loopr(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if definition.origin == .custom { StatusChip("Custom", symbol: nil, accent: .fitnessTab) }
                }
                .padding(.horizontal, LooprSpacing.cardHorizontal)
                .padding(.vertical, LooprSpacing.metricRowVertical)
                .frame(minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([definition.name] + detail + (definition.origin == .custom ? ["Custom"] : [])).joined(separator: ", "))
            .accessibilityHint("Adds it to the workout")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            if !isLast {
                Rectangle()
                    .fill(Color.loopr(.divider))
                    .frame(height: LooprSpacing.hairline)
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A filter chip: filled in the Fitness accent when on, a quiet capsule when off. Menu chips carry a chevron.
private struct ExercisePickerChipLabel: View {
    let title: String
    let selected: Bool
    let menu: Bool

    var body: some View {
        HStack(spacing: LooprSpacing.xxs) {
            Text(title)
            if menu {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
        .looprTypography(.chip)
        .foregroundStyle(selected ? LooprColorToken.fitnessTab.filledLabelColor : Color.loopr(.ink))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, LooprSpacing.sm)
        .frame(minHeight: 36)
        .background(selected ? Color.loopr(.fitnessTab) : Color.loopr(.surfaceElevated), in: Capsule(style: .continuous))
        .overlay {
            if !selected { Capsule(style: .continuous).strokeBorder(Color.loopr(.divider), lineWidth: LooprSpacing.hairline) }
        }
        .padding(.vertical, 4)
        .contentShape(Capsule(style: .continuous))
    }
}

/// Creates a custom exercise: a name, optional equipment and one primary muscle.
private struct CustomExerciseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var equipment = ExercisePickerScreen.anyChoice
    @State private var muscle = ExercisePickerScreen.anyChoice
    @State private var saving = false
    @State private var error: String?
    private let library: ExerciseLibrary
    private let create: @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition
    private let onCreated: (ExerciseDefinition) -> Void

    init(name: String, library: ExerciseLibrary, create: @escaping @Sendable (ExerciseDefinition) async throws -> ExerciseDefinition,
         onCreated: @escaping (ExerciseDefinition) -> Void) {
        _name = State(initialValue: String(name.prefix(80)))
        self.library = library
        self.create = create
        self.onCreated = onCreated
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var muscles: [String] { library.muscles }
    /// An exercise this name already means. Picking it keeps one lift under one name in history.
    private var existing: ExerciseDefinition? { library.existing(named: trimmedName) }

    private var equipmentOptions: [String] {
        [ExercisePickerScreen.anyChoice] + ExerciseEquipment.allCases.filter { $0 != .other }
            .sorted { $0.displayName < $1.displayName }.map(\.rawValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                    LooprCard(density: .flush) {
                        VStack(spacing: LooprSpacing.none) {
                            LooprTextFieldRow(title: "Name", placeholder: "Tempo squat", text: $name)
                                .accessibilityIdentifier("exercise-custom-name")
                            Rectangle()
                                .fill(Color.loopr(.divider))
                                .frame(height: LooprSpacing.hairline)
                                .padding(.horizontal, LooprSpacing.cardHorizontal)
                                .accessibilityHidden(true)
                            LooprPickerRow(title: "Equipment", selection: $equipment, options: equipmentOptions) { option in
                                option == ExercisePickerScreen.anyChoice ? "None" : ExerciseEquipment(dataset: option).displayName
                            }
                            .accessibilityIdentifier("exercise-custom-equipment")
                            Rectangle()
                                .fill(Color.loopr(.divider))
                                .frame(height: LooprSpacing.hairline)
                                .padding(.horizontal, LooprSpacing.cardHorizontal)
                                .accessibilityHidden(true)
                            LooprPickerRow(title: "Main muscle", selection: $muscle,
                                           options: [ExercisePickerScreen.anyChoice] + muscles) { option in
                                option == ExercisePickerScreen.anyChoice ? "None" : TemplateBuilderFormat.capitalized(option)
                            }
                            .accessibilityIdentifier("exercise-custom-muscle")
                        }
                    }
                    if let existing {
                        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                            LooprText("\(existing.name) is already in the list. Use it to keep its history in one place.",
                                      style: .prose, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Use \(existing.name)") { onCreated(existing) }
                                .buttonStyle(LooprButtonStyle(prominent: false, accent: .fitnessTab))
                                .disabled(saving)
                                .accessibilityIdentifier("exercise-custom-use-existing")
                        }
                        .accessibilityIdentifier("exercise-custom-existing")
                    }
                    if let error {
                        LooprText(error, style: .body, color: .critical)
                            .accessibilityIdentifier("exercise-custom-error")
                    }
                    Button(saving ? "Saving" : "Save exercise") { save() }
                        .buttonStyle(LooprButtonStyle(accent: .fitnessTab))
                        .disabled(saving || trimmedName.isEmpty)
                        .accessibilityIdentifier("exercise-custom-save")
                }
                .padding(.horizontal, LooprSpacing.screenGutter)
                .padding(.top, LooprSpacing.tabContentTop)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.loopr(.background))
            .navigationTitle("New exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("exercise-custom-cancel")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() {
        let definition = ExerciseDefinition.custom(
            name: trimmedName, equipment: equipment == ExercisePickerScreen.anyChoice ? nil : equipment,
            primaryMuscles: muscle == ExercisePickerScreen.anyChoice ? [] : [muscle])
        saving = true
        error = nil
        Task {
            do {
                let saved = try await create(definition)
                saving = false
                onCreated(saved)
            } catch {
                saving = false
                self.error = error.localizedDescription
            }
        }
    }
}
