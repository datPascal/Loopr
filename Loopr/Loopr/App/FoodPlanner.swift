import DesignSystem
import FoodKit
import SwiftUI

/// What the planner needs from the profile. Every field is optional: the planner asks for what is missing.
struct FoodSuggestionProfile: Equatable, Sendable {
    var age: Int?
    var sex: FoodGoalPlanner.Sex
    var heightCentimetres: Double?
    var weightKilograms: Double?
}

/// The goal planner: who the person is, where they want to be and how fast, worked out into a
/// daily target they can change before saving. Saving also writes age, sex, height and weight
/// back to the profile, and a changed weight to the weight log.
struct FoodPlannerView: View {
    @Environment(\.dismiss) private var dismiss
    let now: Date
    let calendar: Calendar
    let previous: FoodTargetSettings?
    let saveTarget: @MainActor @Sendable (FoodTargetSettings) async throws -> Void
    let saveProfile: @MainActor @Sendable (FoodSuggestionProfile) async throws -> Void
    let logWeight: @MainActor @Sendable (Double) async throws -> Void
    private let loadedProfile: FoodSuggestionProfile?
    private let latestWeight: Double?

    @State private var goal: FoodGoal
    @State private var age: String
    @State private var sex: FoodGoalPlanner.Sex
    @State private var height: String
    @State private var weight: String
    @State private var goalWeight: String
    @State private var pace: Double
    @State private var activity: FoodActivityLevel
    @State private var base: String
    @State private var protein: String
    @State private var carbs: String
    @State private var fat: String
    @State private var water: String
    /// True once the person typed their own numbers. The plan stops overwriting them.
    @State private var customized: Bool
    @State private var adjusts: Bool
    @State private var error: String?
    @State private var saving = false
    @State private var haptic: LooprHaptic?

    init(now: Date, calendar: Calendar, previous: FoodTargetSettings?, profile: FoodSuggestionProfile?, latestWeight: Double?,
         saveTarget: @escaping @MainActor @Sendable (FoodTargetSettings) async throws -> Void,
         saveProfile: @escaping @MainActor @Sendable (FoodSuggestionProfile) async throws -> Void,
         logWeight: @escaping @MainActor @Sendable (Double) async throws -> Void) {
        self.now = now; self.calendar = calendar; self.previous = previous
        self.saveTarget = saveTarget; self.saveProfile = saveProfile; self.logWeight = logWeight
        loadedProfile = profile; self.latestWeight = latestWeight
        let plan = previous?.plan
        let goal = previous?.goal ?? .maintain
        _goal = State(initialValue: goal)
        _age = State(initialValue: profile?.age.map(String.init) ?? "")
        _sex = State(initialValue: profile?.sex ?? .unspecified)
        _height = State(initialValue: FoodInput.text(profile?.heightCentimetres))
        _weight = State(initialValue: FoodInput.text(latestWeight ?? profile?.weightKilograms))
        _goalWeight = State(initialValue: FoodInput.text(plan?.goalWeightKg))
        _pace = State(initialValue: plan.map { $0.paceKgPerWeek > 0 ? $0.paceKgPerWeek : FoodGoalPlanner.defaultPace(for: goal) }
                      ?? FoodGoalPlanner.defaultPace(for: goal))
        _activity = State(initialValue: plan?.activity ?? .sitting)
        _base = State(initialValue: FoodInput.text(previous?.baseEnergy))
        _protein = State(initialValue: FoodInput.text(previous?.protein))
        _carbs = State(initialValue: FoodInput.text(previous?.carbs))
        _fat = State(initialValue: FoodInput.text(previous?.fat))
        _water = State(initialValue: FoodInput.text(previous?.waterMillilitres))
        // Numbers saved without the planner are the person's own; keep them until they choose the plan's.
        _customized = State(initialValue: previous != nil && plan == nil)
        _adjusts = State(initialValue: previous?.adjustsForActiveEnergy ?? false)
    }

    private var planner: FoodGoalPlanner? {
        FoodGoalPlanner(goal: goal, age: Int(age.trimmingCharacters(in: .whitespaces)), sex: sex,
                        heightCentimetres: FoodInput.parse(height), weightKilograms: FoodInput.parse(weight),
                        goalWeightKilograms: goal == .maintain ? nil : FoodInput.parse(goalWeight),
                        activity: activity, paceKgPerWeek: goal == .maintain ? 0 : pace)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LooprSpacing.lg) {
                goalSection
                aboutSection
                if goal != .maintain { targetSection }
                activitySection
                resultCard
                numbersSection
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        Toggle("Adjust for active energy", isOn: $adjusts).accessibilityIdentifier("food-adjust-energy")
                        LooprText("Your target leaves out workouts. Each day Loopr adds the planned session's calories. With this on, it uses the band's active energy instead when that is higher. It never adds both.",
                                  style: .body, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error { LooprText(error, style: .body, color: .critical).accessibilityIdentifier("food-plan-error") }
            }
            .padding(LooprSpacing.screenGutter)
        }

        // The number pads have no return key; dragging the form puts the keyboard away.
        .scrollDismissesKeyboard(.interactively)
        .background(Color.loopr(.background))
        .navigationTitle("Goal and targets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("food-cancel-plan") }
            // The title carries the calories Save will keep, so the number is in view while any field is edited.
            ToolbarItem(placement: .principal) { titleSummary }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving" : "Save", action: save)
                    .fontWeight(.semibold).tint(Color.loopr(.energy)).disabled(saving)
                    .accessibilityLabel("Save targets")
                    .accessibilityIdentifier("food-save-targets")
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { if base.isEmpty { applyPlan() } }
        .onChange(of: planner) { _, _ in if !customized { withAnimation(LooprMotion.stateChange) { applyPlan() } } }
        .sensoryFeedback(.selection, trigger: activity)
        .looprHaptic(haptic)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("food-planner")
    }

    // MARK: Sections

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your goal")
            HStack(spacing: LooprSpacing.sm) {
                goalTile(.lose, title: "Lose weight", symbol: "arrow.down.right")
                goalTile(.maintain, title: "Maintain", symbol: "equal")
                goalTile(.build, title: "Build muscle", symbol: "dumbbell.fill")
            }
            .sensoryFeedback(.selection, trigger: goal)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("food-goal")
        }
    }

    private func goalTile(_ value: FoodGoal, title: String, symbol: String) -> some View {
        let selected = goal == value
        return Button {
            guard value != goal else { return }
            withAnimation(LooprMotion.stateChange) {
                goal = value
                pace = FoodGoalPlanner.defaultPace(for: value)
            }
        } label: {
            VStack(spacing: LooprSpacing.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? LooprColorToken.energy.filledLabelColor : Color.loopr(.energy))
                    .frame(width: 40, height: 40)
                    .background(Color.loopr(.energy).opacity(selected ? 1 : 0.12), in: Circle())
                    .symbolEffect(.bounce, value: selected)
                Text(title).looprTypography(.label).foregroundStyle(Color.loopr(.ink))
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .padding(.vertical, LooprSpacing.md).padding(.horizontal, LooprSpacing.xxs)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(Color.loopr(selected ? .energy : .surface).opacity(selected ? 0.1 : 1),
                        in: RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous)
                    .strokeBorder(Color.loopr(selected ? .energy : .divider), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityLabel("Goal, \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("food-goal-\(value.rawValue)")
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("About you", detail: "Saved to your profile")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText("Sex", style: .settingsRow)
                        LooprChoiceControl("Sex", choices: [.init("female", title: "Female"), .init("male", title: "Male"), .init("unspecified", title: "Not set")],
                                           selection: sexID, accent: .energy, identifier: "food-plan-sex") { value in
                            sex = switch value { case "female": .female; case "male": .male; default: .unspecified }
                        }
                    }
                    .padding(LooprSpacing.md)
                    Divider()
                    field("Age", unit: "years", text: $age, id: "age", keyboard: .numberPad)
                    Divider()
                    field("Height", unit: "cm", text: $height, id: "height")
                    Divider()
                    field("Weight now", unit: "kg", text: $weight, id: "weight")
                }
            }
            if sex == .unspecified {
                LooprText("Without a sex the formula uses the midpoint between the female and male estimates.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sexID: String { switch sex { case .female: "female"; case .male: "male"; case .unspecified: "unspecified" } }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Where you want to get to", detail: "Optional. It gives you a date.")
            LooprCard(density: .flush) {
                VStack(alignment: .leading, spacing: 0) {
                    field("Goal weight", unit: "kg", text: $goalWeight, id: "goal-weight")
                    Divider()
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        LooprText("Pace, kg a week", style: .rowTitle)
                        LooprChoiceControl("Pace", choices: FoodGoalPlanner.paces(for: goal).map { .init(String($0), title: FoodGoalProgress.pace($0)) },
                                           selection: String(pace), accent: .energy, identifier: "food-plan-pace") { value in
                            if let value, let chosen = Double(value) { pace = chosen }
                        }
                        LooprText(paceCaption, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("food-plan-pace-caption")
                    }
                    .padding(LooprSpacing.md)
                }
            }
        }
    }

    private var paceCaption: String {
        let kcal = Int((pace * FoodGoalPlanner.energyPerKilogram / 7).rounded())
        let direction = goal == .lose ? "below" : "above"
        let advice = goal == .lose
            ? (pace <= 0.5 ? "Easier to keep up and keeps more muscle." : "Harder to keep up. Keep protein high and train with weights.")
            : (pace <= 0.25 ? "Slow gains keep most of the weight as muscle." : "Faster gains add more fat with the muscle.")
        return "About \(kcal.formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal a day \(direction) what keeps your weight steady. \(advice)"
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Day to day", detail: "Leave workouts out. Loopr adds them each day.")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    ForEach(FoodActivityLevel.allCases, id: \.self) { level in
                        Button { withAnimation(LooprMotion.stateChange) { activity = level } } label: {
                            HStack(spacing: LooprSpacing.sm) {
                                VStack(alignment: .leading, spacing: 2) {
                                    LooprText(level.title, style: .rowTitle)
                                    LooprText(level.detail, style: .caption, color: .inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: LooprSpacing.sm)
                                Image(systemName: activity == level ? "checkmark.circle.fill" : "circle")
                                    .looprTypography(.title)
                                    .foregroundStyle(Color.loopr(activity == level ? .energy : .inkTertiary))
                                    .contentTransition(.symbolEffect(.replace))
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, LooprSpacing.cardHorizontal).padding(.vertical, LooprSpacing.sm)
                            .frame(minHeight: LooprSpacing.interactiveRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.looprPressableRow)
                        .accessibilityAddTraits(activity == level ? .isSelected : [])
                        .accessibilityIdentifier("food-activity-\(level.rawValue)")
                        if level != FoodActivityLevel.allCases.last { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var resultCard: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your plan")
            LooprCard(style: .hero(.energy)) {
                if let planner {
                    VStack(alignment: .leading, spacing: LooprSpacing.md) {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                            Text(planner.baseEnergy.formatted(.number.precision(.fractionLength(0)).locale(LooprUnitFormatter.displayLocale)))
                                .font(.custom("SpaceGrotesk-SemiBold", size: 44, relativeTo: .largeTitle))
                                .foregroundStyle(Color.loopr(.ink))
                                .contentTransition(.numericText(value: planner.baseEnergy))
                            LooprText("kcal a day", style: .metricUnit, color: .inkSecondary)
                        }
                        .animation(LooprMotion.revealAnimation, value: planner.baseEnergy)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("food-plan-energy")
                        FoodMacroSplit(protein: planner.protein, carbs: planner.carbs, fat: planner.fat)
                        LooprText("\(Int(planner.protein)) g protein · \(Int(planner.carbs)) g carbs · \(Int(planner.fat)) g fat · \(FoodPlannerView.litres(planner.waterMillilitres)) water",
                                  style: .caption, color: .inkSecondary)
                            .accessibilityIdentifier("food-suggestion-values")
                        if let date = planner.goalDate(from: now, calendar: calendar), let target = FoodInput.parse(goalWeight) {
                            HStack(alignment: .top, spacing: LooprSpacing.sm) {
                                Image(systemName: "flag.checkered")
                                    .looprTypography(.title).foregroundStyle(Color.loopr(.energy))
                                    .accessibilityHidden(true)
                                LooprText("Reach \(FoodGoalProgress.kilograms(target)) kg around \(date.formatted(.dateTime.day().month(.wide).year())), in about \(Int(planner.weeksToGoal!.rounded(.up))) weeks.",
                                          style: .rowTitle)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(LooprSpacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.loopr(.energy).opacity(0.08), in: RoundedRectangle(cornerRadius: LooprRadius.control, style: .continuous))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("food-plan-date")
                        }
                        if planner.isAtMinimum {
                            LooprInlineMessage("This stops at \(Int(planner.minimumEnergy).formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal, the lowest Loopr suggests without a doctor or dietitian. You lose more slowly than the pace you chose.", tone: .warning)
                        } else if planner.isFastLoss {
                            LooprInlineMessage("That is more than 1% of your weight a week. It is hard to keep up and costs muscle. 0.5 kg a week is a good place to start.", tone: .warning)
                        }
                        DisclosureGroup {
                            LooprText(explanation(planner), style: .caption, color: .inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, LooprSpacing.xs)
                        } label: {
                            LooprText("How Loopr worked this out", style: .rowTitle, color: .inkSecondary)
                        }
                        .tint(Color.loopr(.inkSecondary))
                    }
                } else {
                    LooprText("Add your age, height and weight to see your plan. You can also type your own numbers below.",
                              style: .prose, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("food-suggestion-missing")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("food-plan-result")
        }
    }

    private var titleSummary: some View {
        VStack(spacing: 0) {
            Text("Goal and targets").looprTypography(.rowTitle).foregroundStyle(Color.loopr(.ink))
            if let energy = FoodInput.parse(base) {
                Text("\(energy.formatted(.number.precision(.fractionLength(0)).locale(LooprUnitFormatter.displayLocale))) kcal a day")
                    .looprTypography(.caption).foregroundStyle(Color.loopr(.energy))
                    .contentTransition(.numericText(value: energy))
                    .animation(LooprMotion.revealAnimation, value: energy)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func explanation(_ planner: FoodGoalPlanner) -> String {
        let change = planner.baseEnergy - planner.maintenanceEnergy
        let goalText = change < 0 ? "Your target is \(Int(-change).formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal below that." : change > 0 ? "Your target is \(Int(change).formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal above that." : "Your target matches it."
        let perKilo = planner.goal == .lose ? "2" : planner.goal == .build ? "1.8" : "1.6"
        let weightBase = planner.goal == .lose && (FoodInput.parse(goalWeight) ?? .infinity) < (FoodInput.parse(weight) ?? 0) ? "your goal weight" : "your weight"
        return "On a day without a workout you burn about \(Int(planner.maintenanceEnergy).formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal. That is \(Int(planner.restingEnergy).formatted(.number.locale(LooprUnitFormatter.displayLocale))) at rest, from the Mifflin-St Jeor formula, plus everyday movement. \(goalText) Protein is \(perKilo) g per kg of \(weightBase), fat is a quarter of the calories and carbs make up the rest."
    }

    private var numbersSection: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Your daily targets", detail: customized ? "Your own numbers" : "From your plan. Change any of them.")
            LooprCard(density: .flush) {
                VStack(spacing: 0) {
                    field("Calories", unit: "kcal", text: edited($base), id: "base")
                    Divider()
                    field("Protein", unit: "g", text: edited($protein), id: "protein")
                    Divider()
                    field("Carbs", unit: "g", text: edited($carbs), id: "carbs")
                    Divider()
                    field("Fat", unit: "g", text: edited($fat), id: "fat")
                    Divider()
                    field("Water", unit: "ml", text: edited($water), id: "water")
                }
            }
            if customized, planner != nil {
                Button("Use the plan's numbers") { customized = false; applyPlan() }
                    .buttonStyle(LooprButtonStyle(prominent: false, accent: .energy))
                    .accessibilityIdentifier("food-use-suggestion")
            }
            LooprText(macroCheck, style: .caption, color: .inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("food-macro-check")
        }
    }

    /// Says when the macros add up to more or fewer calories than the calorie target.
    private var macroCheck: String {
        guard let energy = FoodInput.parse(base), let p = FoodInput.parse(protein), let c = FoodInput.parse(carbs), let f = FoodInput.parse(fat) else {
            return "Protein and carbs have 4 kcal per gram, fat has 9."
        }
        let total = p * 4 + c * 4 + f * 9
        let gap = total - energy
        if abs(gap) <= max(energy * 0.05, 50) { return "Protein, carbs and fat add up to \(Int(total).formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal, in line with your calories." }
        return "Protein, carbs and fat add up to \(Int(total).formatted(.number.locale(LooprUnitFormatter.displayLocale))) kcal, \(Int(abs(gap)).formatted(.number.locale(LooprUnitFormatter.displayLocale))) \(gap > 0 ? "more" : "fewer") than your calorie target."
    }

    // MARK: Helpers

    private func edited(_ binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; customized = true })
    }

    private func field(_ title: String, unit: String, text: Binding<String>, id: String, keyboard: UIKeyboardType = .decimalPad) -> some View {
        LooprTextFieldRow(title: "\(title), \(unit)", placeholder: "Not set", text: text)
            .keyboardType(keyboard)
            .accessibilityIdentifier("food-target-\(id)")
    }

    private func applyPlan() {
        guard let planner else { return }
        base = FoodInput.text(planner.baseEnergy); protein = FoodInput.text(planner.protein)
        carbs = FoodInput.text(planner.carbs); fat = FoodInput.text(planner.fat); water = FoodInput.text(planner.waterMillilitres)
    }

    static func litres(_ millilitres: Double) -> String {
        (millilitres / 1000).formatted(.number.precision(.fractionLength(0...2)).locale(LooprUnitFormatter.displayLocale)) + " L"
    }

    private func save() {
        error = nil
        do {
            guard let energy = try FoodInput.number(base), energy >= 500, energy <= 10_000 else {
                haptic = .error; error = "Set a calorie target between 500 and 10,000 kcal."; return
            }
            let typedWeight = FoodInput.parse(weight)
            let plan: FoodGoalPlan? = planner.flatMap { _ -> FoodGoalPlan? in
                guard let typedWeight else { return nil }
                let target = goal == .maintain ? nil : FoodInput.parse(goalWeight)
                // Editing the plan keeps its starting weight while the goal stays the same, so progress does not reset.
                let start = previous?.plan.flatMap { $0.goalWeightKg == target && previous?.goal == goal ? $0.startWeightKg : nil } ?? typedWeight
                return FoodGoalPlan(startWeightKg: start, goalWeightKg: target, paceKgPerWeek: goal == .maintain ? 0 : pace, activity: activity)
            }
            let target = FoodTargetSettings(goal: goal, baseEnergy: energy, protein: try FoodInput.number(protein, optional: true),
                                            carbs: try FoodInput.number(carbs, optional: true), fat: try FoodInput.number(fat, optional: true),
                                            waterMillilitres: try FoodInput.number(water, optional: true),
                                            adjustsForActiveEnergy: adjusts, confirmedAt: now, plan: plan)
            try target.validate()
            let about = FoodSuggestionProfile(age: Int(age.trimmingCharacters(in: .whitespaces)), sex: sex,
                                              heightCentimetres: FoodInput.parse(height), weightKilograms: typedWeight)
            saving = true
            Task {
                defer { saving = false }
                do {
                    try await saveTarget(target)
                    if about != loadedProfile { try await saveProfile(about) }
                    if let typedWeight, FoodWeightEntry.validRange.contains(typedWeight),
                       latestWeight.map({ abs($0 - typedWeight) >= 0.05 }) ?? true {
                        try await logWeight(typedWeight)
                    }
                    dismiss()
                } catch { haptic = .error; self.error = error.localizedDescription }
            }
        } catch { haptic = .error; self.error = "Check the numbers. Use digits only, like 2100 or 82.5." }
    }
}
