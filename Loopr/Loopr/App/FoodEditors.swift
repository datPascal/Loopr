import DesignSystem
import FoodKit
import SwiftUI

nonisolated enum FoodInput {
    /// Prefilled values use the phone's decimal separator, so a German keypad's comma and the shown value match.
    static func text(_ value: Double?, locale: Locale = .current) -> String {
        guard let value else { return "" }
        let plain = String(format: "%g", value)
        return locale.decimalSeparator == "," ? plain.replacingOccurrences(of: ".", with: ",") : plain
    }
    /// Reads "2.5" and "2,5" alike: the decimal keypad types a comma in many locales.
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    static func number(_ text: String, optional: Bool = false) throws -> Double? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty && optional { return nil }
        guard let value = parse(raw), value.isFinite, value >= 0 else { throw FoodError.invalidRecord }
        return value
    }
}

struct FoodDrinkEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    let kind: FoodDrinkKind
    let now: Date
    let calendar: Calendar
    // Keep UI isolation explicit across the stored async callback.
    let save: @MainActor @Sendable (FoodDrink) async throws -> Void
    let delete: @MainActor @Sendable (FoodDrink) async throws -> Void
    /// Drinks of this kind already logged on the day, so a mistaken one can be removed here.
    @State private var logged: [FoodDrink]
    @State private var pendingDelete: FoodDrink?
    @State private var name: String
    @State private var occurredAt: Date
    @State private var amount = ""
    @State private var energy = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var preset: FoodDrinkPreset?
    @State private var error: String?
    @State private var saving = false
    @State private var haptic: LooprHaptic?
    init(kind: FoodDrinkKind, date: Date, now: Date, calendar: Calendar, logged: [FoodDrink] = [],
         delete: @escaping @MainActor @Sendable (FoodDrink) async throws -> Void = { _ in },
         save: @escaping @MainActor @Sendable (FoodDrink) async throws -> Void) {
        self.kind = kind; self.now = now; self.calendar = calendar; self.save = save; self.delete = delete
        _logged = State(initialValue: logged.filter { $0.kind == kind }.sorted { $0.occurredAt < $1.occurredAt })
        _name = State(initialValue: kind == .water ? "Water" : "")
        _occurredAt = State(initialValue: calendar.isDate(date, inSameDayAs: now) ? now : date)
    }

    private var accent: LooprColorToken { kind == .water ? .brand : kind == .caffeine ? .energy : .heart }
    private var unit: String { kind == .water ? "ml" : kind == .caffeine ? "mg" : "units" }
    /// How far one press of minus or plus moves the amount.
    private var step: Double { kind == .water ? 50 : kind == .caffeine ? 10 : 0.1 }

    var body: some View {
        let input = FoodDrinkFormInput(kind: kind, name: name, amount: amount, energy: energy,
            protein: protein, carbs: carbs, fat: fat, occurredAt: occurredAt)
        return ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                presets
                amountCard
                if kind != .water { details }
                LooprCard {
                    DatePicker("Time", selection: $occurredAt, displayedComponents: .hourAndMinute)
                        .looprTypography(.settingsRow)
                        .accessibilityIdentifier("food-drink-time")
                }
                if kind == .alcohol {
                    LooprText("One unit is 10 g of pure alcohol. The presets are typical drinks, so check the label on yours. A glass is not a fixed unit.",
                              style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if kind == .caffeine {
                    LooprText("The presets use typical caffeine and calories. Change them to match your drink.", style: .caption, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error { LooprText(error, style: .body, color: .critical).accessibilityIdentifier("food-editor-error") }
                if !logged.isEmpty { loggedList }
            }
            .padding(LooprSpacing.screenGutter)
            .animation(LooprMotion.stateChange, value: logged.map(\.id))
        }
        // The number pads have no return key; dragging the form puts the keyboard away.
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button(saving ? "Saving" : addTitle) {
                do {
                    // Snapshot the visible fields before starting the write.
                    let drink = try input.drink(now: now, timeZoneIdentifier: calendar.timeZone.identifier)
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do { try await save(drink); dismiss() }
                        catch { haptic = .error; self.error = error.localizedDescription }
                    }
                } catch { haptic = .error; self.error = kind == .water ? "Enter how much you drank, like 250." : "Enter the amount, like \(kind == .caffeine ? "95" : "1.5")." }
            }
            .buttonStyle(LooprButtonStyle(accent: accent)).disabled(saving)
            .accessibilityIdentifier("food-save-drink")
            .padding(.horizontal, LooprSpacing.screenGutter).padding(.top, LooprSpacing.sm).padding(.bottom, LooprSpacing.xs)
            .background(Color.loopr(.background).opacity(0.94))
        }
        .background(Color.loopr(.background)).navigationTitle("Add \(kind.rawValue)")
        .navigationBarTitleDisplayMode(.inline)
        .looprHaptic(haptic)
        .confirmationDialog("Delete \(pendingDelete?.name ?? "this drink")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { drink in
            Button("Delete", role: .destructive) {
                saving = true; error = nil
                Task {
                    defer { saving = false }
                    do {
                        try await delete(drink)
                        withAnimation(LooprMotion.stateChange) { logged.removeAll { $0.id == drink.id } }
                    }
                    catch { self.error = error.localizedDescription }
                }
            }.accessibilityIdentifier("food-confirm-delete-drink")
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("It leaves this day's food log.") }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-cancel-drink") } }
        .interactiveDismissDisabled(saving)
    }

    private var addTitle: String {
        guard let value = FoodInput.parse(amount), value > 0 else { return "Add \(kind == .water ? "water" : "drink")" }
        if kind == .water { return "Add \(FoodInput.text(value)) ml" }
        return "Add \(name.trimmingCharacters(in: .whitespaces).isEmpty ? FoodInput.text(value) + " " + unit : name)"
    }

    private var loggedToday: String? {
        guard !logged.isEmpty else { return nil }
        let total: Double = logged.reduce(0) { sum, drink in
            sum + (kind == .water ? drink.waterMillilitres ?? 0 : kind == .caffeine ? drink.caffeineMilligrams ?? 0 : drink.alcoholUnits ?? 0)
        }
        let shown = ((total * 10).rounded() / 10).formatted(.number.precision(.fractionLength(0...1)).locale(LooprUnitFormatter.displayLocale))
        return "\(shown) \(unit) so far this day"
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Common drinks", detail: loggedToday)
            let presets = FoodDrinkPreset.presets(for: kind)
            let perRow = dynamicType.isAccessibilitySize ? 2 : 3
            Grid(horizontalSpacing: LooprSpacing.sm, verticalSpacing: LooprSpacing.sm) {
                ForEach(Array(stride(from: 0, to: presets.count, by: perRow)), id: \.self) { start in
                    GridRow {
                        ForEach(presets[start..<min(start + perRow, presets.count)]) { presetTile($0) }
                        // Keeps a short last row's tiles the same width as the rows above.
                        ForEach(0..<(perRow - min(perRow, presets.count - start)), id: \.self) { _ in Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
    }

    private func presetTile(_ option: FoodDrinkPreset) -> some View {
        let selected = preset == option
        return Button { choose(option) } label: {
            VStack(spacing: LooprSpacing.xxs) {
                Image(systemName: option.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.loopr(accent))
                    .symbolEffect(.bounce, value: selected)
                    .frame(height: 26)
                LooprText(option.name, style: .rowTitle).lineLimit(1).minimumScaleFactor(0.8)
                LooprText(option.serving, style: .caption, color: .inkSecondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.vertical, LooprSpacing.sm).padding(.horizontal, LooprSpacing.xxs)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(Color.loopr(selected ? accent : .surface).opacity(selected ? 0.12 : 1),
                        in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous)
                    .strokeBorder(Color.loopr(selected ? accent : .divider), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
        }
        .buttonStyle(.looprPressableCard)
        .animation(LooprMotion.stateChange, value: selected)
        .accessibilityLabel("\(option.name), \(option.serving)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("food-drink-preset-\(option.name.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private func choose(_ option: FoodDrinkPreset) {
        haptic = .light
        preset = option
        amount = FoodInput.text(option.amount)
        if kind != .water {
            name = option.name
            energy = FoodInput.text(option.energy)
            protein = FoodInput.text(option.protein); carbs = FoodInput.text(option.carbs); fat = FoodInput.text(option.fat)
        }
    }

    private var amountCard: some View {
        LooprCard {
            HStack(spacing: LooprSpacing.md) {
                stepButton(-1)
                VStack(spacing: 2) {
                    TextField("0", text: Binding(get: { amount }, set: { amount = $0; preset = nil }))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .font(.custom("SpaceGrotesk-SemiBold", size: 44, relativeTo: .largeTitle))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Color.loopr(.ink))
                        .tint(Color.loopr(accent))
                        .accessibilityLabel(kind == .water ? "Water, ml" : kind == .caffeine ? "Caffeine, mg" : "Alcohol units")
                        .accessibilityIdentifier("food-drink-amount")
                    LooprText(kind == .water ? "millilitres" : kind == .caffeine ? "mg caffeine" : "units of alcohol", style: .caption, color: .inkSecondary)
                }
                .frame(maxWidth: .infinity)
                stepButton(1)
            }
        }
    }

    private func stepButton(_ direction: Double) -> some View {
        Button {
            let current = FoodInput.parse(amount) ?? 0
            let next = max(0, ((current + direction * step) / step).rounded() * step)
            withAnimation(LooprMotion.stateChange) { amount = next == 0 ? "" : FoodInput.text((next * 10).rounded() / 10) }
            preset = nil
            haptic = .light
        } label: {
            Image(systemName: direction < 0 ? "minus" : "plus")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.loopr(accent))
                .frame(width: 44, height: 44)
                .background(Color.loopr(accent).opacity(0.12), in: Circle())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityLabel(direction < 0 ? "Less, \(FoodInput.text(step)) \(unit)" : "More, \(FoodInput.text(step)) \(unit)")
    }

    private var details: some View {
        LooprCard(density: .flush) {
            VStack(spacing: 0) {
                LooprTextFieldRow(title: "Drink", placeholder: "Name", text: $name).accessibilityIdentifier("food-drink-name")
                Divider()
                LooprTextFieldRow(title: "Energy, kcal", placeholder: "Unknown", text: $energy).keyboardType(.decimalPad).accessibilityIdentifier("food-drink-energy")
                Divider()
                LooprTextFieldRow(title: "Protein, g", placeholder: "Unknown", text: $protein).keyboardType(.decimalPad).accessibilityIdentifier("food-drink-protein")
                Divider()
                LooprTextFieldRow(title: "Carbs, g", placeholder: "Unknown", text: $carbs).keyboardType(.decimalPad).accessibilityIdentifier("food-drink-carbs")
                Divider()
                LooprTextFieldRow(title: "Fat, g", placeholder: "Unknown", text: $fat).keyboardType(.decimalPad).accessibilityIdentifier("food-drink-fat")
            }
        }
    }

    private var loggedList: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprSectionHeader("Logged this day")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(logged) { drink in
                        HStack(spacing: LooprSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                LooprText(drink.name, style: .body)
                                LooprText("\(Self.amount(drink)) · \(drink.occurredAt.formatted(date: .omitted, time: .shortened))", style: .caption, color: .inkSecondary)
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: 0)
                            Button("Delete \(drink.name)", systemImage: "trash", role: .destructive) { pendingDelete = drink }
                                .labelStyle(.iconOnly).foregroundStyle(Color.loopr(.critical))
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                .disabled(saving).accessibilityIdentifier("food-delete-drink-\(drink.id)")
                        }
                        .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.xs)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                        if drink.id != logged.last?.id { Divider().padding(.horizontal, LooprSpacing.cardHorizontal) }
                    }
                }
            }
        }
    }

    static func amount(_ drink: FoodDrink) -> String {
        switch drink.kind {
        case .water: "\(FoodInput.text(drink.waterMillilitres)) ml"
        case .caffeine: "\(FoodInput.text(drink.caffeineMilligrams)) mg caffeine"
        case .alcohol: drink.alcoholUnits == 1 ? "1 unit" : "\(FoodInput.text(drink.alcoholUnits)) units"
        }
    }
}

/// One day's settings: why the target is what it is, the training allowance planned for it, and Done for today. The
/// goal and daily targets live in the planner, which this sheet links to.
struct FoodDayEditor: View {
    @Environment(\.dismiss) private var dismiss
    let date: Date
    let now: Date
    let calendar: Calendar
    let repository: AppFoodRepository
    let didSave: @MainActor @Sendable () async -> Void
    let openPlan: @MainActor () -> Void
    /// The tab's own Done for today: it closes this sheet, then asks or finishes as the Meals row does.
    let finish: @MainActor () -> Void
    let actualStrain: FoodStrain?
    private let target: FoodTarget?
    private let isToday: Bool
    private let completed: Bool
    @State private var planName: String
    @State private var allowance: String
    @State private var strain: String
    @State private var error: String?
    @State private var saving = false
    init(day: FoodDaySummary?, date: Date, now: Date, calendar: Calendar, repository: AppFoodRepository, isToday: Bool,
         openPlan: @escaping @MainActor () -> Void, finish: @escaping @MainActor () -> Void,
         didSave: @escaping @MainActor @Sendable () async -> Void) {
        self.date = date; self.now = now; self.calendar = calendar; self.repository = repository; self.didSave = didSave
        self.openPlan = openPlan; self.finish = finish; self.isToday = isToday
        actualStrain = day?.target.actualStrain
        target = day?.target
        completed = day?.isCompleted ?? false
        _planName = State(initialValue: day?.record?.allowance?.title ?? "")
        _allowance = State(initialValue: FoodInput.text(day?.record?.allowance?.energy))
        _strain = State(initialValue: FoodInput.text(day?.record?.allowance?.plannedStrain?.value))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                // Why today's target is what it is, such as the planned training allowance. It moved here from under
                // the rings (UX R2-DES-01, R2-DES-12).
                if let target {
                    LooprText(target.reason, style: .prose, color: .ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("food-day-reason")
                }
                Button { openPlan() } label: {
                    HStack(spacing: LooprSpacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            LooprText("Goal and daily targets", style: .rowTitle)
                            LooprText("Calories, protein, carbs, fat and water for every day", style: .caption, color: .inkSecondary)
                        }
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                    .padding(.horizontal, LooprSpacing.cardHorizontal)
                    .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                    .looprCardBackground()
                }
                .buttonStyle(.looprPressableCard).accessibilityIdentifier("food-day-open-plan")
                LooprSectionHeader("Planned effort", detail: "Extra calories for training on \(date.formatted(date: .abbreviated, time: .omitted))")
                LooprCard(density: .flush) {
                    VStack(spacing: 0) {
                    LooprTextFieldRow(title: "Session", placeholder: "Optional", text: $planName).accessibilityIdentifier("food-plan-name")
                    field("Allowance, kcal", text: $allowance, id: "allowance")
                    field("Planned strain, /21", text: $strain, id: "strain")
                    }
                }
                if let actualStrain {
                    LooprText("Actual strain \(FoodInput.text(actualStrain.value)) / \(FoodInput.text(actualStrain.scale.maximum)). Strain alone does not change calories.", style: .body, color: .inkSecondary)
                }
                LooprText("The weekly count calls a finished day on target when its calories are within 5% of that day's target.", style: .caption, color: .inkSecondary)
                if let error { LooprText(error, style: .body, color: .critical) }
                Button(saving ? "Saving" : "Save this day") {
                    Task {
                        saving = true; defer { saving = false }
                        do {
                            let planned = try FoodInput.number(allowance, optional: true)
                            let plannedStrain = try FoodInput.number(strain, optional: true).map { FoodStrain(value: $0, scale: .daily21) }
                            if planned == nil && (!planName.isEmpty || plannedStrain != nil) { throw FoodError.invalidRecord }
                            let plan = planned.map { FoodTrainingAllowance(title: planName, energy: $0, plannedStrain: plannedStrain, confirmedAt: now) }
                            try await repository.confirmAllowance(plan, on: date, zone: calendar.timeZone.identifier)
                            await didSave(); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(LooprButtonStyle(accent: .energy)).disabled(saving).accessibilityIdentifier("food-save-day")
                // The same action, under the same name, as the row under Meals (UX R2-DES-12, R2-MAC-10, R2-NEW-07). It
                // stays here on a day with nothing logged, so a day without food can still be finished.
                doneRow
            }.padding(LooprSpacing.screenGutter)
        }
        // The number pads have no return key; dragging the form puts the keyboard away.
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background)).navigationTitle("This day").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-cancel-targets") } }
        .interactiveDismissDisabled(saving)
    }

    private var doneRow: some View {
        let title = FoodScreen.doneTitle(isToday: isToday)
        return Button(action: finish) {
            HStack(spacing: LooprSpacing.sm) {
                Image(systemName: completed ? "checkmark.circle.fill" : "checkmark.circle")
                    .looprTypography(.title).foregroundStyle(Color.loopr(.brand))
                    .accessibilityHidden(true)
                LooprText(title, style: .rowTitle)
                Spacer(minLength: LooprSpacing.sm)
                if completed { LooprText("Reopen", style: .label, color: .energy) }
            }
            .padding(.horizontal, LooprSpacing.cardHorizontal)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
            .looprCardBackground()
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .disabled(saving)
        .accessibilityLabel(completed ? "\(title), finished. Reopen" : title)
        .accessibilityHint(completed ? "Asks before reopening this day's log" : "Finishes this day's log")
        .accessibilityIdentifier("food-complete-day")
    }

    private func field(_ title: String, text: Binding<String>, id: String) -> some View {
        LooprTextFieldRow(title: title, placeholder: "Not set", text: text).keyboardType(.decimalPad).accessibilityIdentifier("food-target-\(id)")
    }
}

/// Logs a body weight and lists recent readings, so a wrong one can be removed.
struct FoodWeightEditor: View {
    @Environment(\.dismiss) private var dismiss
    let now: Date
    let calendar: Calendar
    let save: @MainActor @Sendable (FoodWeightEntry) async throws -> Void
    let delete: @MainActor @Sendable (FoodWeightEntry) async throws -> Void
    @State private var entries: [FoodWeightEntry]
    @State private var kilograms: String
    @State private var measuredAt: Date
    @State private var error: String?
    @State private var saving = false
    @State private var pendingDelete: FoodWeightEntry?
    @State private var haptic: LooprHaptic?
    @FocusState private var focused: Bool

    init(now: Date, calendar: Calendar, entries: [FoodWeightEntry],
         save: @escaping @MainActor @Sendable (FoodWeightEntry) async throws -> Void,
         delete: @escaping @MainActor @Sendable (FoodWeightEntry) async throws -> Void) {
        self.now = now; self.calendar = calendar; self.save = save; self.delete = delete
        let sorted = entries.sorted { $0.measuredAt > $1.measuredAt }
        _entries = State(initialValue: sorted)
        _kilograms = State(initialValue: FoodInput.text(sorted.first?.kilograms))
        _measuredAt = State(initialValue: now)
    }

    /// The ruler's reading: the typed number, or the last reading before anything is typed.
    private var rulerValue: Binding<Double> {
        Binding(get: { FoodInput.parse(kilograms) ?? entries.first?.kilograms ?? 75 },
                set: { kilograms = FoodInput.text(($0 * 10).rounded() / 10) })
    }

    private var change: String? {
        guard let typed = FoodInput.parse(kilograms), let last = entries.first, FoodWeightEntry.validRange.contains(typed) else { return nil }
        let delta = typed - last.kilograms
        if abs(delta) < 0.05 { return "Same as \(last.measuredAt.formatted(.dateTime.day().month(.abbreviated)))" }
        return "\(FoodGoalProgress.signedKilograms(delta)) kg since \(last.measuredAt.formatted(.dateTime.day().month(.abbreviated)))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                LooprCard {
                    VStack(spacing: LooprSpacing.md) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xs) {
                            TextField("–", text: $kilograms)
                                .keyboardType(.decimalPad)
                                .focused($focused)
                                .font(.custom("SpaceGrotesk-SemiBold", size: 56, relativeTo: .largeTitle))
                                .monospacedDigit()
                                .multilineTextAlignment(.center)
                                .contentTransition(.numericText())
                                .fixedSize()
                                .accessibilityLabel("Weight in kilograms")
                                .accessibilityIdentifier("food-weight-value")
                            LooprText("kg", style: .title, color: .inkSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        LooprText(change ?? (kilograms.isEmpty ? "Drag the scale to your weight, or tap the dash to type it" : "Drag the scale or tap the number to type"),
                                  style: .caption, color: .inkSecondary)
                            .contentTransition(.opacity)
                            .animation(LooprMotion.stateChange, value: change)
                        LooprRulerPicker("Weight", value: rulerValue, in: 30...250, unit: "kilograms", accent: .energy)
                    }
                    .padding(.vertical, LooprSpacing.xs)
                }
                LooprCard {
                    DatePicker("Time", selection: $measuredAt, in: ...now)
                        .looprTypography(.settingsRow)
                        .accessibilityIdentifier("food-weight-time")
                }
                LooprText("Weigh at the same time of day, ideally in the morning before eating, for readings you can compare.",
                          style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error { LooprText(error, style: .body, color: .critical).accessibilityIdentifier("food-weight-error") }
                if !entries.isEmpty { history }
            }
            .padding(LooprSpacing.screenGutter)
            .animation(LooprMotion.stateChange, value: entries.map(\.id))
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button(saving ? "Saving" : "Save weight", action: submit)
                .buttonStyle(LooprButtonStyle(accent: .energy)).disabled(saving)
                .accessibilityIdentifier("food-save-weight")
                .padding(.horizontal, LooprSpacing.screenGutter).padding(.top, LooprSpacing.sm).padding(.bottom, LooprSpacing.xs)
                .background(Color.loopr(.background).opacity(0.94))
        }
        .background(Color.loopr(.background))
        .navigationTitle("Log weight")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-cancel-weight") } }
        .looprHaptic(haptic)
        .confirmationDialog("Delete this reading?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await delete(entry)
                        withAnimation(LooprMotion.stateChange) { entries.removeAll { $0.id == entry.id } }
                    }
                    catch { self.error = error.localizedDescription }
                }
            }.accessibilityIdentifier("food-confirm-delete-weight")
            Button("Cancel", role: .cancel) {}
        } message: { entry in Text("\(FoodGoalProgress.kilograms(entry.kilograms)) kg on \(entry.measuredAt.formatted(date: .abbreviated, time: .shortened))") }
        .interactiveDismissDisabled(saving)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.sm) {
            LooprSectionHeader("Recent")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    let shown = Array(entries.prefix(30))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: LooprSpacing.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                LooprText("\(FoodGoalProgress.kilograms(entry.kilograms)) kg", style: .rowTitle)
                                LooprText(entry.measuredAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()), style: .caption, color: .inkSecondary)
                            }
                            Spacer(minLength: 0)
                            if index + 1 < shown.count {
                                let delta = entry.kilograms - shown[index + 1].kilograms
                                LooprText(abs(delta) < 0.05 ? "±0" : FoodGoalProgress.signedKilograms(delta), style: .metricUnit, color: .inkSecondary)
                            }
                            Button("Delete \(FoodGoalProgress.kilograms(entry.kilograms)) kg", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                                .labelStyle(.iconOnly).foregroundStyle(Color.loopr(.critical))
                                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                                .accessibilityIdentifier("food-delete-weight-\(entry.id)")
                        }
                        .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.xxs)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                        if entry.id != shown.last?.id { Divider().padding(.horizontal, LooprSpacing.cardHorizontal) }
                    }
                }
            }
        }
    }

    private func submit() {
        error = nil
        guard let value = FoodInput.parse(kilograms), FoodWeightEntry.validRange.contains(value) else {
            haptic = .error
            error = "Enter your weight in kilograms, like 78.4."; return
        }
        do {
            let entry = try FoodWeightEntry(measuredAt: measuredAt, timeZoneIdentifier: calendar.timeZone.identifier, kilograms: value)
            saving = true
            Task {
                defer { saving = false }
                do { try await save(entry); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
