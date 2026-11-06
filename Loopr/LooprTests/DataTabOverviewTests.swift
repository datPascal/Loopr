import AnalyticsKit
import DataKit
import Foundation
import HealthKitBridge
import ProfileKit
import Testing
import TrainKit
@testable import Loopr

private var berlin: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return calendar
}

/// 25 October 2026, 12:00 in Berlin.
private let now = berlin.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!

private func healthSample(_ kind: AppleHealthSourceKind, _ value: Double, daysAgo: Double, source: String = "Withings",
                          bundle: String = "com.withings.wiScaleNG") -> AppleHealthSample {
    let date = now.addingTimeInterval(-daysAgo * 86_400)
    return AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                             start: date, end: date, provenance: AppleHealthProvenance(sourceName: source, sourceBundleIdentifier: bundle))
}

private func watchVO2(_ value: Double, daysAgo: Double) -> AppleHealthSample {
    let date = now.addingTimeInterval(-daysAgo * 86_400)
    return AppleHealthSample(kind: .vo2Max, value: value, original: AppleHealthOriginalReading(value: value, unit: .mlPerKgPerMin),
                             start: date, end: date,
                             provenance: AppleHealthProvenance(sourceName: "Alex's Apple Watch", sourceBundleIdentifier: "com.apple.health.X",
                                                               deviceName: "Apple Watch"))
}

/// Counts every read a set of sources serves.
private final class DataSourceReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func note(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }

    /// The Data fixture's sources, each read counted.
    func counting(_ base: DataOverviewSources) -> DataOverviewSources {
        DataOverviewSources(
            profile: { self.note("profile"); return await base.profile?() },
            labDraws: { self.note("labs"); return await base.labDraws?() ?? [] },
            appleHealth: { kind, from, to in
                self.note("health")
                return await base.appleHealth?(kind, from, to) ?? .absent(.noSamples)
            },
            metricHistory: { key, days, end in
                self.note("history")
                return await base.metricHistory?(key, days, end) ?? []
            },
            vault: { self.note("vault"); return DataVaultFacts(fileBytes: 1, daysOfData: 460, schemaVersion: 21) })
    }
}

/// The Data tab's mapping from the app's stored data onto DataKit, with fake sources.
struct DataTabOverviewTests {
    /// The loader reads each source once per key, never more: one profile, one lab read, one read per Apple Health
    /// kind and per metric, one vault read. A second load with the same key reads nothing.
    @MainActor @Test func theLoaderReadsEachSourceOnceAndNotAgainForTheSameKey() async {
        let counter = DataSourceReadCounter()
        let sources = counter.counting(DataOverviewFixtures.sources(now: now, calendar: berlin))
        let loader = DataOverviewLoader()
        let key = DataOverviewReloadKey(storageGeneration: 1, day: berlin.startOfDay(for: now), lastSync: nil)
        await loader.load(sources: sources, key: key, now: now, calendar: berlin)
        #expect(counter.count("profile") == 1)
        #expect(counter.count("labs") == 1)
        #expect(counter.count("health") == AppleHealthSourceKind.allCases.count)
        #expect(counter.count("history") == DataOverviewMapping.comparedMetrics.count)
        #expect(counter.count("vault") == 1)
        #expect(loader.core?.ruler.pins.count == 3)
        #expect(loader.trends != nil)
        #expect(loader.vault != nil)
        let reads = counter.total
        await loader.load(sources: sources, key: key, now: now, calendar: berlin)
        #expect(counter.total == reads)
        // A sync in the same quarter hour keeps the key, so it does not restart the load.
        #expect(DataOverviewReloadKey(storageGeneration: 1, day: key.day, lastSync: Date(timeIntervalSince1970: 900 * 10 + 1))
            == DataOverviewReloadKey(storageGeneration: 1, day: key.day, lastSync: Date(timeIntervalSince1970: 900 * 10 + 899)))
    }

    /// The whole fixture, 460 days of six metrics, weekly Apple Health samples and two blood tests, builds well inside
    /// a budget generous enough for a busy CI simulator.
    @Test func theFixtureOverviewBuildsWithinTwoSeconds() async {
        let sources = DataOverviewFixtures.sources(now: now, calendar: berlin)
        let clock = ContinuousClock()
        let started = clock.now
        let overview = await DataOverviewMapping.overview(sources: DataOverviewSources(
            profile: sources.profile, labDraws: sources.labDraws, appleHealth: sources.appleHealth,
            metricHistory: sources.metricHistory, vault: { DataVaultFacts(daysOfData: 460) }),
            band: DataOverviewFixtures.band, now: now, calendar: berlin)
        let elapsed = clock.now - started
        #expect(elapsed < .seconds(2), "the fixture overview took \(elapsed)")
        #expect(overview.ruler.hero.kind == .blood)
    }

    @Test func everyMetricHasABodySystemAndBloodOxygenStaysOff() {
        #expect(!DataOverviewMapping.comparedMetrics.contains(.oxygenSaturation))
        #expect(DataOverviewMapping.comparedMetrics.count == MetricKey.allCases.count - 1)
        #expect(DataOverviewMapping.system(.restingHeartRate) == .cardiovascular)
        #expect(DataOverviewMapping.system(.deepSleep) == .sleep)
        #expect(DataOverviewMapping.system(MetricKey.vo2Max) == .fitness)
        #expect(DataOverviewMapping.system(AppleHealthSourceKind.bloodPressure) == .cardiovascular)
        #expect(DataOverviewMapping.system(.weight) == .metabolic)
        #expect(DataOverviewMapping.appleHealthSeriesKinds == AppleHealthSourceKind.addedReads)
    }

    @Test func aBandMetricKeepsItsBetterDirectionAndFormat() {
        let day = berlin.startOfDay(for: now)
        let rhr = DataOverviewMapping.series(.restingHeartRate, points: [MetricHistoryPoint(day: day, value: 51, source: .band)])
        #expect(rhr.higherIsBetter == false)
        #expect(rhr.cadence == .daily)
        #expect(rhr.source == .band)
        #expect(rhr.valueText(51) == "51 bpm")
        #expect(rhr.deltaText(-3) == "\u{2212}3")
        let vo2 = DataOverviewMapping.series(.vo2Max, points: [])
        #expect(vo2.cadence == .occasional)
        #expect(vo2.source == .appleHealth)
        #expect(DataOverviewMapping.series(.strain, points: []).higherIsBetter == nil)
    }

    @Test func appleHealthSamplesBecomeOneValuePerDay() {
        let weight = DataOverviewMapping.series(.weight, result: .values([
            healthSample(.weight, 79, daysAgo: 1), healthSample(.weight, 81, daysAgo: 1.05), healthSample(.weight, 80, daysAgo: 8)
        ]), calendar: berlin)
        #expect(weight.points.count == 2)
        #expect(weight.points.last?.value == 80)
        #expect(weight.cadence == .occasional)
        #expect(weight.valueText(79.6).replacingOccurrences(of: ",", with: ".") == "79.6 kg")
        let daylight = DataOverviewMapping.series(.daylight, result: .absent(.noSamples), calendar: berlin)
        #expect(daylight.points.isEmpty)
        #expect(daylight.cadence == .daily)
        #expect(DataOverviewMapping.series(.bodyFat, result: nil, calendar: berlin).valueText(18.9).replacingOccurrences(of: ",", with: ".") == "18.9%")
    }

    @Test func aNegativeChangeIsWrittenWithTheTypographicMinus() {
        let minus = "\u{2212}"
        let weight = DataOverviewMapping.series(.weight, result: nil, calendar: berlin)
        #expect(weight.deltaText(-0.5).replacingOccurrences(of: ",", with: ".") == "\(minus)0.5")
        #expect(weight.deltaText(0.5).replacingOccurrences(of: ",", with: ".") == "+0.5")
        #expect(weight.deltaText(0) == "\u{00B1}0.0" || weight.deltaText(0) == "\u{00B1}0,0")
        let steps = DataOverviewMapping.series(.steps, result: nil, calendar: berlin)
        #expect(steps.deltaText(-1_250).hasPrefix(minus))
        let band = DataOverviewMapping.series(.restingHeartRate, points: [])
        #expect(band.deltaText(-14) == "\(minus)14")
        for text in [weight.deltaText(-0.5), steps.deltaText(-1_250), band.deltaText(-14)] {
            #expect(!text.contains("-"), "\(text)")
        }
    }

    @Test func theSourceFactsComeFromTheSummaryTheBandAndTheLabs() {
        let summary = AppleHealthSourceSummaryBuilder.build(results: [
            .vo2Max: .values([watchVO2(44, daysAgo: 2)]),
            .weight: .values([healthSample(.weight, 80, daysAgo: 3)])
        ])
        let report = LabReport(collectedAt: now, timeZoneIdentifier: "Europe/Berlin", labName: "Riverside Lab", source: .typed, createdAt: now)
        let value = LabValue(reportID: report.id, subject: .marker(.apoB), value: 78, unit: "mg/dL", source: .typed)
        let facts = DataOverviewMapping.sourceFacts(summary: summary, band: DataBandFacts(name: "WHOOP 4.0", lastSync: now),
                                                    draws: [DataLabDraw(report: report, values: [value])],
                                                    vault: DataVaultFacts(importedDays: 12))
        #expect(facts.appleHealthSources.sorted() == ["Apple Watch", "Withings"])
        #expect(facts.appleHealthKinds == ["VO₂max", "weight"])
        #expect(!facts.appleHealthSwitchedOff)
        #expect(facts.labReports == 1 && facts.labValues == 1)
        #expect(facts.importedDays == 12)
        #expect(facts.sourceCount == 1 + 2 + 1 + 1)

        let off = AppleHealthSourceSummaryBuilder.build(results: Dictionary(uniqueKeysWithValues:
            AppleHealthSourceKind.allCases.map { ($0, AppleHealthReadResult.absent(.switchedOff)) }))
        #expect(DataOverviewMapping.sourceFacts(summary: off, band: DataBandFacts(), draws: nil, vault: nil).appleHealthSwitchedOff)
    }

    @Test func theVO2MaxReadBecomesCardioAgesSource() {
        #expect(DataOverviewMapping.vo2Max(.absent(.switchedOff)) == .switchedOff)
        #expect(DataOverviewMapping.vo2Max(.absent(.unavailable)) == .unavailable)
        #expect(DataOverviewMapping.vo2Max(.absent(.noSamples)) == .readings([]))
        guard case .readings(let readings) = DataOverviewMapping.vo2Max(.values([watchVO2(44.1, daysAgo: 3)])) else {
            Issue.record("expected readings")
            return
        }
        #expect(readings.first?.sourceLabel == "Apple Watch")
        #expect(DataOverviewMapping.referenceGroup(.female) == .female)
        #expect(DataOverviewMapping.referenceGroup(.undisclosed) == nil)
    }

    /// ICP R3-OPT-3: Cardio Age read a 42-day VO₂max median of 44.1 from Apple Health while the year card and star map
    /// read 48.1 from the metric history. They now read the one Apple Health read.
    @Test func vo2MaxOnTheStarMapIsTheReadCardioAgeUses() async {
        let sources = DataOverviewSources(
            profile: { DataOverviewProfile(birthYear: 1988, biologicalSex: .male) },
            appleHealth: { kind, _, _ in
                kind == .vo2Max ? .values([watchVO2(43.8, daysAgo: 35), watchVO2(44.1, daysAgo: 20), watchVO2(44.4, daysAgo: 3)])
                    : .absent(.noSamples)
            },
            metricHistory: { key, _, _ in
                key == .vo2Max ? [MetricHistoryPoint(day: berlin.startOfDay(for: now), value: 48.1, source: .appleHealth)] : []
            })
        let overview = await DataOverviewMapping.overview(sources: sources, band: DataBandFacts(), now: now, calendar: berlin)
        let star = overview.starMap.clusters.flatMap(\.stars).first { $0.id == MetricKey.vo2Max.rawValue }
        #expect(star?.latestText?.hasPrefix("44.4") == true)
        #expect(star?.title == "VO₂max")
        #expect(overview.ruler.cardio.reading?.median.value == 44.1)
    }

    @Test func theOverviewReadsEverySourceAndAFailedLabReadStaysAbsent() async {
        let sources = DataOverviewSources(
            profile: { DataOverviewProfile(birthYear: 1988, biologicalSex: .male) },
            labDraws: { nil },
            appleHealth: { kind, _, _ in
                kind == .vo2Max ? .values([watchVO2(43.8, daysAgo: 35), watchVO2(44.1, daysAgo: 20), watchVO2(44.4, daysAgo: 3)])
                    : .absent(.noSamples)
            },
            metricHistory: { _, _, _ in [] },
            vault: { DataVaultFacts(fileBytes: 10, daysOfData: 2, schemaVersion: 21) })
        let overview = await DataOverviewMapping.overview(sources: sources, band: DataBandFacts(name: "WHOOP 4.0", lastSync: nil),
                                                          now: now, calendar: berlin)
        #expect(overview.ruler.blood.absence == .unreadable)
        #expect(overview.ruler.cardio.reading != nil)
        #expect(overview.ruler.state(.real).pin != nil)
        #expect(overview.ruler.hero.kind == .cardio)
        #expect(overview.starMap.count == DataOverviewMapping.comparedMetrics.count + AppleHealthSourceKind.addedReads.count
            + LabMarkerCatalog.markers.count)
        #expect(overview.slopes == .noData || overview.slopes == .learning(daysUntilOpen: 365 - 35))
        #expect(overview.meta == "2 days · 2 sources · all on this iPhone")
    }

    @Test func withoutSourcesEveryPartIsAbsentNotZero() async {
        let overview = await DataOverviewMapping.overview(sources: DataOverviewSources(), band: DataBandFacts(), now: now, calendar: berlin)
        #expect(overview.ruler.pins.isEmpty)
        #expect(overview.ruler.hero.kind == .empty)
        #expect(overview.ruler.blood.absence == .noReport)
        #expect(overview.vaultCard == nil)
        #expect(overview.meta == "All on this iPhone")
        #expect(overview.slopes == .noData)
        #expect(overview.starMap.measuredCount == 0)
    }

    @Test func theDataFixtureFillsTheRulerTheSlopesAndTheStars() async {
        let sources = DataOverviewFixtures.sources(now: now, calendar: berlin)
        let overview = await DataOverviewMapping.overview(sources: DataOverviewSources(
            profile: sources.profile, labDraws: sources.labDraws, appleHealth: sources.appleHealth,
            metricHistory: sources.metricHistory, vault: { DataVaultFacts(daysOfData: 460) }),
            band: DataOverviewFixtures.band, now: now, calendar: berlin)
        #expect(overview.ruler.pins.map(\.kind) == [.blood, .real, .cardio])
        #expect(overview.ruler.hero.kind == .blood)
        #expect(overview.slopes.rows.count >= 6)
        #expect(overview.slopes.rows.contains { $0.id == MetricKey.restingHeartRate.rawValue && $0.trend == .improving })
        #expect(overview.starMap.measuredCount > 0)
        #expect(overview.sourceRows.map(\.kind) == [.band, .appleHealth, .labs])
    }
}
