#if DEBUG
import AnalyticsKit
import DataKit
import Foundation
import HealthKitBridge
import ProfileKit

/// Data for the Data tab's root under `--loopr-data-fixture`: Alex, 38, male reference curve. Two blood tests, one
/// 43 days ago with all nine PhenoAge markers and one 400 days ago; three Apple Watch VO₂max readings in the last 42
/// days; weekly weight and body fat and daily daylight from Apple Health; 460 days of band history for six metrics.
/// Everything is placed relative to the launch's clock, so the comparison is always open. The vault reads the Your
/// data fixture ledgers. Nothing here reaches production storage.
///
/// `--loopr-data-fixture=absent` keeps the vault's file but no stored days, and takes every other source away, so each
/// pin and card shows its absent state.
nonisolated enum DataOverviewFixtures {
    static let argument = "--loopr-data-fixture"
    static let absentArgument = "--loopr-data-fixture=absent"

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains { $0 == argument || $0.hasPrefix(argument + "=") }
    }

    static func isAbsentRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(absentArgument)
    }

    static let band = DataBandFacts(name: "WHOOP 4.0", lastSync: nil)

    /// The vault facts of the Your data fixture ledgers, read by the real reader.
    static let vault: @Sendable () async -> DataVaultFacts? = {
        guard let stores = try? await FiveTabDataFixture.stores() else { return nil }
        return await DataOverviewMapping.readVault(stores.ledgers.map(\.database))
    }

    /// The same file with no stored days, for a launch that has no data: an empty state never counts the fixture's days.
    static let emptyVault: @Sendable () async -> DataVaultFacts? = {
        guard var facts = await vault() else { return nil }
        facts.daysOfData = 0
        facts.firstDay = nil
        facts.importedDays = 0
        return facts
    }

    static func sources(now: Date, calendar: Calendar) -> DataOverviewSources {
        if isAbsentRequested() {
            return DataOverviewSources(profile: { nil }, labDraws: { [] },
                                       appleHealth: { _, _, _ in .absent(.noSamples) },
                                       metricHistory: { _, _, _ in [] }, vault: emptyVault)
        }
        let birthYear = calendar.component(.year, from: now) - 38
        let draws = labDraws(now: now)
        return DataOverviewSources(
            profile: { DataOverviewProfile(birthYear: birthYear, biologicalSex: .male) },
            labDraws: { draws },
            appleHealth: { kind, _, _ in Self.appleHealth(kind, now: now, calendar: calendar) },
            metricHistory: { key, _, _ in Self.history(key, now: now, calendar: calendar) },
            vault: vault)
    }

    // MARK: Labs

    private static let zone = "Europe/Berlin"

    private static func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }

    private static func report(_ id: String, daysAgo: Double, now: Date) -> LabReport {
        let collected = now.addingTimeInterval(-daysAgo * 86_400)
        return LabReport(id: UUID(uuidString: id) ?? UUID(), collectedAt: collected, timeZoneIdentifier: zone,
                         labName: "Riverside Lab", fasting: true, source: .typed, createdAt: collected.addingTimeInterval(3_600))
    }

    private static func values(_ report: LabReport, _ entries: [(LabMarkerKey, String, String)]) -> [LabValue] {
        entries.map { key, text, unit in
            LabValue(reportID: report.id, subject: .marker(key), value: decimal(text), unit: unit, source: .typed)
        }
    }

    static func labDraws(now: Date) -> [DataLabDraw] {
        let latest = report("5F0C3A10-0000-4000-8000-000000000001", daysAgo: 43, now: now)
        let earlier = report("5F0C3A10-0000-4000-8000-000000000002", daysAgo: 400, now: now)
        let micro = "\u{00B5}"
        return [
            DataLabDraw(report: latest, values: values(latest, [
                (.albumin, "46", "g/L"), (.creatinine, "84", "\(micro)mol/L"), (.glucose, "4.9", "mmol/L"),
                (.crp, "0.6", "mg/L"), (.lymphocytePercent, "31", "%"), (.meanCellVolume, "89", "fL"),
                (.redCellDistributionWidth, "12.6", "%"), (.alkalinePhosphatase, "62", "U/L"),
                (.whiteBloodCellCount, "5.4", "10^9/L"), (.apoB, "78", "mg/dL"), (.hba1c, "5.4", "%"),
                (.ldlCholesterol, "98", "mg/dL"), (.lipoproteinA, "18", "nmol/L"), (.vitaminD, "34", "ng/mL")
            ])),
            DataLabDraw(report: earlier, values: values(earlier, [
                (.albumin, "45", "g/L"), (.glucose, "5.0", "mmol/L"), (.crp, "1.1", "mg/L"),
                (.apoB, "92", "mg/dL"), (.hba1c, "5.3", "%"), (.ldlCholesterol, "121", "mg/dL"), (.vitaminD, "22", "ng/mL")
            ]))
        ]
    }

    // MARK: Apple Health

    private static let watch = AppleHealthProvenance(sourceName: "Alex's Apple Watch", sourceBundleIdentifier: "com.apple.health.81C9A3F2",
                                                     deviceName: "Apple Watch", deviceModel: "Watch")
    private static let scale = AppleHealthProvenance(sourceName: "Withings", sourceBundleIdentifier: "com.withings.wiScaleNG")

    private static func sample(_ kind: AppleHealthSourceKind, _ value: Double, at date: Date,
                               provenance: AppleHealthProvenance) -> AppleHealthSample {
        AppleHealthSample(kind: kind, value: value, original: AppleHealthOriginalReading(value: value, unit: kind.storeUnit),
                          start: date, end: date, provenance: provenance)
    }

    static func appleHealth(_ kind: AppleHealthSourceKind, now: Date, calendar: Calendar) -> AppleHealthReadResult {
        func ago(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now) ?? now }
        switch kind {
        case .vo2Max:
            // A year ago the 42-day median was 41.5, so the year card says "+2.6", as the Fitness gauge does (R3-OPT-3).
            return .values([sample(.vo2Max, 41.3, at: ago(395), provenance: watch), sample(.vo2Max, 41.5, at: ago(380), provenance: watch),
                            sample(.vo2Max, 41.7, at: ago(366), provenance: watch),
                            sample(.vo2Max, 43.8, at: ago(35), provenance: watch), sample(.vo2Max, 44.1, at: ago(20), provenance: watch),
                            sample(.vo2Max, 44.4, at: ago(3), provenance: watch)])
        case .weight:
            return .values(stride(from: 455, through: 0, by: -7).map { day in
                sample(.weight, 79.6 - Double(455 - day) / 455 * 1.4 + wave(day, 0.4), at: ago(day), provenance: scale)
            })
        case .bodyFat:
            return .values(stride(from: 455, through: 0, by: -7).map { day in
                sample(.bodyFat, 18.9 + wave(day, 0.3), at: ago(day), provenance: scale)
            })
        case .daylight:
            return .values((0...455).map { day in sample(.daylight, 48 + wave(day, 14), at: ago(day), provenance: watch) })
        case .bloodPressure, .leanMass, .bloodGlucose, .steps:
            return .absent(.noSamples)
        }
    }

    // MARK: Band history

    /// A repeatable wobble of `size` around zero.
    private static func wave(_ day: Int, _ size: Double) -> Double {
        sin(Double(day) * 0.9) * size * 0.6 + sin(Double(day) * 0.23) * size * 0.4
    }

    /// This year's level, then last year's, for the metrics the fixture fills.
    private static let levels: [MetricKey: (now: Double, lastYear: Double, wobble: Double)] = [
        .restingHeartRate: (51, 54, 1.5),
        .rmssd: (64, 57, 6),
        .sleepDuration: (444, 446, 18),
        .recovery: (66, 64, 9),
        .strain: (11.8, 10.6, 2.2),
        .sleepConsistency: (88, 81, 4)
    ]

    static func history(_ key: MetricKey, now: Date, calendar: Calendar) -> [MetricHistoryPoint] {
        guard let level = levels[key] else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0...460).reversed().compactMap { day -> MetricHistoryPoint? in
            guard day % 11 != 5, let date = calendar.date(byAdding: .day, value: -day, to: today) else { return nil }
            let share = min(Double(day) / 365, 1)
            let base = level.now + (level.lastYear - level.now) * share
            return MetricHistoryPoint(day: date, value: base + wave(day, level.wobble), source: .band)
        }
    }
}
#endif
