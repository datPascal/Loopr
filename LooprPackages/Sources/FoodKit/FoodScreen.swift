import DesignSystem
import SwiftUI

public enum FoodOverviewAction {
    /// `log` opens the camera, which reads a plate or a barcode. `voice` and `manual` open the text entry for the
    /// suggested slot, `typeMeal` for a given one. `repeatMeal` opens the repeat picker.
    case log(FoodMealSlot), voice, manual, typeMeal(FoodMealSlot), repeatMeal, edit(FoodMeal)
    /// Logs a copy of a meal in its slot at once, with Undo.
    case again(FoodMeal)
    /// Logs a copy of a drink at once, with Undo: what a drink row's plus repeats.
    case repeatDrink(FoodDrink)
    /// `targets` opens this day's sheet. `plan` opens the goal and daily targets.
    case drink(FoodDrinkKind), targets, plan, logWeight, associations
    /// Asks to finish the day, settling alcohol in the same step, or to reopen a finished day.
    case completion
    /// Opens the Week page.
    case week
    /// Logs a common drink at once, such as the last coffee preset.
    case quickDrink(FoodDrinkPreset)
    /// `stackTick` takes or clears one dose on today's stack. `editStack` opens the stack editor, `plants` the week's plants.
    case stackTick(FoodCapsule), editStack, plants
}

public extension FoodNutrient {
    /// Each macro keeps one colour wherever it is drawn: protein red, carbs teal, fat violet.
    var accent: LooprColorToken {
        switch self {
        case .protein: .heart
        case .carbs: .brand
        case .fat: .sleep
        default: .energy
        }
    }
}

public struct FoodScreen: View {
    @Environment(\.looprDayNavigation) private var navigation
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    private let day: FoodDaySummary?
    private let week: [FoodDaySummary]
    private let photos: [UUID: Image]
    private let error: String?
    private let targetWarning: String?
    private let weightTrend: FoodWeightTrend?
    private let now: Date
    private let longevity: FoodLongevity
    /// Whether a photo estimate can run: false with no AI key saved, nil until that is known.
    private let photoEstimates: Bool?
    /// Finished days in the window Food and your body reads. Nil when the count could not be read.
    private let finishedDays: Int?
    private let action: (FoodOverviewAction) -> Void
    private let retry: () -> Void
    @State private var taps = 0
    /// True while the tab plays its entrance, once per local day (`LooprEntranceStore`).
    @State private var entrance = false
    /// False for the moment the entrance starts, so the calorie count rolls up as the rings draw.
    @State private var arrived = true
    /// Debug captures (`-loopr-open-folds YES`) show the Week page's content under the week strip, so a screenshot
    /// tour reaches it without a push.
    private let showsWeekInline = LooprFoldSummary.opensForCapture

    public init(day: FoodDaySummary?, week: [FoodDaySummary], photos: [UUID: Image] = [:],
                error: String? = nil, targetWarning: String? = nil, weightTrend: FoodWeightTrend? = nil, now: Date = Date(),
                longevity: FoodLongevity = .init(), photoEstimates: Bool? = nil, finishedDays: Int? = nil,
                action: @escaping (FoodOverviewAction) -> Void, retry: @escaping () -> Void) {
        self.day = day; self.week = week; self.photos = photos; self.error = error
        self.action = action; self.retry = retry
        self.targetWarning = targetWarning
        self.weightTrend = weightTrend; self.now = now
        self.longevity = longevity; self.photoEstimates = photoEstimates; self.finishedDays = finishedDays
    }

    public var body: some View {
        LooprTabScaffold(header: .init(title: "Food", accent: .energy, dayPhrase: metaLine,
            control: navigation.map(LooprHeaderControl.day) ?? .none), glow: .energy, field: .food, identifier: "food-screen") {
            if let error {
                LooprCard {
                    VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                        StatusChip("Could not load Food", symbol: "exclamationmark.triangle", accent: .warning)
                        LooprText(error, style: .body)
                        Button("Try again", action: retry).buttonStyle(LooprButtonStyle(accent: .energy)).accessibilityIdentifier("food-retry")
                    }
                }.padding(.horizontal, LooprSpacing.screenGutter)
            } else if let day {
                content(day)
            } else {
                ProgressView("Loading Food").frame(maxWidth: .infinity).accessibilityIdentifier("food-loading")
            }
        }
        // Every tap that opens or logs something ticks once under the finger.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: taps)
    }

    /// Runs `action` with the shared light tap.
    private func tap(_ next: FoodOverviewAction) { taps += 1; action(next) }

    private var isToday: Bool { day.map { calendar.isDate(now, inSameDayAs: $0.date) } ?? (navigation?.isToday ?? false) }

    /// "Thu 23 Oct · Kitchen closes in 5 h 26 m". Without a kitchen-closes rule, or on another day, the date only.
    private var metaLine: String? {
        let kitchen = FoodKitchenClock.phrase(closesAtMinute: longevity.targets.kitchenClosesMinute, now: now, isToday: isToday,
                                              calendar: calendar, locale: locale)
        let parts = [navigation.map(LooprHeaderMeta.dayPhrase), kitchen].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func content(_ day: FoodDaySummary) -> some View {
        VStack(spacing: LooprSpacing.tabSection) {
            hero(day)
            VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
                logActions(day)
                // A new person logs first and sets targets after: the quiet link sits under the log row (R1-NEW-03, R3-NEW).
                if day.settings == nil && day.meals.isEmpty && day.drinks.isEmpty { FoodPlanPrompt { tap(.plan) } }
                // Meals and Drinks are what a food logger checks and edits all day, so they follow the log row.
                meals(day)
                drinks(day)
                // The week stays visible as seven mini rings; the eating window, plants, lens, supplements, goal and
                // the week's chart sit one tap away on the Week page (UX R1-DES-06, R1-NEW-07, R1-VET-06).
                FoodWeekStrip(day: day, week: week, proteinTarget: proteinTarget, fibreTarget: longevity.targets.fibreGrams,
                              plants: longevity.isLoaded ? longevity.plants?.count : nil) { tap(.week) }
                if showsWeekInline {
                    FoodWeekContent(day: day, week: week, weightTrend: weightTrend, now: now, longevity: longevity,
                                    finishedDays: finishedDays, animates: entrance) { next in
                        if case .stackTick = next { action(next) } else { tap(next) }
                    }
                }
            }.padding(.horizontal, LooprSpacing.screenGutter)
        }
        .looprEntrance(tab: LooprColorFieldTab.food.rawValue, animates: $entrance, duration: 2.2)
        .onChange(of: entrance) { _, playing in
            guard playing else { return }
            arrived = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { withAnimation(.smooth(duration: 1.1)) { arrived = true } }
        }
    }

    /// Food's own protein target first, then the protocol's.
    private func proteinTarget(_ day: FoodDaySummary) -> Double? { day.settings?.protein ?? longevity.targets.proteinGrams }

    // MARK: Hero

    /// The share of the day's known calories that came from a photo or Ask estimate or from typed menu totals; nil when
    /// none did. USDA matches, barcodes and labels count as looked up, not estimated.
    static func estimatedShare(_ day: FoodDaySummary) -> Double? {
        let known = day.items.compactMap { item in item.nutrients[.energy].map { (item, $0) } }
        let total = known.reduce(0) { $0 + $1.1 }
        let guessed = known.filter { $0.0.isEstimated || $0.0.valueSourceTitle == "Your totals" }.reduce(0) { $0 + $1.1 }
        guard total > 0, guessed > 0 else { return nil }
        return guessed / total
    }

    private func hero(_ day: FoodDaySummary) -> some View {
        let energy = day.total(.energy)
        let empty = day.meals.isEmpty && day.drinks.isEmpty
        // Nothing logged is not the same as eating nothing: an empty day shows no number.
        let eaten = empty ? nil : energy.knownValue
        return VStack(spacing: LooprSpacing.md) {
            FoodRingsView(rings: FoodRingSpec.day(day, proteinTarget: proteinTarget(day), fibreTarget: longevity.targets.fibreGrams),
                          animates: entrance, settleToken: longevity.settleToken) {
                if empty {
                    LooprText(Self.nothingLogged, style: .title, color: .inkSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .frame(maxWidth: 150)
                } else {
                    VStack(spacing: 2) {
                        // The app's number locale, as the caption under it: "1.240" sat over "of 2,450 kcal" (ICP R3-UPG-1).
                        LooprHeroNumber(eaten.map { arrived ? $0 : 0 }, unit: nil, spokenUnit: "kilocalories", style: .heroNumeralLarge,
                                        absentText: "Not known")
                        LooprText(centreCaption(day, energy: energy, empty: empty), style: .caption, color: .inkSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ringsSummary(day, eaten: eaten))
            .accessibilityIdentifier("food-rings")
            if day.settings == nil {
                // Without targets the legend still shows what was eaten; an empty day leaves the rings' centre to say so.
                if !empty {
                    legend(day)
                    FoodPlanPrompt { tap(.plan) }
                }
            } else {
                legend(day)
                statusLine(day)
            }
            if let targetWarning { LooprText(targetWarning, style: .caption, color: .warning).multilineTextAlignment(.center) }
            // How much of the day is a guess: photo and Ask estimates and menu totals, by calories (R3-VET-05).
            if let share = Self.estimatedShare(day) {
                LooprText("Estimates and menu totals are \(number(share * 100))% of today's calories.", style: .caption, color: .inkSecondary)
                    .multilineTextAlignment(.center).accessibilityIdentifier("food-estimated-share")
            } else if day.target.isEstimated { StatusChip("Estimated", symbol: "sparkles", accent: .energy) }
        }
        .padding(.horizontal, LooprSpacing.screenGutter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Food. \(empty ? Self.nothingLogged : energy.knownValue.map { "\(number($0)) kilocalories logged" } ?? "No calorie total").")
        .accessibilityIdentifier("food-energy-hero")
    }

    /// One sentence under the legend naming whichever of protein and fibre is furthest behind its target, built from
    /// the person's own numbers (UX R1-NEW-04, R2-DES-01). The training allowance sentence that sat here lives at the
    /// top of the day sheet now, which this line opens. No line with nothing logged, without targets, or before the
    /// fibre target has loaded, so it never swaps from one nutrient to the other on arrival.
    @ViewBuilder private func statusLine(_ day: FoodDaySummary) -> some View {
        if longevity.isLoaded,
           let line = FoodDayStatus.gapLine(day: day, proteinTarget: proteinTarget(day), fibreTarget: longevity.targets.fibreGrams) {
            Button { tap(.targets) } label: {
                HStack(spacing: LooprSpacing.xs) {
                    LooprText(line, style: .caption, color: .inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    LooprChevron()
                }
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityLabel(line)
            .accessibilityHint("Opens this day's targets and planned training")
            .accessibilityIdentifier("food-status-line")
        }
    }

    private func centreCaption(_ day: FoodDaySummary, energy: FoodNutrientTotal, empty: Bool) -> String {
        let partial = energy.knownValue != nil && !energy.isComplete && !empty
        let base = day.target.energy.map { "of \(number($0)) kcal" } ?? "kcal eaten"
        return partial ? "\(base), known so far" : base
    }

    /// The rings' centre on a day with no meal or drink logged.
    static let nothingLogged = "Nothing logged yet"
    /// A legend value on a day with nothing logged.
    static let nothingLoggedValue = "Nothing logged"

    private func ringsSummary(_ day: FoodDaySummary, eaten: Double?) -> String {
        if day.meals.isEmpty && day.drinks.isEmpty { return "\(Self.nothingLogged)." }
        var parts: [String] = []
        if let eaten {
            parts.append(day.target.energy.map { "\(number(eaten)) of \(number($0)) kilocalories" } ?? "\(number(eaten)) kilocalories")
        } else { parts.append("Calories not known") }
        for (title, nutrient, target) in [("Protein", FoodNutrient.protein, proteinTarget(day)), ("Fibre", .fibre, longevity.targets.fibreGrams)] {
            let value = day.total(nutrient).knownValue ?? (day.meals.isEmpty && day.drinks.isEmpty ? 0 : nil)
            parts.append("\(title) " + (value.map { v in target.map { "\(number(v)) of \(number($0)) grams" } ?? "\(number(v)) grams" } ?? "not known"))
        }
        return parts.joined(separator: ". ") + "."
    }

    /// What is left today of energy, protein and fibre, or how far past the target, with no percent and no scolding
    /// colour (contract p-food, UX R1-MAC-04, R1-VET-13). Without a target a column shows what was eaten. Carbs and fat
    /// sit on a quiet line under them. The whole legend opens this day's sheet, the one door to targets, and carries
    /// the `food-targets` identifier the reason line had.
    private func legend(_ day: FoodDaySummary) -> some View {
        let empty = day.meals.isEmpty && day.drinks.isEmpty
        func grams(_ nutrient: FoodNutrient, _ target: Double?) -> String {
            guard let value = day.total(nutrient).knownValue ?? (empty ? 0 : nil) else { return "Not known" }
            return target.map { "\(number(value)) of \(number($0)) g" } ?? "\(number(value)) g"
        }
        typealias Item = (token: LooprColorToken, title: String, value: String, note: String?, spoken: String)
        /// "1,210 kcal" over "left", "120 kcal" over "over", or with no target "1,240 kcal" over "eaten".
        func remaining(_ token: LooprColorToken, _ title: String, _ nutrient: FoodNutrient, target: Double?, unit: String,
                       spokenUnit: String) -> Item {
            guard let eaten = day.total(nutrient).knownValue else { return (token, title, "Not known", nil, "\(title) not known") }
            guard let target, target > 0 else {
                return (token, title, "\(number(eaten)) \(unit)", "eaten", "\(title), \(number(eaten)) \(spokenUnit) eaten")
            }
            let left = (target - eaten).rounded()
            let note = left < 0 ? "over" : "left"
            return (token, title, "\(number(abs(left))) \(unit)", note,
                    "\(title), \(number(abs(left))) \(spokenUnit) \(note) of \(number(target))")
        }
        // A day with nothing logged keeps each label and its target and shows no number: nothing logged is not zero.
        func waiting(_ token: LooprColorToken, _ title: String, target: Double?, unit: String) -> Item {
            let line = target.map { "Target \(number($0)) \(unit)" }
            return (token, title, Self.nothingLoggedValue, line, "\(title), \(Self.nothingLoggedValue.lowercased())\(line.map { ", \($0.lowercased())" } ?? "")")
        }
        let items: [Item] = empty ? [
            waiting(.energy, "Energy", target: day.target.energy, unit: "kcal"),
            waiting(.heart, "Protein", target: proteinTarget(day), unit: "g"),
            waiting(.brand, "Fibre", target: longevity.targets.fibreGrams, unit: "g"),
        ] : [
            remaining(.energy, "Energy", .energy, target: day.target.energy, unit: "kcal", spokenUnit: "kilocalories"),
            remaining(.heart, "Protein", .protein, target: proteinTarget(day), unit: "g", spokenUnit: "grams"),
            // The fibre target arrives with the longevity data a moment later; until then a dash, not "17 g eaten"
            // that turns into "18 g left".
            longevity.isLoaded ? remaining(.brand, "Fibre", .fibre, target: longevity.targets.fibreGrams, unit: "g", spokenUnit: "grams")
                : (.brand, "Fibre", "–", nil, "Fibre loading"),
        ]
        let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: LooprSpacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: LooprSpacing.xs))
        let rest: String = {
            guard empty else {
                return [("Carbs", FoodNutrient.carbs, day.settings?.carbs), ("Fat", .fat, day.settings?.fat)]
                    .map { "\($0.0) \(grams($0.1, $0.2))" }.joined(separator: " · ")
            }
            let targets = [("Carbs", day.settings?.carbs), ("Fat", day.settings?.fat)]
                .compactMap { name, value in value.map { "\(name) target \(number($0)) g" } }
            return targets.isEmpty ? "\(Self.nothingLogged) for carbs and fat" : (targets + [Self.nothingLogged]).joined(separator: " · ")
        }()
        let incomplete = !empty && [FoodNutrient.energy, .protein, .fibre].contains { day.total($0).knownValue != nil && !day.total($0).isComplete }
        let notes: [String] = incomplete ? ["Some foods did not report every nutrient"] : []
        let spoken: String = (items.map(\.spoken) + [rest] + notes).joined(separator: ". ")
        return Button { tap(.targets) } label: {
            VStack(spacing: LooprSpacing.sm) {
                layout {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        let stack = dynamicType.isAccessibilitySize ? AnyLayout(HStackLayout(spacing: LooprSpacing.xs)) : AnyLayout(VStackLayout(spacing: 3))
                        stack {
                            Circle().fill(Color.loopr(item.token)).frame(width: 8, height: 8).shadow(color: Color.loopr(item.token), radius: 5)
                            LooprText(item.title, style: .caption, color: .inkSecondary)
                            Text(item.value).looprTypography(.metricValue).monospacedDigit()
                                .foregroundStyle(Color.loopr(empty ? .inkSecondary : .ink))
                                .multilineTextAlignment(.center)
                            if let note = item.note {
                                LooprText(note, style: .caption, color: .inkSecondary).multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                LooprText(rest, style: .caption, color: .inkSecondary).multilineTextAlignment(.center)
                if incomplete { LooprText("Some foods did not report every nutrient", style: .caption, color: .inkSecondary) }
            }
            .padding(.vertical, LooprSpacing.xs)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        // One button for VoiceOver: what is left of each, with its target, then carbs and fat.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this day's targets and planned training")
        .accessibilityIdentifier("food-targets")
    }

    // MARK: Logging

    private func logActions(_ day: FoodDaySummary) -> some View {
        let slot = FoodMealSlot.toLog(at: now, calendar: calendar, logged: Set(day.meals.map(\.slot))).slot
        // Without an AI key the camera still reads barcodes and labels, so the button keeps its name and one line says
        // what it does until a key is added (UX R1-NEW-02).
        let keyless = photoEstimates == false
        // Again logs this slot's last meal from the week at once, with Undo, like the empty slot's menu; a long press
        // opens the full list. With nothing to repeat it opens the list (UX R2-DES-07, R2-MAC-05).
        let last = lastMeal(in: slot, before: day)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            FoodLogRow(cameraSpoken: keyless ? "Camera. Reads barcodes and nutrition labels. Photo estimates need your own AI key"
                                             : "Log \(slot.title.lowercased()) with the camera. It also reads barcodes",
                       againSpoken: last.map { "Log \(slot.title.lowercased()) again: \($0.namesLine)" } ?? "Choose a meal to log again",
                       camera: { tap(.log(slot)) }, speak: { tap(.voice) }, type: { tap(.manual) },
                       again: { if let last { tap(.again(last)) } else { tap(.repeatMeal) } },
                       chooseAgain: last == nil ? nil : { tap(.repeatMeal) })
            if keyless {
                LooprText("Without an AI key, Camera reads barcodes and labels.", style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("food-log-key-note")
            }
        }
    }

    private func meals(_ day: FoodDaySummary) -> some View {
        let logged = !(day.meals.isEmpty && day.drinks.isEmpty)
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Meals", detail: mealsDetail(day))
            LooprCard {
                VStack(spacing: 0) {
                    ForEach(FoodMealSlot.allCases, id: \.self) { slot in
                        let meals = day.meals.filter { $0.slot == slot }
                        if meals.isEmpty { emptySlotRow(slot, day: day) }
                        else { ForEach(meals) { mealRow(slot: slot, meal: $0) } }
                        if slot != .dinner { Divider().overlay(Color.loopr(.divider)) }
                    }
                    // Finishing the day gates the lens and the alcohol rule, so it sits where the day's log ends, once
                    // there is something to finish (UX R1-VET-07, R1-MAC-07, R1-NEW-05). The day sheet offers the same
                    // action under the same name.
                    if logged || day.isCompleted {
                        Divider().overlay(Color.loopr(.divider))
                        doneRow(day)
                    }
                }
            }
        }
    }

    private func mealIcon(_ meal: FoodMeal?) -> some View {
        Group {
            if let photoID = meal?.photos.first?.id, let image = photos[photoID] {
                image.resizable().scaledToFill().frame(width: LooprSpacing.hero, height: LooprSpacing.hero).clipShape(Circle())
            } else {
                Image(systemName: meal == nil ? "plus" : "fork.knife")
                    .looprTypography(meal == nil ? .rowTitle : .title).foregroundStyle(Color.loopr(.energy).opacity(meal == nil ? 0.8 : 1))
                    .frame(width: LooprSpacing.hero, height: LooprSpacing.hero)
                    .background(Color.loopr(.energy).opacity(meal == nil ? 0.08 : 0.14), in: Circle())
                    .overlay { if meal == nil { Circle().strokeBorder(Color.loopr(.energy).opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) } }
            }
        }
        .accessibilityHidden(true)
    }

    /// The foods on one short line, then "8:00 AM · Barcode" on a second; kcal on the right with protein under it in
    /// tabular figures, so protein per meal reads as a column (UX R2-DES-06, R1-MAC-10, R2-NEW-05). A food without
    /// calories is named in the row, so a meal's kcal never looks complete when it is not (UX R2-VET-07).
    private func mealRow(slot: FoodMealSlot, meal: FoodMeal) -> some View {
        let energy = FoodNutrientTotal(.energy, items: meal.items)
        let protein = FoodNutrientTotal(.protein, items: meal.items).knownValue
        let names = meal.namesLine
        let time = meal.occurredAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                              timeZone: calendar.timeZone))
        let facts = [time, meal.sourceSummary].compactMap { $0 }.joined(separator: " · ")
        let missing = meal.items.filter { $0.nutrients[.energy] == nil }.count
        let missingText: String? = missing == 0 ? nil : missing == 1 ? "1 food without calories" : "\(missing) foods without calories"
        let wraps = dynamicType.isAccessibilitySize
        let spoken = [slot.title, names.isEmpty ? nil : names,
                      energy.knownValue.map { "\(number($0)) kilocalories" } ?? "Calories not known",
                      protein.map { "\(number($0)) grams of protein" }, missingText, time, meal.sourceSummary]
            .compactMap { $0 }.joined(separator: ". ")
        return Button { tap(.edit(meal)) } label: {
            HStack(alignment: .center, spacing: LooprSpacing.sm) {
                mealIcon(meal)
                VStack(alignment: .leading, spacing: 2) {
                    LooprText(slot.title, style: .rowTitle)
                    if !names.isEmpty {
                        LooprText(names, style: .caption, color: .inkSecondary).lineLimit(wraps ? nil : 1)
                    }
                    LooprText(facts, style: .caption, color: .inkSecondary).lineLimit(wraps ? nil : 1)
                    if let missingText { LooprText(missingText, style: .caption, color: .warning) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    if let kcal = energy.knownValue {
                        HStack(alignment: .firstTextBaseline, spacing: LooprSpacing.xxs) {
                            LooprText(number(kcal), style: .metricValue).monospacedDigit()
                            LooprText("kcal", style: .metricUnit, color: .inkSecondary)
                        }
                    }
                    if let protein {
                        LooprText("\(number(protein))\u{00A0}g protein", style: .caption, color: .inkSecondary).monospacedDigit()
                    }
                }
                .fixedSize()
                LooprChevron()
            }
            .padding(.vertical, LooprSpacing.metricRowVertical)
            .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("food-meal-\(meal.id.uuidString)")
    }

    /// An empty slot offers the camera, typing, and the newest meal logged in that slot this week, which logs a copy
    /// straight away with Undo (UX R1-DES-14, R1-VET-02, R1-NEW-10).
    private func emptySlotRow(_ slot: FoodMealSlot, day: FoodDaySummary) -> some View {
        let last = lastMeal(in: slot, before: day)
        return Menu {
            Button { tap(.log(slot)) } label: { Label("Camera", systemImage: "camera") }
                .accessibilityIdentifier("food-add-\(slot.rawValue)-camera")
            Button { tap(.typeMeal(slot)) } label: { Label("Type", systemImage: "keyboard") }
                .accessibilityIdentifier("food-add-\(slot.rawValue)-type")
            if let last {
                // iOS menus may drop the second line, so the title itself names the meal (UX R2-MAC-06, R2-NEW-09).
                Button { tap(.again(last)) } label: {
                    Label { Text("Same as \(when(last, shown: day)): \(last.namesLine)"); Text(mealSummary(last)) }
                        icon: { Image(systemName: "arrow.counterclockwise") }
                }
                .accessibilityIdentifier("food-add-\(slot.rawValue)-again")
            }
        } label: {
            HStack(spacing: LooprSpacing.sm) {
                mealIcon(nil)
                HairlineMetricRow(title: slot.title, value: "", captionStyle: .caption)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.looprPressableRow)
        .accessibilityIdentifier("food-add-\(slot.rawValue)")
        .accessibilityLabel("\(slot.title). Add a meal")
    }

    /// The newest meal in `slot` from the loaded week, before the shown day.
    private func lastMeal(in slot: FoodMealSlot, before day: FoodDaySummary) -> FoodMeal? {
        week.filter { $0.localDay < day.localDay }.flatMap(\.meals)
            .filter { $0.slot == slot && !$0.items.isEmpty }
            .max { $0.occurredAt < $1.occurredAt }
    }

    /// "yesterday" for the day before today, otherwise the weekday, "Monday".
    private func when(_ meal: FoodMeal, shown day: FoodDaySummary) -> String {
        if let previous = calendar.date(byAdding: .day, value: -1, to: day.date), calendar.isDate(meal.occurredAt, inSameDayAs: previous) {
            return isToday ? "yesterday" : "the day before"
        }
        return meal.occurredAt.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
    }

    /// "520 kcal · 32 g protein"
    private func mealSummary(_ meal: FoodMeal) -> String {
        let energy = FoodNutrientTotal(.energy, items: meal.items).knownValue
        let protein = FoodNutrientTotal(.protein, items: meal.items).knownValue
        return [energy.map { "\(number($0)) kcal" }, protein.map { "\(number($0)) g protein" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Done for today" once something is logged, the one name for finishing, here and in the day sheet. It asks only
    /// when alcohol is still unanswered, otherwise it finishes at once with Undo. A finished day keeps the name with a
    /// filled tick, one summary line with no score, and Reopen (UX R2-DES-12/13, R2-MAC-10, R2-VET-13, R2-NEW-04).
    private func doneRow(_ day: FoodDaySummary) -> some View {
        let finished = day.isCompleted
        let title = Self.doneTitle(isToday: isToday)
        let summary = finished ? FoodDayStatus.finishedSummary(day: day, proteinTarget: proteinTarget(day), fibreTarget: longevity.targets.fibreGrams) : nil
        return VStack(alignment: .leading, spacing: 0) {
            Button { tap(.completion) } label: {
                HStack(spacing: LooprSpacing.sm) {
                    Image(systemName: finished ? "checkmark.circle.fill" : "checkmark.circle")
                        .looprTypography(.title).foregroundStyle(Color.loopr(.brand))
                        .frame(width: LooprSpacing.hero, height: LooprSpacing.hero)
                        .accessibilityHidden(true)
                    LooprText(title, style: .rowTitle)
                    Spacer(minLength: LooprSpacing.sm)
                    if finished { LooprText("Reopen", style: .label, color: .energy) }
                }
                .frame(maxWidth: .infinity, minHeight: LooprSpacing.interactiveRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.looprPressableRow)
            .accessibilityLabel(finished ? "\(title), finished. Reopen" : title)
            .accessibilityHint(finished ? "Asks before reopening this day's log" : "Finishes this day's log")
            .accessibilityIdentifier("food-done-today")
            if let summary {
                LooprText(summary, style: .caption, color: .inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, LooprSpacing.hero + LooprSpacing.sm)
                    .padding(.bottom, LooprSpacing.xs)
                    .accessibilityIdentifier("food-day-summary")
            }
        }
    }

    /// The one name for finishing a day's log: "Done for today", or for another day "Done with this day".
    public static func doneTitle(isToday: Bool) -> String { isToday ? "Done for today" : "Done with this day" }

    private func drinks(_ day: FoodDaySummary) -> some View {
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Drinks")
            LooprCard {
                VStack(spacing: 0) {
                    ForEach(FoodDrinkKind.allCases, id: \.self) { kind in
                        drinkRow(kind, day: day)
                        if kind != .alcohol { Divider().overlay(Color.loopr(.divider)) }
                    }
                }
            }
        }
    }

    /// Alcohol is known only when it was logged or the person said there was none when finishing the day. Other drinks
    /// being logged says nothing about it, so a day of water and coffee does not read as 0 units.
    private func alcoholValue(_ day: FoodDaySummary) -> Double? {
        if day.logsAlcohol { return day.total(.alcoholUnits).knownValue }
        return day.record?.noAlcoholAt != nil ? 0 : nil
    }

    private func drinkRow(_ kind: FoodDrinkKind, day: FoodDaySummary) -> some View {
        let value: Double? = switch kind { case .water: day.water.map { $0 / 1_000 }; case .caffeine: day.total(.caffeine).knownValue; case .alcohol: alcoholValue(day) }
        let incomplete = kind != .water && !day.total(kind == .caffeine ? .caffeine : .alcoholUnits).isComplete
        let partial = value != nil && incomplete && !(kind == .alcohol && !day.logsAlcohol)
        let unit = kind == .water ? "L" : kind == .caffeine ? "mg" : "units"
        let drinks = day.drinks.filter { $0.kind == kind }
        let latest = drinks.map(\.occurredAt).max()
        let noneText = isToday ? "None today" : "None this day"
        let subtitle = latest.map { "\(drinks.count) \(drinks.count == 1 ? "drink" : "drinks") · last \($0.formatted(date: .omitted, time: .shortened))" }
            ?? (kind == .alcohol ? (value == 0 ? noneText : "Not logged")
                : value == 0 && day.isCompleted ? noneText : "No drinks logged")
        let accent: LooprColorToken = kind == .water ? .brand : kind == .caffeine ? .energy : .heart
        let displayedValue = value.map { kind == .water ? litres($0) : number($0) } ?? "–"
        let displayedUnit = kind == .water ? day.settings?.waterMillilitres.map { "of \(litres($0 / 1_000)) L" } ?? unit : unit
        // Caffeine and alcohol already say "No drinks logged", so only water needs "Not logged".
        let detail = [kind == .water ? nil : subtitle, partial ? "Partial total" : value == nil && kind == .water ? "Not logged" : nil].compactMap { $0 }.joined(separator: " · ")
        // The plus repeats the newest drink of its kind from the week, with Undo. Without one it opens the sheet, so a
        // first coffee is never a guessed espresso; water alone adds a 250 ml glass (UX R2-NEW-03, R2-MAC-08, R2-DES-08).
        let last = week.flatMap(\.drinks).filter { $0.kind == kind }.max { $0.occurredAt < $1.occurredAt }
        let quick: LooprIntakeRow.QuickAdd = {
            let identifier = "food-quick-\(kind.rawValue)"
            if let last {
                let label = kind == .water ? "Add \(Self.millilitres(last.waterMillilitres)) ml of water" : "Add another \(last.name.lowercased())"
                return .init(label: label, identifier: identifier) { action(.repeatDrink(last)) }
            }
            if kind == .water {
                let glass = FoodDrinkPreset.glassOfWater
                return .init(label: "Add a glass of water, \(glass.serving)", identifier: identifier) { action(.quickDrink(glass)) }
            }
            return .init(label: kind == .caffeine ? "Choose a coffee or tea to add" : "Choose a drink to add", identifier: identifier) { action(.drink(kind)) }
        }()
        return LooprIntakeRow(title: kind.title, symbol: kind.symbol, accent: accent, value: displayedValue, unit: displayedUnit,
            detail: detail.isEmpty ? nil : detail, progress: day.water, target: day.settings?.waterMillilitres,
            showsProgress: kind == .water, showsPlus: false, identifier: "food-drink-\(kind.rawValue)",
            accessibilityLabel: "\(kind.title), \(value.map { "\(kind == .water ? litres($0) : number($0)) \(unit)" } ?? "not logged")\(partial ? ", partial total" : ""). Add a drink",
            quickAdd: quick) { tap(.drink(kind)) }
    }

    private func mealsDetail(_ day: FoodDaySummary) -> String? {
        guard !day.meals.isEmpty else { return nil }
        let energy = FoodNutrientTotal(.energy, items: day.items).knownValue
        let count = day.meals.count == 1 ? "1 meal" : "\(day.meals.count) meals"
        // The ring counts drinks too. Naming them here keeps one total on the screen (ICP R2-OPT-21: 1,240 against 1,232).
        let drinks = day.drinks.compactMap(\.energy).filter { $0.isFinite && $0 > 0 }.reduce(0, +)
        let drinksText = drinks.rounded() >= 1 ? " · drinks \(number(drinks)) kcal" : ""
        return energy.map { "\(count) · \(number($0)) kcal\(drinksText)" } ?? count
    }

    private func number(_ value: Double) -> String { LooprUnitFormatter.number(value, digits: 0) ?? "–" }
    /// "300" for a water drink's millilitres.
    public static func millilitres(_ value: Double?) -> String { value.flatMap { LooprUnitFormatter.number($0, digits: 0) } ?? "–" }
    /// 250 ml reads 0.25 L, in the phone's number format. One fixed decimal showed it as 0.2.
    private func litres(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2)).locale(LooprUnitFormatter.displayLocale)) }
}

/// The ways to log, under the hero, in glass (UX R1-DES-03, R1-DES-04): a wide Camera capsule tinted in the tab's
/// colour, then round Speak, Type and Again buttons, each named under its circle. At accessibility sizes they stack
/// as full-width capsules.
struct FoodLogRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicType
    let cameraSpoken: String
    /// What Again logs, for VoiceOver: "Log breakfast again: Greek yogurt, berries".
    let againSpoken: String
    let camera: () -> Void
    let speak: () -> Void
    let type: () -> Void
    let again: () -> Void
    /// Opens the full repeat list from a long press on Again. Nil when Again opens that list itself.
    let chooseAgain: (() -> Void)?

    private static let height: CGFloat = 54

    private struct Way: Identifiable {
        let title: String
        let symbol: String
        let spoken: String
        let identifier: String
        let action: () -> Void
        var menu: (() -> Void)?
        var id: String { identifier }
    }

    private var ways: [Way] {
        [Way(title: "Speak", symbol: "mic.fill", spoken: "Say what you ate", identifier: "food-voice", action: speak),
         Way(title: "Type", symbol: "keyboard", spoken: "Type what you ate", identifier: "food-manual", action: type),
         Way(title: "Again", symbol: "arrow.counterclockwise", spoken: againSpoken, identifier: "food-again", action: again, menu: chooseAgain)]
    }

    var body: some View {
        GlassEffectContainer(spacing: LooprSpacing.sm) {
            if dynamicType.isAccessibilitySize {
                VStack(spacing: LooprSpacing.sm) {
                    cameraButton
                    ForEach(ways) { wide($0) }
                }
            } else {
                HStack(alignment: .top, spacing: LooprSpacing.sm) {
                    cameraButton
                    ForEach(ways) { round($0) }
                }
            }
        }
    }

    private var cameraButton: some View {
        Button(action: camera) {
            HStack(spacing: LooprSpacing.xs) {
                Image(systemName: "camera.fill").font(.system(size: 18, weight: .semibold))
                Text("Camera").looprTypography(.label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(LooprColorToken.energy.filledLabelColor)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .modifier(FoodTintedGlass())
            .contentShape(Capsule())
        }
        .buttonStyle(.looprPressableCard)
        .accessibilityLabel(cameraSpoken)
        .accessibilityIdentifier("food-log-meal")
    }

    private func round(_ way: Way) -> some View {
        Button(action: way.action) {
            VStack(spacing: LooprSpacing.xxs) {
                Image(systemName: way.symbol).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.loopr(.energy))
                    .frame(width: Self.height, height: Self.height)
                    .looprGlass(in: Circle())
                Text(way.title).looprTypography(.caption).foregroundStyle(Color.loopr(.ink))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(minWidth: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.looprPressableCard)
        .modifier(FoodChooseMenu(choose: way.menu))
        .accessibilityLabel(way.spoken)
        .accessibilityIdentifier(way.identifier)
    }

    private func wide(_ way: Way) -> some View {
        Button(action: way.action) {
            HStack(spacing: LooprSpacing.xs) {
                Image(systemName: way.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.loopr(.energy))
                Text(way.title).looprTypography(.label).foregroundStyle(Color.loopr(.ink))
            }
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .looprGlass(in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.looprPressableCard)
        .modifier(FoodChooseMenu(choose: way.menu))
        .accessibilityLabel(way.spoken)
        .accessibilityIdentifier(way.identifier)
    }
}

/// Again's long press: a menu with the full repeat list, also offered to VoiceOver as a named action.
private struct FoodChooseMenu: ViewModifier {
    let choose: (() -> Void)?

    func body(content: Content) -> some View {
        if let choose {
            content
                .contextMenu {
                    Button(action: choose) { Label("Choose a meal", systemImage: "list.bullet") }
                        .accessibilityIdentifier("food-again-choose")
                }
                .accessibilityAction(named: "Choose a meal", choose)
        } else {
            content
        }
    }
}

public extension FoodMeal {
    /// "Greek yogurt, berries, granola", or past three foods "Greek yogurt, berries, granola and 2 more".
    var namesLine: String {
        let names = items.map(\.name)
        guard names.count > 3 else { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }
}

/// The Camera capsule's glass, tinted in the energy colour; a solid energy fill under Reduce Transparency.
private struct FoodTintedGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Color.loopr(.energy), in: Capsule())
            } else {
                content.glassEffect(.regular.tint(Color.loopr(.energy)).interactive(), in: Capsule())
            }
        }
    }
}
