import BodyKit
import DesignSystem
import DomainKit
import Foundation
import NotificationKit
import SleepKit
import TodayKit

nonisolated enum LooprMorningRecapRequest {
    static func make(summary: TodaySummary, sleep: SleepSessionSummary?, target: StrainTarget?,
                     syncedAt: Date?, now: Date, calendar: Calendar) -> NotificationRequest? {
        guard let sleep, !sleep.isPartial, sleep.isMainSleep, sleep.end <= now,
              let syncedAt, syncedAt >= sleep.end, syncedAt <= now,
              calendar.isDate(sleep.end, inSameDayAs: now),
              let recovery = summary.metric(.recovery), recovery.state != .absent,
              recovery.numericUnit == .scorePoints, let score = recovery.numericValue,
              score.isFinite, (0...100).contains(score),
              let driver = summary.headline, !driver.isEmpty,
              let target, target.recovery == Int(score.rounded()),
              let plan = TodayMorningSentence.plan(range: target.range, adjustment: target.adjustment),
              let expiry = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        let day = String(format: "%04d-%02d-%02d", summary.day.year, summary.day.month, summary.day.day)
        let current = calendar.dateComponents([.era, .year, .month, .day], from: now)
        guard summary.day == DayIdentity(era: current.era ?? 1, year: current.year!, month: current.month!, day: current.day!) else { return nil }
        let early = recovery.confidence?.hasPrefix("Early estimate") == true ? " Early estimate." : ""
        return NotificationRequest(identity: .init(family: .recoveryReadiness, objectID: "morning-recap", day: day),
            fireDate: now, title: "Morning recap",
            detail: "Recovery \(Int(score.rounded()))." + early + " " + driver + " " + plan,
            sensitivity: .userRequestedAlert, deepLink: .today(day),
            quietHoursBehavior: .deferUntilEnd, expiresAt: expiry)
    }
}

nonisolated protocol LooprMorningRecapNotifying: Sendable {
    func morning(summary: TodaySummary, sleep: SleepSessionSummary?, syncedAt: Date?, now: Date, calendar: Calendar) async
}

nonisolated struct LooprMorningRecapNotifier: LooprMorningRecapNotifying {
    func morning(summary: TodaySummary, sleep: SleepSessionSummary?, syncedAt: Date?, now: Date, calendar: Calendar) async {
        let runtime = LooprNotificationRuntime.shared
        guard await runtime.isEnabled(.recoveryReadiness), let score = summary.metric(.recovery)?.numericValue else { return }
        let history = await MetricHistoryBodyProvider(provider: LooprMetricHistory.shared, calendar: calendar).bodyHistory(anchor: summary.day)
        let state = BodyTrainingLoad.compute(history: history, endingOn: summary.day.bodyAdding(days: -1))
        let load: TrainingLoad? = if case .ready(let ready) = state { ready.model } else { nil }
        guard let request = LooprMorningRecapRequest.make(summary: summary, sleep: sleep,
            target: StrainTarget(recovery: score, trainingLoad: load), syncedAt: syncedAt, now: now, calendar: calendar) else { return }
        // NotificationPolicy owns durable claims. A later sync or relaunch
        // uses the same identity and cannot send a second recap for this night.
        _ = await runtime.schedule(request)
    }
}
