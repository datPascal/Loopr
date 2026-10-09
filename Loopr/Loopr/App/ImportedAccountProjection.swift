import Foundation
import ImportKit
import DomainKit
import DesignSystem
import TodayKit
import SleepKit
import HeartKit
import BodyKit

nonisolated let looprAccountHistoryImported = Notification.Name("com.loopr.account-history-imported")

nonisolated enum ImportedAccountProjection {
    static func display(_ imported: WHOOPImportedDay, trend: [SleepTrendPoint]) -> CanonicalDayDisplay {
        let today = imported.today
        let sleep = imported.sleep ?? SleepDaySnapshot(day: today.day, state: .absent, mainSleep: nil, metrics: [], source: "Account export")
        let heartDefinitions: [(HeartMetricID, TodayMetricID, String, HeartMetricUnitID)] = [
            (.restingHeartRate, .restingHeartRate, "bpm", .beatsPerMinute), (.rmssd, .hrv, "ms", .milliseconds)
        ]
        let heart = HeartDaySnapshot(day: today.day, state: .partial, metrics: heartDefinitions.map { id, todayID, unit, numericUnit in
            let metric = today.metric(todayID)
            return HeartMetricValue(id: id, title: id.title, value: metric?.value, unit: unit,
                state: metric?.state ?? .absent, source: "Account export", numericValue: metric?.numericValue, numericUnit: numericUnit)
        }, source: "Account export")
        let body = BodyDaySnapshot(day: today.day, state: .partial, metrics: [
            BodyMetricValue(id: .strain, title: "Strain", value: today.metric(.strain)?.value, unit: "/21",
                state: today.metric(.strain)?.state ?? .absent, source: "Account export")
        ], composition: BodyCompositionContext(weight: nil, height: nil, bodyFat: nil, state: .absent, source: "Account export"), cardioAge: nil, looprAge: nil, source: "Account export")
        let projection = CanonicalDailyProjection(revision: 0, movementBaselineRevision: 0, profile: nil,
            timeZoneIdentifier: imported.timezone, algorithmVersion: "account-export-v1", latestRecord: nil,
            today: today, sleep: withTrend(sleep, imported: trend), heart: heart, body: body, strainConfidence: 0)
        return CanonicalDayDisplay(projection: projection, today: today)
    }

    static func withTrend(_ sleep: SleepDaySnapshot, imported: [SleepTrendPoint]) -> SleepDaySnapshot {
        var points = Dictionary(uniqueKeysWithValues: imported.map { ($0.localDay, $0) })
        for point in sleep.trend where point.value != nil { points[point.localDay] = point }
        return SleepDaySnapshot(day: sleep.day, state: sleep.state, mainSleep: sleep.mainSleep, naps: sleep.naps,
            metrics: sleep.metrics, hypnogram: sleep.hypnogram, trend: points.values.sorted { $0.localDay < $1.localDay },
            needHours: sleep.needHours, debtHours: sleep.debtHours, source: sleep.source, algorithmVersion: sleep.algorithmVersion,
            coachLink: sleep.coachLink, suggestedAlarm: sleep.suggestedAlarm)
    }
}
