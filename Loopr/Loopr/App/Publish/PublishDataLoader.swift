import AnalyticsKit
import DataKit
import DomainKit
import Foundation
import FoodKit
import RoutineKit
import StorageKit

/// The stores a report file reads: the ones the Food tab, the Protocol tab and the blood test screens read. In
/// production all three sit on the products database. A fixture launch gives each tab a scratch store of its own, so
/// the report file must be handed those same stores, or it greys out Food and Protocol while both tabs show data
/// (ICP R3-UPG-7).
nonisolated struct PublishStores: Sendable {
    var food: FoodStore?
    var routine: RoutineStore?
    var labs: LabStore?

    init(food: FoodStore? = nil, routine: RoutineStore? = nil, labs: LabStore? = nil) {
        self.food = food
        self.routine = routine
        self.labs = labs
    }

    /// All three on one database, as production keeps them.
    init(database: StorageDatabase?) {
        self.init(food: database.map(FoodStore.init(database:)), routine: database.map(RoutineStore.init(database:)),
                  labs: database.map(LabStore.init(database:)))
    }
}

/// Reads the stored series behind the Make a report file picker: the metric history every detail page reads, the
/// food log, the protocol checks and blood test reports. It reads only what is asked for, only on this iPhone.
nonisolated struct PublishDataLoader: Sendable {
    let history: any MetricHistoryProviding
    /// The food, protocol and blood test stores, resolved when the picker first reads them.
    let stores: @Sendable () async -> PublishStores
    let timeZone: TimeZone
    let now: @Sendable () -> Date

    init(history: any MetricHistoryProviding, stores: @escaping @Sendable () async -> PublishStores, timeZone: TimeZone,
         now: @escaping @Sendable () -> Date) {
        self.history = history
        self.stores = stores
        self.timeZone = timeZone
        self.now = now
    }

    /// Every store on the products database. Nil reads no food, protocol or blood tests.
    init(history: any MetricHistoryProviding, database: StorageDatabase?, timeZone: TimeZone, now: @escaping @Sendable () -> Date) {
        let stores = PublishStores(database: database)
        self.init(history: history, stores: { stores }, timeZone: timeZone, now: now)
    }

    /// How far back the picker looks for data. It matches the longest period.
    static let lookback = PublishPeriod.months12

    static let foodKeys: [(key: String, name: String, unit: String, nutrient: FoodNutrient)] = [
        ("food_energy", "Calories", "kcal", .energy),
        ("food_protein", "Protein", "g", .protein),
        ("food_fibre", "Fibre", "g", .fibre)
    ]
    static let protocolKey = "protocol_rules_kept"
    static let labPrefix = "lab_"

    private var calendar: Calendar { MetricHistoryDays.calendar(timeZone) }

    // MARK: Picker

    /// Every metric the picker lists. Metrics with no stored values come back with `hasData` false.
    func candidates() async -> [PublishMetricDescriptor] {
        let stores = await stores()
        var result: [PublishMetricDescriptor] = []
        for key in MetricKey.allCases {
            let points = (try? await history.series(for: key, days: Self.lookback.days, endingOn: now())) ?? []
            result.append(Self.descriptor(for: key, hasData: !points.isEmpty))
        }
        let food = foodSeries(stores.food, period: Self.lookback)
        for item in Self.foodKeys {
            result.append(PublishMetricDescriptor(key: item.key, name: item.name, unit: item.unit, group: .food,
                                                  hasData: !(food[item.key] ?? []).isEmpty))
        }
        result.append(PublishMetricDescriptor(key: Self.protocolKey, name: "Protocol rules kept", unit: "rules",
                                              group: .protocolRules, hasData: protocolHasData(stores.routine)))
        result.append(contentsOf: labCandidates(stores.labs))
        return result
    }

    /// The daily values for the picked keys over a period. An unknown key returns nothing.
    func series(keys: [String], period: PublishPeriod) async -> [PublishMetricSeries] {
        let stores = await stores()
        var result: [PublishMetricSeries] = []
        var food: [String: [PublishDayValue]]?
        var labs: [String: PublishMetricSeries]?
        for key in keys {
            if let metric = MetricKey(rawValue: key) {
                if let series = await metricSeries(metric, days: period.days) { result.append(series) }
            } else if let item = Self.foodKeys.first(where: { $0.key == key }) {
                if food == nil { food = foodSeries(stores.food, period: period) }
                result.append(PublishMetricSeries(key: item.key, name: item.name, unit: item.unit, group: .food,
                                                  source: "Loopr food log", values: food?[key] ?? []))
            } else if key == Self.protocolKey {
                result.append(PublishMetricSeries(key: key, name: "Protocol rules kept", unit: "rules", group: .protocolRules,
                                                  source: "Loopr protocol", values: protocolValues(stores.routine, period: period)))
            } else if key.hasPrefix(Self.labPrefix) {
                if labs == nil { labs = labSeries(stores.labs) }
                if let series = labs?[key] { result.append(series) }
            }
        }
        return result
    }

    // MARK: Metric history

    static func descriptor(for key: MetricKey, hasData: Bool) -> PublishMetricDescriptor {
        PublishMetricDescriptor(key: key.rawValue, name: name(for: key), unit: unit(for: key), group: group(for: key), hasData: hasData)
    }

    /// The names a page handed to a doctor carries, in plain words (ICP R1-LAB-24).
    static func name(for key: MetricKey) -> String {
        switch key {
        case .steps: "Steps"
        case .vo2Max: "VO₂max"
        case .sleepPerformance: "Hours slept against need"
        default: key.presentation.title
        }
    }

    static func unit(for key: MetricKey) -> String {
        switch key.historyUnit {
        case .count: "steps"
        case .breathsPerMinute: "breaths per minute"
        default: key.historyUnit.rawValue
        }
    }

    static func group(for key: MetricKey) -> PublishGroup {
        switch key {
        case .sleepDuration, .sleepPerformance, .sleepDebt, .sleepEfficiency, .deepSleep, .remSleep, .sleepConsistency: .sleep
        case .restingHeartRate, .rmssd, .sdnn, .pNN50, .respiratoryRate, .sleepingHeartRate, .heartRateDip,
             .oxygenSaturation, .skinTemperatureDeviation, .recovery, .stress: .heart
        case .strain, .vo2Max, .maxHeartRate, .activeEnergy, .steps: .fitness
        }
    }

    static func sourceName(_ source: MetricSampleSource) -> String {
        switch source {
        case .band: "WHOOP band"
        case .appleHealth: "Apple Health"
        case .whoopExport: "WHOOP account export"
        }
    }

    private func metricSeries(_ key: MetricKey, days: Int) async -> PublishMetricSeries? {
        guard let points = try? await history.series(for: key, days: days, endingOn: now()) else { return nil }
        let calendar = calendar
        let values = points.map { PublishDayValue(date: MetricHistoryDays.label($0.day, calendar: calendar), value: $0.value) }
        let sources = Set(points.map(\.source)).map(Self.sourceName).sorted()
        return PublishMetricSeries(key: key.rawValue, name: Self.name(for: key), unit: Self.unit(for: key), group: Self.group(for: key),
                                   source: sources.isEmpty ? "Loopr" : sources.joined(separator: ", "), values: values)
    }

    // MARK: Food

    /// One value per local day for calories, protein and fibre. A day counts only when every item and drink of
    /// that day reports the nutrient, so a partly logged day never shows a low total as if it were whole.
    private func foodSeries(_ store: FoodStore?, period: PublishPeriod) -> [String: [PublishDayValue]] {
        let range = dayRange(period)
        guard let store, let data = try? store.overview(from: range.from, through: range.through) else { return [:] }
        var result: [String: [PublishDayValue]] = [:]
        let mealsByDay = Dictionary(grouping: data.meals, by: \.localDay)
        let drinksByDay = Dictionary(grouping: data.drinks, by: \.localDay)
        for day in Set(mealsByDay.keys).union(drinksByDay.keys).sorted() {
            let items = (mealsByDay[day] ?? []).flatMap(\.items)
            let drinks = drinksByDay[day] ?? []
            for item in Self.foodKeys {
                let readings = items.map { $0.nutrients[item.nutrient] } + drinks.map { drink -> Double? in
                    item.nutrient == .energy ? drink.energy : (drink.kind == .water ? 0 : drink.additionalNutrients?[item.nutrient])
                }
                let total = FoodNutrientTotal(values: readings)
                if total.isComplete, let value = total.knownValue, value > 0 {
                    result[item.key, default: []].append(PublishDayValue(date: day, value: value))
                }
            }
        }
        return result
    }

    // MARK: Protocol

    private func protocolHasData(_ store: RoutineStore?) -> Bool {
        !protocolValues(store, from: dayRange(Self.lookback), stopAtFirst: true).isEmpty
    }

    private func protocolValues(_ store: RoutineStore?, period: PublishPeriod) -> [PublishDayValue] {
        protocolValues(store, from: dayRange(period), stopAtFirst: false)
    }

    /// Per day, how many protocol rules were kept. A day with no kept or missed check has no value.
    private func protocolValues(_ store: RoutineStore?, from range: (from: String, through: String), stopAtFirst: Bool) -> [PublishDayValue] {
        guard let store, let active = try? store.activeProtocol(),
              let first = PublishDay.ordinal(range.from), let last = PublishDay.ordinal(range.through) else { return [] }
        var values: [PublishDayValue] = []
        var ordinal = last
        while ordinal >= first {
            let label = PublishDay.label(ordinal: ordinal)
            let parts = label.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3,
               let checks = try? store.checks(protocolID: active.routineProtocol.id, day: DayIdentity(year: parts[0], month: parts[1], day: parts[2])),
               checks.contains(where: { $0.state == .kept || $0.state == .missed }) {
                values.append(PublishDayValue(date: label, value: Double(checks.filter { $0.state == .kept }.count)))
                if stopAtFirst { return values }
            }
            ordinal -= 1
        }
        return values.reversed()
    }

    // MARK: Blood tests

    static func labKey(_ subject: LabValueSubject) -> String {
        switch subject {
        case .marker(let key): return labPrefix + key.rawValue.replacingOccurrences(of: "-", with: "_")
        case .other(let name):
            let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            let slug = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            return labPrefix + "other_" + String(slug)
        }
    }

    private func labCandidates(_ store: LabStore?) -> [PublishMetricDescriptor] {
        guard let store, let latest = try? store.latestValues() else { return [] }
        let candidates = latest.values.map { entry in
            PublishMetricDescriptor(key: Self.labKey(entry.value.subject), name: entry.value.subject.displayName,
                                    unit: entry.value.unit ?? "", group: .bloodTests, hasData: true)
        }
        return candidates.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One series per marker, one value per report day. A value printed in another unit than the latest one is
    /// left out, so a series never mixes units.
    private func labSeries(_ store: LabStore?) -> [String: PublishMetricSeries] {
        guard let store, let latest = try? store.latestValues() else { return [:] }
        var result: [String: PublishMetricSeries] = [:]
        for (subject, newest) in latest {
            guard let entries = try? store.history(for: subject) else { continue }
            let unit = newest.value.unit ?? ""
            let values: [PublishDayValue] = entries.compactMap { entry in
                guard (entry.value.unit ?? "").caseInsensitiveCompare(unit) == .orderedSame,
                      let day = entry.report.collectedDay else { return nil }
                return PublishDayValue(date: day, value: NSDecimalNumber(decimal: entry.value.value).doubleValue)
            }
            let key = Self.labKey(subject)
            result[key] = PublishMetricSeries(key: key, name: subject.displayName, unit: unit, group: .bloodTests,
                                              source: "Blood test reports", values: values)
        }
        return result
    }

    // MARK: Days

    private func dayRange(_ period: PublishPeriod) -> (from: String, through: String) {
        let range = PublishPeriodRange(period: period, endingOn: now(), timeZone: timeZone)
        return (range.from, range.through)
    }
}
