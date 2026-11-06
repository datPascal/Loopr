import AnalyticsKit
import Combine
import DataKit
import DesignSystem
import Foundation
import HealthKitBridge
import ProfileKit
import StorageKit
import TrainKit

// LV-08b step 1: builds the Data tab's root from stored data. This file maps the app's repositories onto DataKit's
// plain inputs and decides nothing: the ages, the year slopes, the star map and the vault come from DataKit and
// AnalyticsKit. A source that is not wired in, or cannot be read, comes back absent and the screen says so.

/// The profile fields Data reads.
nonisolated struct DataOverviewProfile: Equatable, Sendable {
    var birthYear: Int?
    var biologicalSex: BiologicalSex?
}

/// The band's name and last sync, as the shell shows them.
nonisolated struct DataBandFacts: Equatable, Sendable {
    var name: String?
    var lastSync: Date?
}

/// Where each Data input comes from. A nil reader is a source this composition does not have.
nonisolated struct DataOverviewSources: Sendable {
    var profile: (@Sendable () async -> DataOverviewProfile?)?
    /// Every stored blood test with its values. A nil result means the lab store could not be read.
    var labDraws: (@Sendable () async -> [DataLabDraw]?)?
    /// One Apple Health kind over a window, through `AppleHealthSources`.
    var appleHealth: (@Sendable (AppleHealthSourceKind, _ from: Date, _ to: Date) async -> AppleHealthReadResult)?
    /// One metric's daily history, through the metric history provider.
    var metricHistory: (@Sendable (MetricKey, _ days: Int, _ endingOn: Date) async -> [MetricHistoryPoint])?
    var vault: (@Sendable () async -> DataVaultFacts?)?

    init(profile: (@Sendable () async -> DataOverviewProfile?)? = nil,
         labDraws: (@Sendable () async -> [DataLabDraw]?)? = nil,
         appleHealth: (@Sendable (AppleHealthSourceKind, Date, Date) async -> AppleHealthReadResult)? = nil,
         metricHistory: (@Sendable (MetricKey, Int, Date) async -> [MetricHistoryPoint])? = nil,
         vault: (@Sendable () async -> DataVaultFacts?)? = nil) {
        self.profile = profile; self.labDraws = labDraws; self.appleHealth = appleHealth
        self.metricHistory = metricHistory; self.vault = vault
    }
}

/// Pure mapping from the app's types onto DataKit's inputs.
nonisolated enum DataOverviewMapping {
    /// Two years and a little more: this year's 90 days, the same days last year, and the star map's windows.
    static let historyDays = 800

    /// Every metric with a history, except blood oxygen, which Loopr does not show (DEC-02.6, DEC-05.2).
    static let comparedMetrics: [MetricKey] = MetricKey.allCases.filter { $0 != .oxygenSaturation }

    /// The Apple Health kinds that have no metric history of their own. VO₂max and steps come through `MetricKey`.
    static let appleHealthSeriesKinds: [AppleHealthSourceKind] = AppleHealthSourceKind.addedReads

    static func system(_ key: MetricKey) -> DataBodySystem {
        switch key {
        case .restingHeartRate, .rmssd, .sdnn, .pNN50, .sleepingHeartRate, .heartRateDip, .stress, .oxygenSaturation:
            .cardiovascular
        case .respiratoryRate, .skinTemperatureDeviation, .sleepDuration, .sleepPerformance, .sleepDebt, .sleepEfficiency,
             .deepSleep, .remSleep, .sleepConsistency:
            .sleep
        case .recovery, .strain, .vo2Max, .maxHeartRate, .activeEnergy, .steps:
            .fitness
        }
    }

    static func system(_ kind: AppleHealthSourceKind) -> DataBodySystem {
        switch kind {
        case .bloodPressure: .cardiovascular
        case .weight, .bodyFat, .leanMass, .bloodGlucose: .metabolic
        case .daylight: .sleep
        case .vo2Max, .steps: .fitness
        }
    }

    /// The word for a kind in the Apple Health source row.
    static func rowName(_ kind: AppleHealthSourceKind) -> String {
        switch kind {
        case .vo2Max: "VO₂max"
        case .daylight: "daylight"
        case .bloodPressure: "blood pressure"
        case .weight: "weight"
        case .bodyFat: "body fat"
        case .leanMass: "lean mass"
        case .bloodGlucose: "blood glucose"
        case .steps: "steps"
        }
    }

    static func title(_ kind: AppleHealthSourceKind) -> String {
        switch kind {
        case .vo2Max: "VO₂max"
        case .daylight: "Time in daylight"
        case .bloodPressure: "Systolic blood pressure"
        case .weight: "Weight"
        case .bodyFat: "Body fat"
        case .leanMass: "Lean mass"
        case .bloodGlucose: "Blood glucose"
        case .steps: "Steps"
        }
    }

    /// One band metric's history as a series. VO₂max arrives now and then; the rest are daily.
    static func series(_ key: MetricKey, points: [MetricHistoryPoint]) -> DataSeries {
        let presentation = key.presentation
        let source: DataMarkerSource = points.last?.source == .appleHealth || key == .vo2Max ? .appleHealth : .band
        return DataSeries(
            id: key.rawValue, title: presentation.title, system: system(key), source: source,
            cadence: key == .vo2Max ? .occasional : .daily, higherIsBetter: MetricDetailRules.higherIsBetter(key),
            points: points.map { DataPoint(date: $0.day, value: $0.value) },
            valueText: { presentation.valueWithUnit($0) },
            deltaText: { presentation.format.delta($0) })
    }

    /// VO₂max as one series: the Apple Health samples the age ruler and the Fitness gauge read, when Apple Health gave
    /// any, else the stored daily history. Its year row follows `LooprAgeSource.vo2MaxYear`, the 42-day median today
    /// against a year earlier, so the card shows the value and the change Fitness shows (R3-OPT-3).
    static func vo2MaxSeries(history: [MetricHistoryPoint], appleHealth: AppleHealthReadResult?, now: Date,
                             calendar: Calendar) -> DataSeries {
        let fromHealth = LooprAgeSource.vo2MaxReadings(appleHealth)
        let readings = fromHealth.isEmpty
            ? history.map { VO2MaxReading(value: $0.value, date: $0.day, sourceLabel: "Apple Health", isConsumerEstimate: true) }
            : fromHealth
        var byDay: [Date: [Double]] = [:]
        for reading in readings { byDay[calendar.startOfDay(for: reading.date), default: []].append(reading.value) }
        let points = byDay.compactMap { day, values in DataTrendRule.median(values).map { DataPoint(date: day, value: $0) } }
        let year = LooprAgeSource.vo2MaxYear(readings, now: now, calendar: calendar)
        let presentation = MetricKey.vo2Max.presentation
        return DataSeries(
            id: MetricKey.vo2Max.rawValue, title: title(AppleHealthSourceKind.vo2Max), system: system(MetricKey.vo2Max), source: .appleHealth,
            cadence: .occasional, higherIsBetter: MetricDetailRules.higherIsBetter(MetricKey.vo2Max), points: points,
            valueText: { presentation.valueWithUnit($0) }, deltaText: { presentation.format.delta($0) },
            yearValues: DataYearValues(thisYear: year?.current.value ?? .nan, lastYear: year?.yearAgo?.value, basis: "42-day median"))
    }

    /// One Apple Health kind as a series: one value per local day, the median when a day has several. Daylight is a
    /// daily total; the others arrive now and then.
    static func series(_ kind: AppleHealthSourceKind, result: AppleHealthReadResult?, calendar: Calendar) -> DataSeries {
        var byDay: [Date: [Double]] = [:]
        for sample in result?.samples ?? [] where sample.kind == kind && sample.value.isFinite {
            byDay[calendar.startOfDay(for: sample.end), default: []].append(sample.value)
        }
        let points = byDay.compactMap { day, values in DataTrendRule.median(values).map { DataPoint(date: day, value: $0) } }
        let format = valueFormat(kind)
        return DataSeries(
            id: "apple-health-\(kind.rawValue)", title: title(kind), system: system(kind), source: .appleHealth,
            cadence: kind.isDailyAggregate ? .daily : .occasional, higherIsBetter: nil, points: points,
            valueText: { format.value($0) }, deltaText: { format.delta($0) })
    }

    private static func valueFormat(_ kind: AppleHealthSourceKind) -> (value: @Sendable (Double) -> String, delta: @Sendable (Double) -> String) {
        let digits = kind == .daylight || kind == .bloodPressure || kind == .steps ? 0 : 1
        let unit: String = switch kind {
        case .daylight: "min"
        case .bloodPressure: "mmHg"
        case .weight, .leanMass: "kg"
        case .bodyFat: "%"
        case .bloodGlucose: "mmol/L"
        case .vo2Max: "ml/kg/min"
        case .steps: "steps"
        }
        @Sendable func number(_ value: Double) -> String {
            LooprSignedNumber.text(value, fractionDigits: digits, plus: false)
        }
        return ({ unit == "%" ? number($0) + "%" : "\(number($0)) \(unit)" },
                {
                    let text = LooprSignedNumber.text($0, fractionDigits: digits)
                    return text.hasPrefix("+") || text.hasPrefix(LooprSignedNumber.minusSign) ? text : "±" + text
                })
    }

    /// FRIEND publishes a female and a male curve. Any other answer, or none, picks no curve (Fitness does the same).
    static func referenceGroup(_ sex: BiologicalSex?) -> FriendReferenceGroup? {
        FitnessInputMapping.referenceGroup(sex)
    }

    /// Apple Health's VO₂max read as Cardio Age's input.
    static func vo2Max(_ result: AppleHealthReadResult?) -> DataVO2MaxSource {
        switch FitnessInputMapping.vo2Max(result) {
        case .readings(let readings): .readings(readings)
        case .switchedOff: .switchedOff
        case .unavailable: .unavailable
        }
    }

    static func sourceFacts(summary: AppleHealthSourceSummary, band: DataBandFacts, draws: [DataLabDraw]?,
                            vault: DataVaultFacts?) -> DataSourceFacts {
        DataSourceFacts(
            bandName: band.name, bandLastSync: band.lastSync,
            appleHealthSources: summary.sources.map(\.label),
            appleHealthKinds: summary.suppliedKinds.map(rowName),
            appleHealthSwitchedOff: summary.kinds.allSatisfy { !$0.isEnabled },
            labReports: draws?.count ?? 0, labValues: draws?.reduce(0) { $0 + $1.values.count } ?? 0,
            labNames: draws?.map(\.report.labName) ?? [], importedDays: vault?.importedDays ?? 0)
    }

    /// Stage one: the profile, the blood tests and Apple Health's VO₂max, which are all the ruler needs. Three small
    /// reads, off the main actor.
    @concurrent
    static func core(sources: DataOverviewSources, now: Date, calendar: Calendar) async -> DataOverviewCore {
        let profile = await sources.profile?()
        var draws: [DataLabDraw]? = []
        if let read = sources.labDraws { draws = await read() }
        var vo2: AppleHealthReadResult?
        if let read = sources.appleHealth {
            vo2 = await read(.vo2Max, calendar.date(byAdding: .day, value: -historyDays, to: now) ?? now, now)
        }
        let ruler = DataAgeRuler.make(
            birthYear: profile?.birthYear, draws: draws, vo2Max: vo2.map { vo2Max($0) } ?? .readings([]),
            referenceGroup: referenceGroup(profile?.biologicalSex), now: now, calendar: calendar)
        return DataOverviewCore(ruler: ruler, draws: draws, vo2Max: vo2, readsAppleHealth: sources.appleHealth != nil)
    }

    /// Stage two: every metric's history and the other seven Apple Health kinds, read concurrently, then the year
    /// slopes, the star map and the source facts. Each source is read once.
    @concurrent
    static func trends(sources: DataOverviewSources, core: DataOverviewCore, now: Date, calendar: Calendar) async -> DataOverviewTrends {
        let from = calendar.date(byAdding: .day, value: -historyDays, to: now) ?? now
        let endOfToday = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: now)) ?? now

        var health: [AppleHealthSourceKind: AppleHealthReadResult] = [:]
        if core.readsAppleHealth, let vo2 = core.vo2Max { health[.vo2Max] = vo2 }
        if let read = sources.appleHealth {
            await withTaskGroup(of: (AppleHealthSourceKind, AppleHealthReadResult).self) { group in
                for kind in AppleHealthSourceKind.allCases where kind != .vo2Max {
                    group.addTask { (kind, await read(kind, from, now)) }
                }
                for await (kind, result) in group { health[kind] = result }
            }
        }

        var histories: [MetricKey: [MetricHistoryPoint]] = [:]
        if let read = sources.metricHistory {
            await withTaskGroup(of: (MetricKey, [MetricHistoryPoint]).self) { group in
                for key in comparedMetrics {
                    group.addTask { (key, await read(key, historyDays, endOfToday)) }
                }
                for await (key, points) in group { histories[key] = points }
            }
        }

        var series = comparedMetrics.map { key in
            let points = (histories[key] ?? []).filter { $0.value.isFinite }
            return key == .vo2Max
                ? Self.vo2MaxSeries(history: points, appleHealth: core.readsAppleHealth ? core.vo2Max : nil, now: now, calendar: calendar)
                : Self.series(key, points: points)
        }
        series += appleHealthSeriesKinds.map { Self.series($0, result: health[$0], calendar: calendar) }
        series += DataLabSeries.series(core.draws ?? [])
        let summary = AppleHealthSourceSummaryBuilder.build(results: health)
        return DataOverviewTrends(
            slopes: DataYearComparisonRule.compare(series, now: now, calendar: calendar),
            starMap: DataStarMapRule.make(series, now: now, calendar: calendar),
            sources: sourceFacts(summary: summary, band: DataBandFacts(), draws: core.draws, vault: nil))
    }

    /// Stage three, run beside the other two: the ledgers' size, days and schema.
    @concurrent
    static func vault(sources: DataOverviewSources) async -> DataVaultFacts? {
        await sources.vault?()
    }

    /// The source facts with the band and the WHOOP export days filled in. Cheap, so the screen redoes it when the
    /// band syncs instead of reloading the overview.
    static func sources(_ base: DataSourceFacts, band: DataBandFacts, vault: DataVaultFacts?) -> DataSourceFacts {
        var facts = base
        facts.bandName = band.name
        facts.bandLastSync = band.lastSync
        facts.importedDays = vault?.importedDays ?? 0
        return facts
    }

    /// All three stages in one value, for tests and for any caller that wants the finished overview.
    @concurrent
    static func overview(sources: DataOverviewSources, band: DataBandFacts, now: Date, calendar: Calendar) async -> DataOverview {
        async let vaultFacts = Self.vault(sources: sources)
        let core = await Self.core(sources: sources, now: now, calendar: calendar)
        let trends = await Self.trends(sources: sources, core: core, now: now, calendar: calendar)
        let facts = await vaultFacts
        let merged = Self.sources(trends.sources, band: band, vault: facts)
        return DataOverview(ruler: core.ruler, slopes: trends.slopes, starMap: trends.starMap,
                            vaultCard: facts.map { DataVaultCard.make(facts: $0, now: now, calendar: calendar) },
                            sourceRows: DataSourceRow.rows(merged, now: now),
                            meta: DataVaultMeta.line(facts: facts, sources: merged))
    }

    /// Every report with its values. Nil when the store cannot be read.
    @concurrent
    static func readLabs(_ store: LabStore) async -> [DataLabDraw]? {
        do {
            return try store.reports().map { report in DataLabDraw(report: report, values: try store.values(reportID: report.id)) }
        } catch {
            return nil
        }
    }

    @concurrent
    static func readVault(_ databases: [StorageDatabase]) async -> DataVaultFacts? {
        try? DataVaultReader.read(databases)
    }
}

extension DataOverviewSources {
    /// The app's stored data: the profile, the lab tables, Apple Health through `AppleHealthSources`, the metric
    /// history and both ledgers. A read that fails is absent.
    @MainActor
    static func live(_ persistent: PersistentProductRepositories, history provider: any MetricHistoryProviding) -> DataOverviewSources {
        let profile = persistent.profile
        let database = persistent.database
        let ledgers = [persistent.database, persistent.historyDatabase]
        let appleHealth = persistent.healthSync.appleHealthSources()
        return DataOverviewSources(
            profile: {
                guard let value = try? await profile.readProfile() else { return nil }
                return DataOverviewProfile(birthYear: value.birthYear, biologicalSex: value.biologicalSex)
            },
            labDraws: { await DataOverviewMapping.readLabs(LabStore(database: database)) },
            appleHealth: { kind, from, to in await appleHealth.read(kind, from: from, to: to) },
            metricHistory: { key, days, end in (try? await provider.series(for: key, days: days, endingOn: end)) ?? [] },
            vault: { await DataOverviewMapping.readVault(ledgers) })
    }
}

/// What the ruler needs, read first.
nonisolated struct DataOverviewCore: Equatable, Sendable {
    var ruler: DataAgeRuler
    var draws: [DataLabDraw]?
    var vo2Max: AppleHealthReadResult?
    var readsAppleHealth: Bool
}

/// What the cards under the ruler need.
nonisolated struct DataOverviewTrends: Equatable, Sendable {
    var slopes: DataYearComparison
    var starMap: DataStarMap
    /// Without the band, which the screen adds.
    var sources: DataSourceFacts
}

/// Loads the Data root in three stages and publishes each as it arrives: the ruler first, then the slopes and the
/// star map, and the vault beside them. A key that already loaded is not read again; a newer key drops what an older
/// load was still reading.
@MainActor
final class DataOverviewLoader: ObservableObject {
    @Published private(set) var core: DataOverviewCore?
    @Published private(set) var trends: DataOverviewTrends?
    /// Set once the vault was read: nil inside when it could not be.
    @Published private(set) var vault: DataVaultFacts??
    private var generation = 0
    private(set) var loadedKey: DataOverviewReloadKey?

    func load(sources: DataOverviewSources, key: DataOverviewReloadKey, now: Date, calendar: Calendar) async {
        guard key != loadedKey else { return }
        generation += 1
        let token = generation
        async let vaultFacts = DataOverviewMapping.vault(sources: sources)
        let core = await DataOverviewMapping.core(sources: sources, now: now, calendar: calendar)
        guard token == generation, !Task.isCancelled else { return }
        if core != self.core { self.core = core }
        DataAgeRulerLatest.ruler = core.ruler
        let trends = await DataOverviewMapping.trends(sources: sources, core: core, now: now, calendar: calendar)
        guard token == generation, !Task.isCancelled else { return }
        if trends != self.trends { self.trends = trends }
        let facts = await vaultFacts
        guard token == generation, !Task.isCancelled else { return }
        vault = .some(facts)
        loadedKey = key
    }
}

/// The age ruler Data last loaded. Method pages opened from "How the numbers work" take the person's value from it,
/// the same value the ruler's pin passes, so the page and the ruler never tell two stories (ICP R2-LAB-19).
@MainActor
enum DataAgeRulerLatest {
    static var ruler: DataAgeRuler?
}
