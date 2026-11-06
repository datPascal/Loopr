import DesignSystem
import SwiftUI

extension FoodRingSpec {
    /// Where the three rings sit, in the rings' 300 pt design space.
    enum Layout {
        /// The Food hero.
        case hero
        /// A day in the week strip: wider strokes and gaps so the rings still read at 32 pt.
        case mini

        var rows: [(radius: CGFloat, width: CGFloat)] {
            switch self {
            case .hero: [(128, 18), (103, 15), (80, 13)]
            case .mini: [(130, 26), (96, 24), (62, 22)]
            }
        }
    }

    /// Energy, protein and fibre, outside in, as in the contract. Each ring fills toward its target and keeps a few
    /// dots by its end in the colours the camera's finish laid there.
    static func day(_ day: FoodDaySummary, proteinTarget: Double?, fibreTarget: Double?, layout: Layout = .hero) -> [FoodRingSpec] {
        func fraction(_ value: Double?, _ target: Double?) -> Double? {
            guard let value, let target, target > 0, value.isFinite else { return nil }
            return max(value / target, 0)
        }
        let energy = fraction(day.total(.energy).knownValue, day.target.energy)
        let protein = fraction(day.total(.protein).knownValue, proteinTarget)
        let fibre = fraction(day.total(.fibre).knownValue, fibreTarget)
        let proteinEnergy: Double = (day.total(.protein).knownValue ?? 0) * 4
        let carbsEnergy: Double = (day.total(.carbs).knownValue ?? 0) * 4
        let fatEnergy: Double = (day.total(.fat).knownValue ?? 0) * 9
        let hasMacros = proteinEnergy + carbsEnergy + fatEnergy > 0
        let energyWeights: [Double] = hasMacros ? [proteinEnergy, carbsEnergy, fatEnergy] : [1]
        let energyTokens: [LooprColorToken] = hasMacros ? [.heart, .brand, .sleep] : [.energy]
        typealias Row = (token: LooprColorToken, fraction: Double?, weights: [Double], tokens: [LooprColorToken])
        let rows: [Row] = [
            Row(token: .energy, fraction: energy, weights: energyWeights, tokens: energyTokens),
            Row(token: .heart, fraction: protein, weights: [1], tokens: [.heart]),
            Row(token: .brand, fraction: fibre, weights: [1], tokens: [.brand]),
        ]
        return rows.enumerated().map { index, row in
            let size = layout.rows[index]
            let dots = FoodRingDots.dots(fraction: row.fraction ?? 0, lineWidth: Double(size.width), weights: row.weights,
                                         seed: FoodRingDots.seed(localDay: day.localDay, ring: index))
            return FoodRingSpec(id: index, token: row.token, fraction: row.fraction, radius: size.radius, width: size.width,
                                dots: dots, dotTokens: row.tokens)
        }
    }

    /// The three tracks alone, for a day with no summary or one still to come.
    static func empty(layout: Layout) -> [FoodRingSpec] {
        let tokens: [LooprColorToken] = [.energy, .heart, .brand]
        return layout.rows.enumerated().map { index, size in
            FoodRingSpec(id: index, token: tokens[index], fraction: nil, radius: size.radius, width: size.width, dots: [], dotTokens: [])
        }
    }
}

/// The value a week chart draws for each day.
enum FoodWeekMetric: String, CaseIterable, Hashable {
    case energy, protein, fibre

    var title: String {
        switch self {
        case .energy: "Calories"
        case .protein: "Protein"
        case .fibre: "Fibre"
        }
    }
    var nutrient: FoodNutrient {
        switch self {
        case .energy: .energy
        case .protein: .protein
        case .fibre: .fibre
        }
    }
    var unit: String { self == .energy ? "kcal" : "g" }
    var accent: LooprColorToken {
        switch self {
        case .energy: .energy
        case .protein: .heart
        case .fibre: .brand
        }
    }
}

/// "This week" on the Food screen: seven mini rings, Monday first, drawn like the hero, with the shown day larger,
/// and one line under them. Tapping it opens the Week page.
struct FoodWeekStrip: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale
    let day: FoodDaySummary
    let week: [FoodDaySummary]
    let proteinTarget: (FoodDaySummary) -> Double?
    let fibreTarget: Double?
    /// This week's plant count, nil until the plants load.
    let plants: Int?
    let open: () -> Void

    private struct Slot: Identifiable {
        let id: String
        let date: Date?
        let summary: FoodDaySummary?
        let isShown: Bool
        let isLater: Bool
    }

    var body: some View {
        let soFar = FoodWeekSoFar(day: day, summaries: week)
        let slots = slots(soFar)
        VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("This week")
            Button(action: open) {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(slots) { slot in
                            VStack(spacing: LooprSpacing.xxs) {
                                FoodRingsView(rings: rings(slot), animates: false, settleToken: 0) { EmptyView() }
                                    .frame(width: slot.isShown ? 44 : 32, height: slot.isShown ? 44 : 32)
                                    .opacity(slot.isLater ? 0.45 : 1)
                                Text(slot.date.map(weekday) ?? "")
                                    .looprTypography(.caption)
                                    .fontWeight(slot.isShown ? .semibold : .regular)
                                    .foregroundStyle(Color.loopr(slot.isShown ? .ink : .inkSecondary))
                                Circle()
                                    .fill(Color.loopr(.brand))
                                    .frame(width: 4, height: 4)
                                    .opacity(slot.summary?.isCompleted == true ? 1 : 0)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    HStack(spacing: LooprSpacing.sm) {
                        LooprText(line(soFar), style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        LooprChevron()
                    }
                }
                .padding(LooprSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .looprCardBackground()
                .contentShape(RoundedRectangle(cornerRadius: LooprRadius.card, style: .continuous))
            }
            .buttonStyle(.looprPressableCard)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("This week. \(spoken(slots)) \(line(soFar)).")
            .accessibilityHint("Opens the week: plants, eating window, each day's numbers, supplements and weight")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("food-week")
        }
    }

    private func slots(_ soFar: FoodWeekSoFar?) -> [Slot] {
        guard let soFar else {
            return week.map { Slot(id: $0.localDay, date: $0.date, summary: $0, isShown: $0.localDay == day.localDay, isLater: false) }
        }
        let dates = soFar.axisDates(shownDay: day.date, calendar: calendar)
        return soFar.week.days.enumerated().map { index, key in
            Slot(id: key, date: index < dates.count ? dates[index] : nil, summary: week.first { $0.localDay == key },
                 isShown: key == day.localDay, isLater: key > day.localDay)
        }
    }

    private func rings(_ slot: Slot) -> [FoodRingSpec] {
        guard let summary = slot.summary, !slot.isLater, !(summary.meals.isEmpty && summary.drinks.isEmpty) else { return FoodRingSpec.empty(layout: .mini) }
        return FoodRingSpec.day(summary, proteinTarget: proteinTarget(summary), fibreTarget: fibreTarget, layout: .mini)
    }

    private func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.narrow))
    }

    /// "18 plants this week · 2 finished days". A week with none finished says so without a zero.
    private func line(_ soFar: FoodWeekSoFar?) -> String {
        let finished = soFar?.finishedDays ?? week.filter(\.isCompleted).count
        let finishedText = finished == 0 ? "No finished days yet" : finished == 1 ? "1 finished day" : "\(finished) finished days"
        return [plants.map { "\($0) \($0 == 1 ? "plant" : "plants") this week" }, finishedText].compactMap { $0 }.joined(separator: " · ")
    }

    private func spoken(_ slots: [Slot]) -> String {
        let logged = slots.filter { slot in slot.summary.map { !($0.meals.isEmpty && $0.drinks.isEmpty) } ?? false }.count
        return logged == 1 ? "1 day logged." : "\(logged) days logged."
    }
}

/// The week, in this order: plants, the eating window, the longevity lens, each day's numbers with a protein, fibre
/// and kcal switch, supplements and medication, goal and weight, and the link to Food, sleep and recovery (UX R2-NEW-10,
/// R2-DES-09). The Week page shows it; `-loopr-open-folds YES` also shows it under the week strip.
struct FoodWeekContent: View {
    @Environment(\.calendar) private var calendar
    let day: FoodDaySummary
    let week: [FoodDaySummary]
    let weightTrend: FoodWeightTrend?
    let now: Date
    let longevity: FoodLongevity
    /// Finished days in the window Food and your body reads. Nil when the count could not be read.
    let finishedDays: Int?
    let animates: Bool
    let action: (FoodOverviewAction) -> Void
    /// Protein first: the tab leads with protein and fibre as much as with calories (UX R2-DES-17, R2-VET-11).
    @State private var metric: FoodWeekMetric = .protein

    /// The longevity lens shows from this many finished days.
    static let lensMinimumDays = 3

    private var isToday: Bool { calendar.isDate(now, inSameDayAs: day.date) }
    private var soFar: FoodWeekSoFar? { FoodWeekSoFar(day: day, summaries: week) }
    /// Food's own protein target first, then the protocol's.
    private func proteinTarget(_ day: FoodDaySummary) -> Double? { day.settings?.protein ?? longevity.targets.proteinGrams }

    var body: some View {
        VStack(alignment: .leading, spacing: LooprSpacing.tabSection) {
            if longevity.isLoaded, let plants = longevity.plants {
                let field = FoodSeedField(week: plants, new: longevity.newPlants)
                FoodPlantsCard(field: field, sentence: field.sentence(today: day.localDay, comparedWithEarlierWeeks: longevity.hasEarlierWeeks)) {
                    action(.plants)
                }
            }
            FoodWindowRailView(rail: FoodWindowRail(meals: day.meals, calendar: calendar, now: isToday ? now : nil,
                                                    closesMinute: longevity.targets.kitchenClosesMinute),
                               stickers: longevity.stickers, animates: animates,
                               open: { id in if let meal = day.meals.first(where: { $0.id == id }) { action(.edit(meal)) } },
                               log: { action(.log($0)) })
            if longevity.isLoaded { lens }
            chart
            if longevity.isLoaded {
                FoodStackView(shelf: longevity.stack, tick: { action(.stackTick($0)) }, edit: { action(.editStack) })
            }
            FoodGoalCard(progress: day.settings.map { FoodGoalProgress(settings: $0, trend: weightTrend) }, trend: weightTrend,
                         now: now, onEdit: { action(.plan) }, onLogWeight: { action(.logWeight) })
            associations
        }
    }

    // MARK: Each day

    private var chart: some View {
        let days = soFar?.days ?? week
        let target: (FoodDaySummary) -> Double? = { summary in
            switch metric {
            case .energy: summary.target.energy
            case .protein: proteinTarget(summary)
            case .fibre: longevity.targets.fibreGrams
            }
        }
        return VStack(alignment: .leading, spacing: LooprSpacing.xs) {
            LooprSectionHeader("Each day", detail: chartDetail(days))
            LooprCard {
                VStack(alignment: .leading, spacing: LooprSpacing.sm) {
                    LooprGlassSegmentedControl("Chart", segments: [FoodWeekMetric.protein, .fibre, .energy].map {
                        LooprGlassSegment($0.title, value: $0, identifier: "food-week-metric-\($0.rawValue)")
                    }, selection: $metric, identifier: "food-week-metric")
                    LooprTargetBars(days: days.map { summary -> LooprTargetBar in
                        let total = summary.total(metric.nutrient)
                        return .init(date: summary.date, value: total.knownValue, target: target(summary),
                                     isComplete: summary.isCompleted && total.isComplete)
                    }, title: "This week's \(metric.title.lowercased()) and targets", unit: metric.unit,
                       accent: metric.accent, axis: soFar?.axisDates(shownDay: day.date, calendar: calendar),
                       showsValues: true, labelsTarget: true)
                    .id(metric)
                    // The calorie tally waits for a few finished days: a zero for a week with one day in it reads as failure.
                    if metric == .energy, let soFar, soFar.finishedDays >= Self.lensMinimumDays {
                        LooprText(soFar.onTargetLine, style: .caption, color: .inkSecondary)
                            .accessibilityLabel(soFar.spokenOnTargetLine)
                    }
                }
            }
            .accessibilityIdentifier("food-week-chart")
        }
    }

    /// The average of the week's finished days, the days the on-target line counts. A day still being logged would
    /// pull it down (ICP R2-OPT-21: today's 1,240 in a 2,201 average).
    private func chartDetail(_ days: [FoodDaySummary]) -> String {
        let finished = days.compactMap { day -> Double? in
            let total = day.total(metric.nutrient)
            return day.isCompleted && total.isComplete ? total.knownValue : nil
        }
        guard finished.count >= 2 else { return "Faded bars are days not finished yet. Finished days show their number." }
        let average = number(finished.reduce(0, +) / Double(finished.count))
        let value = metric == .energy ? "\(average) kcal" : "\(average) g \(metric.title.lowercased())"
        return "Average \(value) over \(finished.count) finished days"
    }

    // MARK: Lens

    @ViewBuilder private var lens: some View {
        let complete = longevity.lens?.completeDays ?? 0
        // The lens is four dashes until three days are finished; it says what it waits for until then (UX R1-DES-10,
        // R1-VET-06, R1-VET-17).
        if complete >= Self.lensMinimumDays {
            FoodLensTilesView(tiles: FoodLensTiles.tiles(lens: longevity.lens, bodyWeightKilograms: longevity.bodyWeightKilograms,
                barcodedItems: longevity.barcodedItems, proteinTarget: proteinTarget(day), fibreTarget: longevity.targets.fibreGrams),
                method: nil)
        } else {
            VStack(alignment: .leading, spacing: LooprSpacing.xs) {
                LooprSectionHeader("Longevity lens")
                LooprCard {
                    LooprText("Starts after \(Self.lensMinimumDays) finished days, \(complete) so far. It shows protein per kilogram, fibre, ultra-processed food and alcohol-free days.",
                              style: .body, color: .inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("food-lens-waiting")
        }
    }

    // MARK: Food and your body

    /// Food and your body compares about this many finished days at least: five with and five without a habit.
    static let associationMinimumDays = 10

    private var associations: some View {
        let waiting = finishedDays.map { $0 < Self.associationMinimumDays } ?? false
        let line = waiting
            ? "Needs \(Self.associationMinimumDays) finished days to compare, \(finishedDays ?? 0) so far"
            : "Late meals and deep sleep, protein and next-day recovery"
        return LooprCard {
            Button { action(.associations) } label: {
                HStack(spacing: LooprSpacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        LooprText("Food, sleep and recovery", style: .rowTitle)
                        LooprText(line, style: .caption, color: .inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    LooprChevron()
                }.frame(minHeight: LooprSpacing.interactiveRowHeight).contentShape(Rectangle())
            }.buttonStyle(.looprPressableRow).accessibilityIdentifier("food-associations")
                .accessibilityLabel("Food, sleep and recovery. \(line).")
                .accessibilityHint("Compares what you ate with your sleep and recovery")
        }
    }

    private func number(_ value: Double) -> String { LooprUnitFormatter.number(value, digits: 0) ?? "–" }
}

/// The Week page, pushed from the week strip on Food.
public struct FoodWeekPage: View {
    private let day: FoodDaySummary
    private let week: [FoodDaySummary]
    private let weightTrend: FoodWeightTrend?
    private let now: Date
    private let longevity: FoodLongevity
    private let finishedDays: Int?
    private let action: (FoodOverviewAction) -> Void
    @State private var taps = 0

    public init(day: FoodDaySummary, week: [FoodDaySummary], weightTrend: FoodWeightTrend?, now: Date, longevity: FoodLongevity,
                finishedDays: Int?, action: @escaping (FoodOverviewAction) -> Void) {
        self.day = day; self.week = week; self.weightTrend = weightTrend; self.now = now
        self.longevity = longevity; self.finishedDays = finishedDays; self.action = action
    }

    public var body: some View {
        ScrollView {
            FoodWeekContent(day: day, week: week, weightTrend: weightTrend, now: now, longevity: longevity,
                            finishedDays: finishedDays, animates: false) { next in
                if case .stackTick = next {} else { taps += 1 }
                action(next)
            }
            .padding(.horizontal, LooprSpacing.screenGutter)
            .padding(.top, LooprSpacing.md)
            .padding(.bottom, LooprSpacing.tabBarClearance)
        }
        .background(Color.loopr(.background).ignoresSafeArea())
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: taps)
        .navigationTitle("This week").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("food-week-page")
    }
}
